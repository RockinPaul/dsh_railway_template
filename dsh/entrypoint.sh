#!/bin/sh
set -eu

# Railway mounts the volume root-owned with a lost+found directory, so everything
# lives in subdirectories, created here and handed to the unprivileged user.
mkdir -p "${HOME}" "${DSH_HOME}" "${DSH_WORKSPACE}" "${NPM_CONFIG_PREFIX}" \
         "${MISE_DATA_DIR}" "${MISE_CONFIG_DIR}" "${MISE_CACHE_DIR}"

# useradd ran with -M, so the shell skeleton was never copied. Seed it once, on a
# genuinely empty home, so interactive shells behave normally.
if [ ! -e "${HOME}/.bashrc" ]; then
    cp -a /etc/skel/. "${HOME}/" 2>/dev/null || true
fi
if ! grep -q 'mise activate' "${HOME}/.bashrc" 2>/dev/null; then
    printf '\n# added by the Railway entrypoint\neval "$(mise activate bash)"\n' >> "${HOME}/.bashrc"
fi

chown -R dsh:dsh "${HOME}" "${DSH_HOME}" "${DSH_WORKSPACE}" "${NPM_CONFIG_PREFIX}" "${MISE_DATA_DIR}"

# The /api trust fence accepts Host values that are loopback or listed as trusted.
# Behind Railway's edge the browser's Host is the public domain, so it must be
# trusted or every API call and WebSocket answers 403 while the page itself loads.
# DSH_TRUSTED_HOSTS adds custom domains, comma-separated.
set -- --profile web --no-open --port "${DSH_PORT}" "$@"
if [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]; then
    set -- "$@" --trusted-host "${RAILWAY_PUBLIC_DOMAIN}"
fi
if [ -n "${DSH_TRUSTED_HOSTS:-}" ]; then
    for h in $(printf '%s' "${DSH_TRUSTED_HOSTS}" | tr ',' ' '); do
        set -- "$@" --trusted-host "$h"
    done
fi
if [ -z "${RAILWAY_PUBLIC_DOMAIN:-}${DSH_TRUSTED_HOSTS:-}" ]; then
    echo "WARNING: no RAILWAY_PUBLIC_DOMAIN and no DSH_TRUSTED_HOSTS; only loopback Hosts will pass the /api fence." >&2
fi

# LongMemory joins as an MCP server when the service reference is present. The
# overlay is a launcher flag and must precede --profile.
if [ -n "${LONGMEMORY_MCP_URL:-}" ]; then
    if [ -z "${LONGMEMORY_API_KEY:-}" ]; then
        echo "FATAL: LONGMEMORY_MCP_URL is set but LONGMEMORY_API_KEY is empty." >&2
        exit 1
    fi
    set -- --patch /etc/dsh/longmemory.cordis.patch.yml "$@"
    echo "dsh: LongMemory MCP server at ${LONGMEMORY_MCP_URL}"
fi

# The edge gate: HTTP basic auth in front of DSH's own session authentication. The
# template generates DSH_GATE_PASSWORD, so this is normally on; the hash is computed
# at boot so no secret is written into the image or the repository.
#
# It is also the interlock for auto sign-in below. Auto sign-in redeems DSH's launch
# token on the visitor's behalf, so whoever reaches the index gets a session — which
# is exactly what this gate decides. No gate, no auto sign-in: the deployment falls
# back to DSH's own token URL rather than standing open.
mkdir -p /run/caddy
# A comment rather than an empty file: Caddy warns on importing an empty file.
printf '# no edge gate: DSH_GATE_PASSWORD is not set\n' > /run/caddy/gate.caddy
if [ -n "${DSH_GATE_PASSWORD:-}" ]; then
    # hash-password reads one newline-terminated line from stdin; without the newline it fails with EOF.
    hash="$(printf '%s\n' "${DSH_GATE_PASSWORD}" | caddy hash-password)"
    printf 'basic_auth {\n\t%s %s\n}\n' "${DSH_GATE_USER:-dsh}" "${hash}" > /run/caddy/gate.caddy
    echo "dsh: edge gate enabled for user ${DSH_GATE_USER:-dsh}"
fi
chown -R dsh:dsh /run/caddy

if [ -z "${DEEPSEEK_API_KEY:-}" ]; then
    echo "WARNING: DEEPSEEK_API_KEY is empty; set it as a variable, or in Settings -> Models after signing in." >&2
fi

echo "dsh: gateway on :${PORT}, harness on 127.0.0.1:${DSH_PORT}, workspace ${DSH_WORKSPACE}"

# ---------------------------------------------------------------------------
# Auto sign-in
# ---------------------------------------------------------------------------
# DSH mints a launch token with randomBytes() at every process start — it cannot be
# preset by flag, environment or config — and that token is the only way to obtain
# the browser session cookie. Left alone, the deployer's first login means opening
# the deploy logs and hand-editing a loopback URL, which is not something to ask of
# someone who just clicked Deploy.
#
# So the gateway redeems it for them. The token is captured from DSH's own output
# here, and Caddy bounces a session-less visitor through DSH's ordinary /?token=
# exchange, which answers 303 + Set-Cookie exactly as it does for a pasted URL.
# Nothing in DSH's auth is bypassed or reimplemented; the cookie is minted by DSH,
# with its own secret, and the edge gate decides who gets to reach the exchange.
#
# The redirect excludes requests that already carry a cookie or a token, so a stale
# token answers 401 once instead of looping.
mkdir -p /run/dsh
rm -f /run/dsh/log
mkfifo /run/dsh/log
TOKEN_FILE=/run/dsh/launch-token
: > "${TOKEN_FILE}"
chown -R dsh:dsh /run/dsh

cd "${DSH_WORKSPACE}"
gosu dsh dsh "$@" > /run/dsh/log 2>&1 &
DSH_PID=$!

# Every line goes through to the deploy log unchanged; the one carrying the token is
# also parsed. The token is base64url, so it ends at the first character outside
# that alphabet.
(
    while IFS= read -r line; do
        printf '%s\n' "${line}"
        case "${line}" in
            *"dsh web:"*"?token="*)
                if [ ! -s "${TOKEN_FILE}" ]; then
                    t="${line##*\?token=}"
                    printf '%s' "${t%%[!A-Za-z0-9_-]*}" > "${TOKEN_FILE}"
                fi
                ;;
        esac
    done < /run/dsh/log
) &

# Measured at about 2.4 s after start; the health check allows 300, so waiting here
# costs nothing and keeps Caddy's config a single static file with no reload API.
printf '# no auto sign-in\n' > /run/caddy/signin.caddy
if [ -n "${DSH_GATE_PASSWORD:-}" ]; then
    i=0
    while [ ! -s "${TOKEN_FILE}" ] && [ "${i}" -lt 60 ]; do
        kill -0 "${DSH_PID}" 2>/dev/null || break
        i=$((i + 1))
        sleep 1
    done
    if [ -s "${TOKEN_FILE}" ]; then
        printf '@dsh_needs_signin {\n\tpath /\n\tmethod GET\n\tnot header Cookie *dsh-auth-*\n\tnot query token=*\n}\nredir @dsh_needs_signin /?token=%s 302\n' \
            "$(cat "${TOKEN_FILE}")" > /run/caddy/signin.caddy
        echo "dsh: auto sign-in armed — open https://${RAILWAY_PUBLIC_DOMAIN:-<your-domain>}/ and authenticate at the edge gate"
    else
        echo "WARNING: the 'dsh web:' token line did not appear; sign in with its token from this log instead." >&2
    fi
else
    echo "dsh: no DSH_GATE_PASSWORD, so auto sign-in stays off — sign in with the 'dsh web:' token below." >&2
fi
chown dsh:dsh /run/caddy/signin.caddy

# Caddy runs as the same unprivileged user, in the background; tini reaps it. If it
# dies the health check fails and Railway restarts the container.
gosu dsh caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!

# dsh is no longer exec'd, so its exit status has to be carried out by hand, and a
# platform stop has to reach both children rather than only this shell.
trap 'kill -TERM "${DSH_PID}" "${CADDY_PID}" 2>/dev/null || true' TERM INT
wait "${DSH_PID}"
status=$?
kill -TERM "${CADDY_PID}" 2>/dev/null || true
exit "${status}"
