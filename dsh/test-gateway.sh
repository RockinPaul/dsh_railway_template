#!/bin/bash
# Gateway contract for the Caddyfile: the edge gate must run BEFORE auto sign-in.
#
# This exists because getting it wrong is silent. With the two directives in a
# `handle` block, Caddy's own ordering puts `redir` ahead of `basic_auth`, so an
# unauthenticated `GET /` is answered with 302 and the live launch token — DSH's
# session handed to a stranger — while every other path still returns 401 and the
# gate looks like it is working. Only the index is affected, so nothing but a test
# that probes exactly `/` without credentials will catch it.
#
# Needs a caddy binary; set CADDY_BIN, or drop one in ./.caddytest.
#   ./test-gateway.sh
#
# Teardown matches on the bare name because `caddy start` detaches with a rewritten
# argv: a stale listener answered three runs during development and inverted the
# result every time.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${CADDY_TEST_DIR:-$HERE/.caddytest}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
CADDY="${CADDY_BIN:-$WORK/caddy}"
GATEWAY_PORT=18080
BACKEND_PORT=17000

if [ ! -x "$CADDY" ]; then
    echo "no caddy binary at $CADDY — set CADDY_BIN or place one in $WORK" >&2
    exit 2
fi

cleanup() { pkill -f caddy >/dev/null 2>&1; }
trap cleanup EXIT
cleanup
sleep 1
if lsof -nP -iTCP:"$GATEWAY_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "ABORT: port $GATEWAY_PORT is still held; a stale listener would fake a pass" >&2
    exit 1
fi

mkdir -p "$WORK/run/caddy"
hash=$(printf 'testpass\n' | "$CADDY" hash-password)
printf 'basic_auth {\n\tdsh %s\n}\n' "$hash" > "$WORK/run/caddy/gate.caddy"
printf '@dsh_needs_signin {\n\tpath /\n\tmethod GET\n\tnot header Cookie *dsh-auth-*\n\tnot query token=*\n}\nredir @dsh_needs_signin /?token=TOK123 302\n' > "$WORK/run/caddy/signin.caddy"
printf ':%s {\n\trespond "BACKEND" 200\n}\n' "$BACKEND_PORT" > "$WORK/backend.caddyfile"
sed "s#/run/caddy#$WORK/run/caddy#g" "$HERE/Caddyfile" > "$WORK/gateway.caddyfile"

"$CADDY" start --config "$WORK/backend.caddyfile" --adapter caddyfile >/dev/null 2>&1
PORT="$GATEWAY_PORT" DSH_PORT="$BACKEND_PORT" \
    "$CADDY" run --config "$WORK/gateway.caddyfile" --adapter caddyfile >"$WORK/gateway.log" 2>&1 &
sleep 2

fail=0
check() { # label, expected, actual
    if [ "$2" = "$3" ]; then
        printf '  ok   %-44s %s\n' "$1" "$3"
    else
        printf '  FAIL %-44s expected %s, got %s\n' "$1" "$2" "$3"
        fail=1
    fi
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
U="http://127.0.0.1:$GATEWAY_PORT"

echo "no credentials:"
check "GET / must not leak the redirect"   401 "$(code "$U/")"
check "GET /?token=x"                      401 "$(code "$U/?token=x")"
check "GET / + session cookie"             401 "$(code -H 'Cookie: dsh-auth-X=1' "$U/")"
check "GET /api/remote.mux"                401 "$(code "$U/api/remote.mux")"
check "GET /up stays open for the probe"   200 "$(code "$U/up")"

echo "with credentials:"
check "GET / redirects into the exchange"  302 "$(code -u dsh:testpass "$U/")"
check "  and points at the live token"     "/?token=TOK123" \
    "$(curl -s -u dsh:testpass -o /dev/null -D - "$U/" | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r')"
check "GET /?token=x passes through"       200 "$(code -u dsh:testpass "$U/?token=x")"
check "GET / + cookie passes through"      200 "$(code -u dsh:testpass -H 'Cookie: dsh-auth-X=1' "$U/")"
check "GET /api/remote.mux passes through" 200 "$(code -u dsh:testpass "$U/api/remote.mux")"

exit "$fail"
