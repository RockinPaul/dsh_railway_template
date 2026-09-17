#!/bin/bash
# Gateway contract for the Caddyfile. Three separate mistakes have shipped from this
# file, each invisible to the obvious probe, so each has an assertion below.
#
#  1. The edge gate must run BEFORE auto sign-in. With both in a `handle` block,
#     Caddy's directive order puts `redir` ahead of `basic_auth`, so an anonymous
#     `GET /` is answered 302 with the live launch token while every other path
#     still answers 401 — the gate looks like it works. `route` keeps the order.
#
#  2. Sign-in must terminate for a browser that will not keep the session cookie.
#     DSH ends its exchange with 303 to "/", so the flow used to loop forever;
#     Firefox reported "The page isn't redirecting properly" while curl with a
#     cookie jar and a clean Chromium both passed.
#
#  3. Sign-in must be driven by DSH's 401, not by guessing from the request. An
#     earlier version skipped sign-in whenever a dsh-auth cookie was present, so a
#     stale or rejected cookie suppressed it permanently and stranded the visitor
#     on "authentication required; reopen the URL printed by dsh web".
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

# Stand in for DSH: the token exchange 303s to "/", a good cookie is served, and
# anything else on the index is 401 — which is the signal the gateway now acts on.
cat > "$WORK/backend.caddyfile" <<BACKEND
:$BACKEND_PORT {
	@exchange query token=*
	handle @exchange {
		header Set-Cookie "dsh-auth-X=good; Path=/"
		# The matcher is explicit: a bare leading "/" is read as a path matcher, so
		# \`redir / 303\` redirects to "303".
		redir * / 303
	}

	@api path /api*
	handle @api {
		respond "BACKEND-API" 200
	}

	@good header Cookie *dsh-auth-X=good*
	handle @good {
		respond "BACKEND" 200
	}

	handle {
		respond "dsh web authentication required" 401
	}
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
        printf '  ok   %-46s %s\n' "$1" "$3"
    else
        printf '  FAIL %-46s expected %s, got %s\n' "$1" "$2" "$3"
        fail=1
    fi
}
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
loc() { curl -s -o /dev/null -D - "$@" | awk 'tolower($1)=="location:"{print $2}' | tr -d '\r'; }
A=(-u dsh:testpass)
U="http://127.0.0.1:$GATEWAY_PORT"

echo "before the token exists (the 502 window this ordering removes):"
check "gateway already serving /up"            200 "$(code "$U/up")"
check "GET / reaches DSH, no redirect yet"     401 "$(code "${A[@]}" "$U/")"
check "GET / still gated"                      401 "$(code "$U/")"

# Arm auto sign-in the way the entrypoint does: write the snippet, then reload. A
# probe runs across the reload to prove the listener never drops, which is why the
# config is reloaded rather than Caddy being started late.
printf '@dsh_needs_signin {\n\tpath /\n\tmethod GET\n\tnot query token=*\n\tnot query signedin=*\n}\nredir @dsh_needs_signin /?token=TOK123 302\n' > "$WORK/run/caddy/signin.caddy"
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
check "reload succeeded"                       0 "$reloaded"
check "listener never dropped during reload"   0 "$(cat "$WORK/drops")"

echo "the gate holds (nothing below leaks without credentials):"
check "GET / must not leak the redirect"       401 "$(code "$U/")"
check "GET /?token=x"                          401 "$(code "$U/?token=x")"
check "GET /api/remote.mux"                    401 "$(code "$U/api/remote.mux")"
check "GET /up stays open for the probe"       200 "$(code "$U/up")"

echo "signed-in traffic passes through:"
check "GET / with a good cookie"               200 "$(code "${A[@]}" -H 'Cookie: dsh-auth-X=good' "$U/")"
check "GET /api with a good cookie"            200 "$(code "${A[@]}" -H 'Cookie: dsh-auth-X=good' "$U/api/remote.mux")"

echo "sign-in is driven by DSH's 401, not by cookie presence:"
check "no cookie redirects to the exchange"    302 "$(code "${A[@]}" "$U/")"
check "  and carries the live token"           "/?token=TOK123" "$(loc "${A[@]}" "$U/")"
check "STALE cookie also redirects"            302 "$(code "${A[@]}" -H 'Cookie: dsh-auth-X=stale' "$U/")"
check "  rather than stranding on 401"         "/?token=TOK123" "$(loc "${A[@]}" -H 'Cookie: dsh-auth-X=stale' "$U/")"

echo "cross-site arrival (SameSite=Strict withholds the cookie on the first hop):"
check "401 on signedin=1 serves the hop page"   200 "$(code "${A[@]}" "$U/?signedin=1")"
check "  and it points at signedin=2"           1 \
    "$(curl -s "${A[@]}" "$U/?signedin=1" | grep -c 'signedin=2')"
check "signedin=2 with a cookie serves the app" 200 "$(code "${A[@]}" -H 'Cookie: dsh-auth-X=good' "$U/?signedin=2")"
check "signedin=2 without one stops at 401"     401 "$(code "${A[@]}" "$U/?signedin=2")"

echo "loop guard (a client whose cookies never stick):"
check "exchange lands on the marker, not /"    "/?signedin=1" "$(loc "${A[@]}" "$U/?token=TOK123")"
# curl runs no JS, so it stops at the hop page; the hop's own target is asserted
# above, and signedin=2 is where a cookie-less client actually terminates.
check "cookieless walk stops at the hop page"  "2 200" \
    "$(curl -s "${A[@]}" -o /dev/null -L --max-redirs 8 -w '%{num_redirects} %{http_code}' "$U/" 2>/dev/null)"
check "and no redirect is issued from there"   "" "$(loc "${A[@]}" "$U/?signedin=2")"
# A client that DOES keep cookies walks the whole flow: 401 -> exchange -> marker.
jar=$(mktemp)
check "cookie-keeping walk signs in"           "2 200" \
    "$(curl -s "${A[@]}" -c "$jar" -b "$jar" -o /dev/null -L --max-redirs 8 -w '%{num_redirects} %{http_code}' "$U/" 2>/dev/null)"
check "  and a stale cookie recovers"          "2 200" \
    "$(curl -s "${A[@]}" -b 'dsh-auth-X=stale' -c "$jar" -o /dev/null -L --max-redirs 8 -w '%{num_redirects} %{http_code}' "$U/" 2>/dev/null)"
rm -f "$jar"

exit "$fail"
