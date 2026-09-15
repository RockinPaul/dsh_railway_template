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

# Optional second gate at the edge: HTTP basic auth in front of DSH's own session
# authentication. Off unless DSH_GATE_PASSWORD is set; the hash is computed at boot so
# no secret is written into the image or the repository.
mkdir -p /run/caddy
: > /run/caddy/gate.caddy
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
echo "dsh: the 'dsh web:' URL below carries the sign-in token; open it as https://${RAILWAY_PUBLIC_DOMAIN:-<your-domain>}/?token=..."

# Caddy runs as the same unprivileged user, in the background; tini reaps it. If it
# dies the health check fails and Railway restarts the container.
gosu dsh caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &

cd "${DSH_WORKSPACE}"
exec gosu dsh dsh "$@"
