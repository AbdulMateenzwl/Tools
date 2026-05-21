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

REDIS_POD=$(kubectl get pod -n kong -l app=redis \
  -o jsonpath='{.items[0].metadata.name}')
REDIS_PASS=$(kubectl get secret redis-secret -n kong \
  -o jsonpath='{.data.password}' | base64 -d)

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
  kubectl exec -n kong $REDIS_POD -- \
    redis-cli -a $REDIS_PASS -n 1 FLUSHDB > /dev/null 2>&1
}

reset_cache() {
  kubectl exec -n kong $REDIS_POD -- \
    redis-cli -a $REDIS_PASS -n 0 FLUSHDB > /dev/null 2>&1
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

REDIS_POD=$(kubectl get pod -n kong -l app=redis \
  -o jsonpath='{.items[0].metadata.name}')
REDIS_PASS=$(kubectl get secret redis-secret -n kong \
  -o jsonpath='{.data.password}' | base64 -d)

# DB 0 = conversion cache
kubectl exec -n kong $REDIS_POD -- \
  redis-cli -a $REDIS_PASS -n 0 FLUSHDB > /dev/null 2>&1
# DB 1 = rate limiting counters
kubectl exec -n kong $REDIS_POD -- \
  redis-cli -a $REDIS_PASS -n 1 FLUSHDB > /dev/null 2>&1

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
check_pods "convertx"  "app=postgres"            "PostgreSQL pod"
check_pods "kong"      "app=redis"               "Redis pod"
check_pods "localstack" "app=localstack"         "LocalStack pod"

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

# Old refresh token should now be invalid (rotation)
OLD_REFRESH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  $BASE_URL/api/v1/auth/refresh \
  -H "Content-Type: application/json" \
  -d "{\"refresh_token\":\"$REFRESH_TOKEN\"}")
assert_status "POST /api/v1/auth/refresh (old token rejected)" "401" "$OLD_REFRESH_STATUS"

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

JWT_EMAIL=$(echo $JWT_RESP | jq -r '.payload.email')
JWT_ALG=$(echo $JWT_RESP | jq -r '.header.alg')

assert_json "JWT decode returns correct email" "$TEST_EMAIL" "$JWT_EMAIL"
assert_json "JWT decode returns correct algorithm" "HS256" "$JWT_ALG"

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
kubectl exec -n kong $REDIS_POD -- \
  redis-cli -a $REDIS_PASS -n 0 FLUSHDB > /dev/null 2>&1

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