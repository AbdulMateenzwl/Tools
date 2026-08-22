// Package cognito wraps the Cognito user pool operations the auth service
// needs. It replaces the previous users table, bcrypt hashing, and
// Redis-backed refresh tokens.
package cognito

import (
	"context"
	"errors"
	"fmt"
	"os"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	cip "github.com/aws/aws-sdk-go-v2/service/cognitoidentityprovider"
	"github.com/aws/aws-sdk-go-v2/service/cognitoidentityprovider/types"
)

// DefaultGroup is the tier every new user joins. Group membership surfaces
// as the "cognito:groups" claim and stands in for the old users.role column.
const DefaultGroup = "free"

var (
	ErrUserExists         = errors.New("user already exists")
	ErrInvalidCredentials = errors.New("invalid credentials")
	ErrInvalidToken       = errors.New("invalid token")
)

type Client struct {
	api        *cip.Client
	userPoolID string
	clientID   string
}

type Tokens struct {
	AccessToken  string
	RefreshToken string
	ExpiresIn    int32
}

type User struct {
	Sub   string
	Email string
}

func New(ctx context.Context, userPoolID, clientID string) (*Client, error) {
	cfg, err := config.LoadDefaultConfig(ctx,
		config.WithRegion(os.Getenv("AWS_REGION")),
	)
	if err != nil {
		return nil, fmt.Errorf("load aws config: %w", err)
	}

	api := cip.NewFromConfig(cfg, func(o *cip.Options) {
		if endpoint := os.Getenv("AWS_ENDPOINT_URL"); endpoint != "" {
			o.BaseEndpoint = aws.String(endpoint)
		}
	})

	return &Client{api: api, userPoolID: userPoolID, clientID: clientID}, nil
}

// Register signs the user up, then immediately confirms them and grants the
// default group. Confirmation is done admin-side because there is no email
// delivery in this environment.
func (c *Client) Register(ctx context.Context, email, password string) error {
	_, err := c.api.SignUp(ctx, &cip.SignUpInput{
		ClientId: aws.String(c.clientID),
		Username: aws.String(email),
		Password: aws.String(password),
		UserAttributes: []types.AttributeType{
			{Name: aws.String("email"), Value: aws.String(email)},
		},
	})
	if err != nil {
		var exists *types.UsernameExistsException
		if errors.As(err, &exists) {
			return ErrUserExists
		}
		var invalidPw *types.InvalidPasswordException
		if errors.As(err, &invalidPw) {
			return fmt.Errorf("password does not meet policy: %w", err)
		}
		return fmt.Errorf("sign up: %w", err)
	}

	if _, err := c.api.AdminConfirmSignUp(ctx, &cip.AdminConfirmSignUpInput{
		UserPoolId: aws.String(c.userPoolID),
		Username:   aws.String(email),
	}); err != nil {
		return fmt.Errorf("confirm sign up: %w", err)
	}

	if _, err := c.api.AdminAddUserToGroup(ctx, &cip.AdminAddUserToGroupInput{
		UserPoolId: aws.String(c.userPoolID),
		Username:   aws.String(email),
		GroupName:  aws.String(DefaultGroup),
	}); err != nil {
		return fmt.Errorf("add user to group %s: %w", DefaultGroup, err)
	}

	return nil
}

func (c *Client) Login(ctx context.Context, email, password string) (*Tokens, error) {
	out, err := c.api.AdminInitiateAuth(ctx, &cip.AdminInitiateAuthInput{
		UserPoolId: aws.String(c.userPoolID),
		ClientId:   aws.String(c.clientID),
		AuthFlow:   types.AuthFlowTypeAdminUserPasswordAuth,
		AuthParameters: map[string]string{
			"USERNAME": email,
			"PASSWORD": password,
		},
	})
	if err != nil {
		if isAuthFailure(err) {
			return nil, ErrInvalidCredentials
		}
		return nil, fmt.Errorf("initiate auth: %w", err)
	}
	return tokensFrom(out.AuthenticationResult)
}

func (c *Client) Refresh(ctx context.Context, refreshToken string) (*Tokens, error) {
	out, err := c.api.AdminInitiateAuth(ctx, &cip.AdminInitiateAuthInput{
		UserPoolId:     aws.String(c.userPoolID),
		ClientId:       aws.String(c.clientID),
		AuthFlow:       types.AuthFlowTypeRefreshTokenAuth,
		AuthParameters: map[string]string{"REFRESH_TOKEN": refreshToken},
	})
	if err != nil {
		if isAuthFailure(err) {
			return nil, ErrInvalidToken
		}
		return nil, fmt.Errorf("refresh auth: %w", err)
	}

	tokens, err := tokensFrom(out.AuthenticationResult)
	if err != nil {
		return nil, err
	}
	// The refresh flow does not reissue a refresh token; carry the old one
	// forward so the response shape stays the same as before.
	if tokens.RefreshToken == "" {
		tokens.RefreshToken = refreshToken
	}
	return tokens, nil
}

// Revoke invalidates a refresh token and everything issued from it. Callers
// treat failure as non-fatal: it is a best-effort stand-in for the rotation
// the Redis implementation used to do, and not every backend implements it.
func (c *Client) Revoke(ctx context.Context, refreshToken string) error {
	_, err := c.api.RevokeToken(ctx, &cip.RevokeTokenInput{
		ClientId: aws.String(c.clientID),
		Token:    aws.String(refreshToken),
	})
	return err
}

// GetUser resolves the caller's identity from an access token. Cognito access
// tokens carry no email claim, so this is how /me gets one.
func (c *Client) GetUser(ctx context.Context, accessToken string) (*User, error) {
	out, err := c.api.GetUser(ctx, &cip.GetUserInput{
		AccessToken: aws.String(accessToken),
	})
	if err != nil {
		return nil, ErrInvalidToken
	}

	u := &User{}
	for _, attr := range out.UserAttributes {
		switch aws.ToString(attr.Name) {
		case "sub":
			u.Sub = aws.ToString(attr.Value)
		case "email":
			u.Email = aws.ToString(attr.Value)
		}
	}
	if u.Email == "" {
		// Pool uses email as the username, so this is a safe fallback.
		u.Email = aws.ToString(out.Username)
	}
	return u, nil
}

func tokensFrom(r *types.AuthenticationResultType) (*Tokens, error) {
	if r == nil {
		return nil, fmt.Errorf("no authentication result returned (challenge required?)")
	}
	return &Tokens{
		AccessToken:  aws.ToString(r.AccessToken),
		RefreshToken: aws.ToString(r.RefreshToken),
		ExpiresIn:    r.ExpiresIn,
	}, nil
}

func isAuthFailure(err error) bool {
	var notAuthorized *types.NotAuthorizedException
	var userNotFound *types.UserNotFoundException
	var userNotConfirmed *types.UserNotConfirmedException
	return errors.As(err, &notAuthorized) ||
		errors.As(err, &userNotFound) ||
		errors.As(err, &userNotConfirmed)
}
