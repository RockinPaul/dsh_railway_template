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
# Boot state: Caddy starts before DSH has printed a token, exactly as the entrypoint
# does, because waiting for one leaves the port unserved and the edge answers 502.
printf '# no auto sign-in yet\n' > "$WORK/run/caddy/signin.caddy"
cat > "$WORK/backend.caddyfile" <<BACKEND
:$BACKEND_PORT {
	@exchange query token=*
	redir @exchange / 303
	respond "BACKEND" 200
}
BACKEND
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

echo "before the token exists (the 502 window this ordering removes):"
check "gateway already serving /up"        200 "$(code "$U/up")"
check "GET / proxies, no redirect yet"     200 "$(code -u dsh:testpass "$U/")"
check "GET / still gated"                  401 "$(code "$U/")"

# Arm auto sign-in the way the entrypoint does: write the snippet, then reload.
# A probe runs across the reload to prove the listener never drops, which is the
# whole reason the config is reloaded instead of Caddy being started late.
printf '@dsh_needs_signin {\n\tpath /\n\tmethod GET\n\tnot header Cookie *dsh-auth-*\n\tnot query token=*\n\tnot query signedin=*\n}\nredir @dsh_needs_signin /?token=TOK123 302\n' > "$WORK/run/caddy/signin.caddy"
(
    drops=0
    for _ in $(seq 1 40); do
        c=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$U/up" 2>/dev/null)
        [ "$c" = "200" ] || drops=$((drops + 1))
    done
    echo "$drops" > "$WORK/drops"
) &
probe=$!
PORT="$GATEWAY_PORT" DSH_PORT="$BACKEND_PORT" \
    "$CADDY" reload --config "$WORK/gateway.caddyfile" --adapter caddyfile >>"$WORK/gateway.log" 2>&1
reloaded=$?
wait "$probe"
check "reload succeeded"                   0 "$reloaded"
check "listener never dropped during reload" 0 "$(cat "$WORK/drops")"

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
check "GET /?token=x reaches the exchange"  303 "$(code -u dsh:testpass "$U/?token=x")"
check "GET / + cookie passes through"      200 "$(code -u dsh:testpass -H 'Cookie: dsh-auth-X=1' "$U/")"
check "GET /api/remote.mux passes through" 200 "$(code -u dsh:testpass "$U/api/remote.mux")"

# The loop guard. DSH ends the exchange with 303 to "/", which is what the sign-in
# redirect matches, so the flow terminates only because the session cookie comes
# back. A browser that will not keep the cookie otherwise bounces forever, which is
# how this surfaced: Firefox's "The page isn't redirecting properly".
echo "loop guard (a client whose cookies never stick):"
check "exchange lands on the marker, not /" "/?signedin=1" \
    "$(curl -s -u dsh:testpass -o /dev/null -D - "$U/?token=TOK123" | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r')"
check "marker falls through, no redirect"  200 "$(code -u dsh:testpass "$U/?signedin=1")"

# Walk it the way a browser does, with cookie storage disabled entirely.
hops=$(curl -s -u dsh:testpass -o /dev/null -L --max-redirs 8 -w '%{num_redirects} %{http_code}' "$U/" 2>/dev/null)
check "cookieless client terminates"       "2 200" "$hops"

exit "$fail"
