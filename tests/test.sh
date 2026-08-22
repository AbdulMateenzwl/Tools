#!/bin/bash
# =============================================================
# ConvertX — API Test Suite
# Usage: bash tests/test.sh
# Requires: curl, jq
# =============================================================

BASE_URL="http://localhost:8080"
PASS=0
FAIL=0
TOTAL=0

# ── Colors ─────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Helpers ────────────────────────────────────────────────────

# Redis now lives inside LocalStack as ElastiCache on a dynamic port, so both
# the endpoint and the password are resolved from SecretsManager.
LOCALSTACK_POD=$(kubectl get pod -n localstack -l app=localstack \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

ls_secret() {
  kubectl exec -n localstack "$LOCALSTACK_POD" -- \
    awslocal secretsmanager get-secret-value \
      --secret-id "$1" --query SecretString --output text 2>/dev/null \
    | tr -d '\r\n'
}

REDIS_ENDPOINT=$(ls_secret convertx/redis/endpoint)
REDIS_EP_PORT="${REDIS_ENDPOINT##*:}"
REDIS_PASS=$(ls_secret convertx/redis/password)

# An empty password means ElastiCache is not enforcing AUTH — send none.
redis_cli() {
  local DB=$1; shift
  if [ -n "$REDIS_PASS" ]; then
    kubectl exec -n localstack "$LOCALSTACK_POD" -- \
      redis-cli -h 127.0.0.1 -p "$REDIS_EP_PORT" -a "$REDIS_PASS" -n "$DB" "$@"
  else
    kubectl exec -n localstack "$LOCALSTACK_POD" -- \
      redis-cli -h 127.0.0.1 -p "$REDIS_EP_PORT" -n "$DB" "$@"
  fi
}

pass() {
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
  echo -e "  ${GREEN}✓${NC} $1"
}

fail() {
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
  echo -e "  ${RED}✗${NC} $1"
  if [ -n "$2" ]; then
    echo -e "    ${RED}Expected:${NC} $2"
  fi
  if [ -n "$3" ]; then
    echo -e "    ${RED}Got:${NC}      $3"
  fi
}

reset_rate_limit() {
  redis_cli 1 FLUSHDB > /dev/null 2>&1
}

reset_cache() {
  redis_cli 0 FLUSHDB > /dev/null 2>&1
}

reset_all() {
  reset_rate_limit
  reset_cache
}

section() {
  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# Assert HTTP status code
assert_status() {
  local TEST_NAME=$1
  local EXPECTED=$2
  local ACTUAL=$3
  if [ "$ACTUAL" = "$EXPECTED" ]; then
    pass "$TEST_NAME (HTTP $ACTUAL)"
  else
    fail "$TEST_NAME" "HTTP $EXPECTED" "HTTP $ACTUAL"
  fi
}

# Assert JSON field equals value
assert_json() {
  local TEST_NAME=$1
  local EXPECTED=$2
  local ACTUAL=$3
  if [ "$ACTUAL" = "$EXPECTED" ]; then
    pass "$TEST_NAME"
  else
    fail "$TEST_NAME" "$EXPECTED" "$ACTUAL"
  fi
}

# Assert header exists
assert_header() {
  local TEST_NAME=$1
  local HEADER=$2
  local RESPONSE=$3
  if echo "$RESPONSE" | grep -qi "$HEADER"; then
    pass "$TEST_NAME"
  else
    fail "$TEST_NAME" "Header '$HEADER' present" "Header not found"
  fi
}

# Assert header value
assert_header_value() {
  local TEST_NAME=$1
  local HEADER=$2
  local EXPECTED=$3
  local RESPONSE=$4
  ACTUAL=$(echo "$RESPONSE" | grep -i "$HEADER" | cut -d: -f2- | tr -d ' \r\n')
  if [ "$ACTUAL" = "$EXPECTED" ]; then
    pass "$TEST_NAME"
  else
    fail "$TEST_NAME" "$EXPECTED" "$ACTUAL"
  fi
}

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║       ConvertX — API Test Suite          ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Target: $BASE_URL"
echo "  Time:   $(date)"

# ── Pre-flight: Check port forward is active ───────────────────
section "Pre-flight Checks"

AUTH_REACHABLE=$(curl -s -o /dev/null -w "%{http_code}" \
  --connect-timeout 3 \
  $BASE_URL/api/v1/auth/health 2>/dev/null)

if [ "$AUTH_REACHABLE" = "200" ]; then
  pass "Gateway is reachable at $BASE_URL"
else
  echo -e "  ${RED}✗${NC} Gateway not reachable at $BASE_URL"
  echo ""
  echo "  Make sure port-forward is running:"
  echo "  kubectl port-forward svc/\$(kubectl get svc -n kong | grep dataplane-ingress | awk '{print \$1}') 8080:80 -n kong &"
  echo ""
  exit 1
fi

# ── Reset rate limits and cache ────────────────────────────────
section "Resetting Rate Limits and Cache"

# DB 0 = conversion cache, DB 1 = rate limiting counters
reset_cache
reset_rate_limit

pass "Rate limits and cache reset"

# ── Check K8s pods ─────────────────────────────────────────────
section "Kubernetes Pod Health"

check_pods() {
  local NAMESPACE=$1
  local SELECTOR=$2
  local NAME=$3
  local READY=$(kubectl get pods -n $NAMESPACE -l $SELECTOR \
    --no-headers 2>/dev/null | \
    grep -c "Running" || true)
  local TOTAL_PODS=$(kubectl get pods -n $NAMESPACE -l $SELECTOR \
    --no-headers 2>/dev/null | \
    wc -l | tr -d ' ')

  if [ "$READY" -gt "0" ]; then
    pass "$NAME ($READY/$TOTAL_PODS pods running)"
  else
    fail "$NAME" "At least 1 pod running" "$READY/$TOTAL_PODS pods running"
  fi
}

check_pods "convertx"  "app=auth-service"       "Auth Service pods"
check_pods "convertx"  "app=conversion-service"  "Conversion Service pods"
check_pods "localstack" "app=localstack"         "LocalStack pod"

# PostgreSQL and Redis are no longer pods — they are RDS and ElastiCache
# instances inside LocalStack, so assert on their AWS status instead.
RDS_STATUS=$(kubectl exec -n localstack "$LOCALSTACK_POD" -- \
  awslocal rds describe-db-instances --db-instance-identifier convertx-db \
    --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null | tr -d '\r\n')
assert_json "RDS instance convertx-db is available" "available" "$RDS_STATUS"

CACHE_STATUS=$(kubectl exec -n localstack "$LOCALSTACK_POD" -- \
  awslocal elasticache describe-cache-clusters --cache-cluster-id convertx-cache \
    --query 'CacheClusters[0].CacheClusterStatus' --output text 2>/dev/null | tr -d '\r\n')
assert_json "ElastiCache cluster convertx-cache is available" "available" "$CACHE_STATUS"

# Check Kong dataplane
KONG_RUNNING=$(kubectl get pods -n kong --no-headers 2>/dev/null | \
  grep "dataplane" | grep -c "Running" || true)
if [ "$KONG_RUNNING" -gt "0" ]; then
  pass "Kong DataPlane pod running"
else
  fail "Kong DataPlane pod running" "Running" "Not running"
fi

# Check Kong controlplane
KONG_CP=$(kubectl get pods -n kong --no-headers 2>/dev/null | \
  grep "controlplane" | grep -c "Running" || true)
if [ "$KONG_CP" -gt "0" ]; then
  pass "Kong ControlPlane pod running"
else
  fail "Kong ControlPlane pod running" "Running" "Not running"
fi

# ── Auth Service Health ────────────────────────────────────────
section "Auth Service — Health"

HEALTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  $BASE_URL/api/v1/auth/health)
HEALTH_BODY=$(curl -s $BASE_URL/api/v1/auth/health)

assert_status "GET /api/v1/auth/health" "200" "$HEALTH_STATUS"
assert_json "Health returns status ok" \
  "ok" \
  "$(echo $HEALTH_BODY | jq -r '.status')"

# ── Auth Service — Registration ────────────────────────────────
section "Auth Service — Registration"

TEST_EMAIL="test_$(date +%s)@convertx.io"
TEST_PASSWORD="TestPass123!"

# Valid registration
REGISTER_RESP=$(curl -s -w "\n%{http_code}" -X POST \
  $BASE_URL/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}")
REGISTER_STATUS=$(echo "$REGISTER_RESP" | tail -1)
REGISTER_BODY=$(echo "$REGISTER_RESP" | head -1)

assert_status "POST /api/v1/auth/register (valid)" "201" "$REGISTER_STATUS"
assert_json "Register returns success message" \
  "registered successfully" \
  "$(echo $REGISTER_BODY | jq -r '.message')"

# Duplicate registration
DUP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  $BASE_URL/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}")
assert_status "POST /api/v1/auth/register (duplicate email)" "409" "$DUP_STATUS"

# Missing fields
MISSING_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  $BASE_URL/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":""}')
assert_status "POST /api/v1/auth/register (missing fields)" "400" "$MISSING_STATUS"

# Invalid email format
INVALID_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  $BASE_URL/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"notanemail","password":"password123"}')
assert_status "POST /api/v1/auth/register (invalid email)" "400" "$INVALID_STATUS"

# Short password
SHORT_PASS_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  $BASE_URL/api/v1/auth/register \
  -H "Content-Type: application/json" \
  -d '{"email":"new@test.com","password":"short"}')
assert_status "POST /api/v1/auth/register (password too short)" "400" "$SHORT_PASS_STATUS"

# ── Auth Service — Login ───────────────────────────────────────
section "Auth Service — Login"

LOGIN_RESP=$(curl -s -X POST \
  $BASE_URL/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}")

LOGIN_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  $BASE_URL/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"$TEST_PASSWORD\"}")

assert_status "POST /api/v1/auth/login (valid)" "200" "$LOGIN_STATUS"

ACCESS_TOKEN=$(echo $LOGIN_RESP | jq -r '.access_token')
REFRESH_TOKEN=$(echo $LOGIN_RESP | jq -r '.refresh_token')
EXPIRES_IN=$(echo $LOGIN_RESP | jq -r '.expires_in')

if [ "$ACCESS_TOKEN" != "null" ] && [ -n "$ACCESS_TOKEN" ]; then
  pass "Login returns access_token"
else
  fail "Login returns access_token" "JWT token" "null or empty"
fi

if [ "$REFRESH_TOKEN" != "null" ] && [ -n "$REFRESH_TOKEN" ]; then
  pass "Login returns refresh_token"
else
  fail "Login returns refresh_token" "refresh token" "null or empty"
fi

assert_json "Login returns expires_in 900" "900" "$EXPIRES_IN"

# Wrong password
WRONG_PASS_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  $BASE_URL/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$TEST_EMAIL\",\"password\":\"wrongpassword\"}")
assert_status "POST /api/v1/auth/login (wrong password)" "401" "$WRONG_PASS_STATUS"

# Non-existent user
NOUSER_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  $BASE_URL/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"nobody@convertx.io","password":"password123"}')
assert_status "POST /api/v1/auth/login (user not found)" "401" "$NOUSER_STATUS"

# ── Auth Service — Protected Routes ───────────────────────────
section "Auth Service — Protected Routes"

# /me with valid token
ME_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  $BASE_URL/api/v1/auth/me \
  -H "Authorization: Bearer $ACCESS_TOKEN")
assert_status "GET /api/v1/auth/me (valid token)" "200" "$ME_STATUS"

ME_BODY=$(curl -s $BASE_URL/api/v1/auth/me \
  -H "Authorization: Bearer $ACCESS_TOKEN")
assert_json "GET /me returns correct email" \
  "$TEST_EMAIL" \
  "$(echo $ME_BODY | jq -r '.email')"
assert_json "GET /me returns role free" \
  "free" \
  "$(echo $ME_BODY | jq -r '.role')"

# /me without token
ME_NO_TOKEN=$(curl -s -o /dev/null -w "%{http_code}" \
  $BASE_URL/api/v1/auth/me)
assert_status "GET /api/v1/auth/me (no token)" "401" "$ME_NO_TOKEN"

# /me with invalid token
ME_BAD_TOKEN=$(curl -s -o /dev/null -w "%{http_code}" \
  $BASE_URL/api/v1/auth/me \
  -H "Authorization: Bearer invalidtoken123")
assert_status "GET /api/v1/auth/me (invalid token)" "401" "$ME_BAD_TOKEN"

# ── Auth Service — Refresh Token ───────────────────────────────
section "Auth Service — Refresh Token"

REFRESH_RESP=$(curl -s -w "\n%{http_code}" -X POST \
  $BASE_URL/api/v1/auth/refresh \
  -H "Content-Type: application/json" \
  -d "{\"refresh_token\":\"$REFRESH_TOKEN\"}")
REFRESH_STATUS=$(echo "$REFRESH_RESP" | tail -1)
REFRESH_BODY=$(echo "$REFRESH_RESP" | head -1)

assert_status "POST /api/v1/auth/refresh (valid)" "200" "$REFRESH_STATUS"

NEW_ACCESS_TOKEN=$(echo $REFRESH_BODY | jq -r '.access_token')
if [ "$NEW_ACCESS_TOKEN" != "null" ] && [ -n "$NEW_ACCESS_TOKEN" ]; then
  pass "Refresh returns new access_token"
else
  fail "Refresh returns new access_token" "JWT token" "null or empty"
fi

# BEHAVIOUR CHANGE (Cognito): refresh tokens no longer rotate on every use.
# The old implementation deleted the refresh token from Redis and issued a new
# one; Cognito's REFRESH_TOKEN_AUTH flow reissues only the access token, so the
# same refresh token stays valid until it expires. The service revokes the old
# token only when a genuinely new one is returned. Assert reusability, which is
# the real contract now.
REUSE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  $BASE_URL/api/v1/auth/refresh \
  -H "Content-Type: application/json" \
  -d "{\"refresh_token\":\"$REFRESH_TOKEN\"}")
assert_status "POST /api/v1/auth/refresh (token reusable until expiry)" "200" "$REUSE_STATUS"

# A garbage refresh token must still be rejected.
BAD_REFRESH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  $BASE_URL/api/v1/auth/refresh \
  -H "Content-Type: application/json" \
  -d '{"refresh_token":"not-a-real-refresh-token"}')
assert_status "POST /api/v1/auth/refresh (invalid token rejected)" "401" "$BAD_REFRESH_STATUS"

# ── Auth Service — API Key ─────────────────────────────────────
section "Auth Service — API Key Generation"

APIKEY_RESP=$(curl -s -w "\n%{http_code}" -X POST \
  $BASE_URL/api/v1/auth/api-key \
  -H "Authorization: Bearer $ACCESS_TOKEN")
APIKEY_STATUS=$(echo "$APIKEY_RESP" | tail -1)
APIKEY_BODY=$(echo "$APIKEY_RESP" | head -1)

assert_status "POST /api/v1/auth/api-key (valid)" "201" "$APIKEY_STATUS"

API_KEY=$(echo $APIKEY_BODY | jq -r '.api_key')
if echo "$API_KEY" | grep -q "^cx_"; then
  pass "API key has correct cx_ prefix"
else
  fail "API key has correct cx_ prefix" "cx_..." "$API_KEY"
fi

if [ ${#API_KEY} -gt 20 ]; then
  pass "API key has sufficient length (${#API_KEY} chars)"
else
  fail "API key length" ">20 chars" "${#API_KEY} chars"
fi

# ── Conversion Service — Health ────────────────────────────────
section "Conversion Service — Health"

CONV_HEALTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  $BASE_URL/api/v1/convert/health)
CONV_HEALTH_BODY=$(curl -s $BASE_URL/api/v1/convert/health)

assert_status "GET /api/v1/convert/health" "200" "$CONV_HEALTH_STATUS"
assert_json "Convert health returns status ok" \
  "ok" \
  "$(echo $CONV_HEALTH_BODY | jq -r '.status')"

# ── Conversion Service — JSON/XML ─────────────────────────────
section "Conversion Service — JSON ↔ XML"

# JSON to XML
JSON_XML_RESP=$(curl -s -w "\n%{http_code}" -X POST \
  $BASE_URL/api/v1/convert/json-to-xml \
  -H "Content-Type: application/json" \
  -d '{"input":"{\"name\":\"John\",\"age\":30}"}')
JSON_XML_STATUS=$(echo "$JSON_XML_RESP" | tail -1)
JSON_XML_BODY=$(echo "$JSON_XML_RESP" | head -1)

assert_status "POST /convert/json-to-xml" "200" "$JSON_XML_STATUS"
OUTPUT=$(echo $JSON_XML_BODY | jq -r '.output')
if echo "$OUTPUT" | grep -q "<name>John</name>"; then
  pass "JSON to XML output contains correct XML"
else
  fail "JSON to XML output" "<name>John</name>" "$OUTPUT"
fi

# JSON array to XML
ARRAY_XML_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  $BASE_URL/api/v1/convert/json-to-xml \
  -H "Content-Type: application/json" \
  -d '{"input":"[{\"name\":\"John\"},{\"name\":\"Jane\"}]"}')
assert_status "POST /convert/json-to-xml (array input)" "200" "$ARRAY_XML_STATUS"

# XML to JSON
XML_JSON_RESP=$(curl -s -w "\n%{http_code}" -X POST \
  $BASE_URL/api/v1/convert/xml-to-json \
  -H "Content-Type: application/json" \
  -d '{"input":"<person><name>John</name><age>30</age></person>"}')
XML_JSON_STATUS=$(echo "$XML_JSON_RESP" | tail -1)
XML_JSON_BODY=$(echo "$XML_JSON_RESP" | head -1)

assert_status "POST /convert/xml-to-json" "200" "$XML_JSON_STATUS"
OUTPUT=$(echo $XML_JSON_BODY | jq -r '.output')
if echo "$OUTPUT" | grep -q "John"; then
  pass "XML to JSON output contains correct data"
else
  fail "XML to JSON output" "Contains John" "$OUTPUT"
fi

# Invalid JSON input
INVALID_JSON_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  $BASE_URL/api/v1/convert/json-to-xml \
  -H "Content-Type: application/json" \
  -d '{"input":"not valid json {{{"}')
assert_status "POST /convert/json-to-xml (invalid input)" "400" "$INVALID_JSON_STATUS"

# ── Conversion Service — JSON/CSV ─────────────────────────────
reset_cache
section "Conversion Service — JSON ↔ CSV"

JSON_CSV_RESP=$(curl -s -w "\n%{http_code}" -X POST \
  $BASE_URL/api/v1/convert/json-to-csv \
  -H "Content-Type: application/json" \
  -d '{"input":"[{\"name\":\"John\",\"age\":\"30\"},{\"name\":\"Jane\",\"age\":\"25\"}]"}')
JSON_CSV_STATUS=$(echo "$JSON_CSV_RESP" | tail -1)
JSON_CSV_BODY=$(echo "$JSON_CSV_RESP" | head -1)

assert_status "POST /convert/json-to-csv" "200" "$JSON_CSV_STATUS"
OUTPUT=$(echo $JSON_CSV_BODY | jq -r '.output')
if echo "$OUTPUT" | grep -q "John"; then
  pass "JSON to CSV output contains correct data"
else
  fail "JSON to CSV output" "Contains John" "$OUTPUT"
fi

CSV_JSON_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  $BASE_URL/api/v1/convert/csv-to-json \
  -H "Content-Type: application/json" \
  -d '{"input":"name,age\nJohn,30\nJane,25"}')
assert_status "POST /convert/csv-to-json" "200" "$CSV_JSON_STATUS"

# ── Conversion Service — YAML/JSON ────────────────────────────
reset_cache
section "Conversion Service — YAML ↔ JSON"

YAML_JSON_RESP=$(curl -s -w "\n%{http_code}" -X POST \
  $BASE_URL/api/v1/convert/yaml-to-json \
  -H "Content-Type: application/json" \
  -d '{"input":"name: John\nage: 30\ncity: Dublin"}')
YAML_JSON_STATUS=$(echo "$YAML_JSON_RESP" | tail -1)
YAML_JSON_BODY=$(echo "$YAML_JSON_RESP" | head -1)

assert_status "POST /convert/yaml-to-json" "200" "$YAML_JSON_STATUS"

# Verify integer fix — age should be 30 not 30.0
AGE=$(echo $YAML_JSON_BODY | jq -r '.output' | jq -r '.age')
assert_json "YAML integer not converted to float (30 not 30.0)" "30" "$AGE"

JSON_YAML_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  $BASE_URL/api/v1/convert/json-to-yaml \
  -H "Content-Type: application/json" \
  -d '{"input":"{\"name\":\"John\",\"age\":30}"}')
assert_status "POST /convert/json-to-yaml" "200" "$JSON_YAML_STATUS"

# ── Tools — Base64 ─────────────────────────────────────────────
reset_cache
section "Tools — Base64"

B64_ENCODE_RESP=$(curl -s -X POST \
  $BASE_URL/api/v1/tools/base64/encode \
  -H "Content-Type: application/json" \
  -d '{"input":"Hello ConvertX"}')

ENCODED=$(echo $B64_ENCODE_RESP | jq -r '.output')
assert_json "Base64 encode correct output" \
  "SGVsbG8gQ29udmVydFg=" \
  "$ENCODED"

B64_DECODE_RESP=$(curl -s -X POST \
  $BASE_URL/api/v1/tools/base64/decode \
  -H "Content-Type: application/json" \
  -d '{"input":"SGVsbG8gQ29udmVydFg="}')

DECODED=$(echo $B64_DECODE_RESP | jq -r '.output')
assert_json "Base64 decode correct output" \
  "Hello ConvertX" \
  "$DECODED"

# Invalid base64
INVALID_B64_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  $BASE_URL/api/v1/tools/base64/decode \
  -H "Content-Type: application/json" \
  -d '{"input":"!!!notbase64!!!"}')
assert_status "Base64 decode invalid input returns 400" "400" "$INVALID_B64_STATUS"

# ── Tools — URL Encode/Decode ──────────────────────────────────
reset_cache
section "Tools — URL Encode/Decode"

URL_ENCODE_RESP=$(curl -s -X POST \
  $BASE_URL/api/v1/tools/url/encode \
  -H "Content-Type: application/json" \
  -d '{"input":"https://convertx.io?type=json&output=xml"}')

URL_ENCODED=$(echo $URL_ENCODE_RESP | jq -r '.output')
if echo "$URL_ENCODED" | grep -q "%3A"; then
  pass "URL encode correct output"
else
  fail "URL encode output" "Contains %3A" "$URL_ENCODED"
fi

URL_DECODE_RESP=$(curl -s -X POST \
  $BASE_URL/api/v1/tools/url/decode \
  -H "Content-Type: application/json" \
  -d '{"input":"https%3A%2F%2Fconvertx.io%3Ftype%3Djson"}')

URL_DECODED=$(echo $URL_DECODE_RESP | jq -r '.output')
if echo "$URL_DECODED" | grep -q "https://convertx.io"; then
  pass "URL decode correct output"
else
  fail "URL decode output" "https://convertx.io..." "$URL_DECODED"
fi

# ── Tools — JWT Decode ─────────────────────────────────────────
reset_cache
section "Tools — JWT Decode"

JWT_RESP=$(curl -s -X POST \
  $BASE_URL/api/v1/tools/jwt/decode \
  -H "Content-Type: application/json" \
  -d "{\"input\":\"$ACCESS_TOKEN\"}")

JWT_ALG=$(echo $JWT_RESP | jq -r '.header.alg')
JWT_USE=$(echo $JWT_RESP | jq -r '.payload.token_use')
JWT_SUB=$(echo $JWT_RESP | jq -r '.payload.sub')

# Cognito signs with rotating RSA keys, not the old shared HS256 secret.
assert_json "JWT decode returns correct algorithm" "RS256" "$JWT_ALG"

# Access tokens carry no email claim — that is why /me calls GetUser.
assert_json "Access token is an access token" "access" "$JWT_USE"

if [ -n "$JWT_SUB" ] && [ "$JWT_SUB" != "null" ]; then
  pass "Access token carries a sub claim"
else
  fail "Access token carries a sub claim" "a Cognito sub" "$JWT_SUB"
fi

INVALID_JWT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  $BASE_URL/api/v1/tools/jwt/decode \
  -H "Content-Type: application/json" \
  -d '{"input":"not.a.jwt"}')
assert_status "JWT decode invalid token returns 400" "400" "$INVALID_JWT_STATUS"

# ── Tools — UUID ───────────────────────────────────────────────
section "Tools — UUID"

UUID_RESP=$(curl -s $BASE_URL/api/v1/tools/uuid)
UUID_VAL=$(echo $UUID_RESP | jq -r '.uuid')

if echo "$UUID_VAL" | grep -qE \
  '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'; then
  pass "UUID is valid v4 format"
else
  fail "UUID v4 format" "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx" "$UUID_VAL"
fi

UUID2=$(curl -s $BASE_URL/api/v1/tools/uuid | jq -r '.uuid')
if [ "$UUID_VAL" != "$UUID2" ]; then
  pass "UUID generates unique values each time"
else
  fail "UUID uniqueness" "Different UUIDs" "Same UUID generated twice"
fi

# ── Redis Caching ──────────────────────────────────────────────
reset_all
section "Redis Caching"

# Flush conversion cache (DB 0) so we get a fresh result
reset_cache

# Use a unique payload with timestamp so it is never pre-cached
CACHE_TS=$(date +%s%N)
PAYLOAD="{\"input\":\"{\\\"cache_test\\\":true,\\\"ts\\\":\\\"$CACHE_TS\\\"}\"}"

FIRST=$(curl -s -X POST \
  $BASE_URL/api/v1/convert/json-to-xml \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" | jq -r '.cached')

SECOND=$(curl -s -X POST \
  $BASE_URL/api/v1/convert/json-to-xml \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" | jq -r '.cached')

assert_json "First request not cached" "false" "$FIRST"
assert_json "Second request is cached" "true" "$SECOND"

# ── Kong Plugins ───────────────────────────────────────────────
section "Kong Plugins"

HEADERS=$(curl -s -D - -o /dev/null http://localhost:8080/api/v1/convert/health)

assert_header "X-Content-Type-Options header present" \
  "X-Content-Type-Options" "$HEADERS"

assert_header "X-Frame-Options header present" \
  "X-Frame-Options" "$HEADERS"

assert_header "X-XSS-Protection header present" \
  "X-XSS-Protection" "$HEADERS"

assert_header "X-Request-ID header present" \
  "X-Request-ID" "$HEADERS"

assert_header "Rate limit header present" \
  "X-RateLimit-Limit-Day" "$HEADERS"

assert_header "Rate limit remaining header present" \
  "X-RateLimit-Remaining-Day" "$HEADERS"

# CORS with allowed origin
CORS_HEADERS=$(curl -s -D - -o /dev/null \
  http://localhost:8080/api/v1/auth/health \
  -H "Origin: http://localhost:4200")

assert_header "CORS allows localhost:4200" \
  "Access-Control-Allow-Origin: http://localhost:4200" "$CORS_HEADERS"

# CORS with blocked origin
BLOCKED_CORS=$(curl -s -D - -o /dev/null \
  http://localhost:8080/api/v1/auth/health \
  -H "Origin: http://evil.com")

if echo "$BLOCKED_CORS" | grep -qi "Access-Control-Allow-Origin: http://evil.com"; then
  fail "CORS blocks evil.com" "No header" "Header present"
else
  pass "CORS correctly blocks evil.com"
fi

# CORS preflight
PREFLIGHT_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X OPTIONS \
  $BASE_URL/api/v1/auth/register \
  -H "Origin: http://localhost:4200" \
  -H "Access-Control-Request-Method: POST")
if [ "$PREFLIGHT_STATUS" = "200" ] || [ "$PREFLIGHT_STATUS" = "204" ]; then
  pass "CORS preflight OPTIONS returns $PREFLIGHT_STATUS"
else
  fail "CORS preflight" "200 or 204" "$PREFLIGHT_STATUS"
fi

# Request ID is unique per request
REQ_ID_1=$(curl -s -D - -o /dev/null \
  http://localhost:8080/api/v1/convert/health | \
  grep -i "X-Request-ID" | head -1 | cut -d: -f2 | tr -d ' \r\n')
REQ_ID_2=$(curl -s -D - -o /dev/null \
  http://localhost:8080/api/v1/convert/health | \
  grep -i "X-Request-ID" | head -1 | cut -d: -f2 | tr -d ' \r\n')

if [ "$REQ_ID_1" != "$REQ_ID_2" ] && [ -n "$REQ_ID_1" ]; then
  pass "X-Request-ID is unique per request"
else
  fail "X-Request-ID uniqueness" "Different IDs" "$REQ_ID_1 == $REQ_ID_2"
fi


# ── CloudWatch Log Shipping ────────────────────────────────────
section "CloudWatch Log Shipping"

check_pods "convertx" "app=fluent-bit" "fluent-bit pods"

# The suite has been generating traffic throughout, so by now fluent-bit
# should have flushed at least once (SERVICE Flush is 5s).
for GROUP in /convertx/auth-service /convertx/conversion-service /convertx/kong; do
  GROUP_EXISTS=$(kubectl exec -n localstack "$LOCALSTACK_POD" -- \
    awslocal logs describe-log-groups --log-group-name-prefix "$GROUP" \
      --query 'logGroups[0].logGroupName' --output text 2>/dev/null | tr -d '\r\n')
  assert_json "Log group $GROUP exists" "$GROUP" "$GROUP_EXISTS"
done

# Streams only appear once a record is actually delivered, so this is the
# assertion that proves the pipeline works rather than just that it is wired.
wait_for_stream() {
  local GROUP=$1
  for i in $(seq 1 12); do
    local COUNT=$(kubectl exec -n localstack "$LOCALSTACK_POD" -- \
      awslocal logs describe-log-streams --log-group-name "$GROUP" \
        --query 'length(logStreams)' --output text 2>/dev/null | tr -d '\r\n')
    if [ -n "$COUNT" ] && [ "$COUNT" != "0" ] && [ "$COUNT" != "None" ]; then
      echo "$COUNT"; return
    fi
    sleep 5
  done
  echo "0"
}

for GROUP in /convertx/auth-service /convertx/conversion-service /convertx/kong; do
  STREAMS=$(wait_for_stream "$GROUP")
  if [ "$STREAMS" != "0" ]; then
    pass "$GROUP has $STREAMS delivered stream(s)"
  else
    fail "$GROUP received logs" "at least 1 stream" "0 streams after 60s"
  fi
done

# ── CloudFront ─────────────────────────────────────────────────
section "CloudFront"

cf() {
  kubectl exec -n localstack "$LOCALSTACK_POD" -- awslocal cloudfront "$@" 2>/dev/null | tr -d '\r'
}

DIST_ID=$(cf list-distributions \
  --query "DistributionList.Items[?Comment=='convertx-api'].Id | [0]" \
  --output text | tr -d '\n')

if [ -z "$DIST_ID" ] || [ "$DIST_ID" = "None" ]; then
  fail "CloudFront distribution exists" "a distribution commented convertx-api" "none found"
else
  pass "Distribution exists ($DIST_ID)"

  # These two assertions are the whole point of the distribution config.
  # CloudFront defaults DefaultTTL to 86400; at that setting GET /tools/uuid
  # would be cached and every caller would receive the same UUID.
  DEFAULT_TTL=$(cf get-distribution --id "$DIST_ID" \
    --query 'Distribution.DistributionConfig.DefaultCacheBehavior.DefaultTTL' \
    --output text | tr -d '\n')
  MAX_TTL=$(cf get-distribution --id "$DIST_ID" \
    --query 'Distribution.DistributionConfig.DefaultCacheBehavior.MaxTTL' \
    --output text | tr -d '\n')

  assert_json "DefaultTTL is 0 (GET /tools/uuid must never be cached)" "0" "$DEFAULT_TTL"
  assert_json "MaxTTL is 0" "0" "$MAX_TTL"

  METHODS=$(cf get-distribution --id "$DIST_ID" \
    --query 'Distribution.DistributionConfig.DefaultCacheBehavior.AllowedMethods.Items' \
    --output text)
  if echo "$METHODS" | grep -q "POST"; then
    pass "POST is allowed through to the origin"
  else
    fail "POST allowed through to origin" "POST in AllowedMethods" "$METHODS"
  fi

  ORIGIN=$(cf get-distribution --id "$DIST_ID" \
    --query 'Distribution.DistributionConfig.Origins.Items[0].DomainName' \
    --output text | tr -d '\n')
  if echo "$ORIGIN" | grep -q "dataplane-ingress"; then
    pass "Origin points at the Kong dataplane ($ORIGIN)"
  else
    fail "Origin points at Kong" "a dataplane-ingress service" "$ORIGIN"
  fi
fi

# NOTE: traffic is not exercised through the distribution domain — it is not
# resolvable from here. These assertions cover the cache posture, which is the
# part that can silently break correctness.

# ── Summary ────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ $FAIL -eq 0 ]; then
  echo -e "  ${GREEN}All $TOTAL tests passed${NC}"
else
  echo -e "  ${GREEN}$PASS passed${NC} / ${RED}$FAIL failed${NC} / $TOTAL total"
fi

echo ""

if [ $FAIL -gt 0 ]; then
  exit 1
fi