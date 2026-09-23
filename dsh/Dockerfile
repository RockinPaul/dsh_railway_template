# DSH — DeepSeek Harness, the browser agent surface (https://github.com/deepseek-ai/deepseek-harness)
#
# Upstream publishes no container image. The CLI is an npm package that hard-depends
# on the built web frontend (@deepseek-ai/dsh-web-frontend), so a pinned global install
# is a complete, servable GUI. Upstream has shipped only prereleases so far; the
# `latest` dist-tag is an rc, and this pins the version, not the tag.
FROM node:22-bookworm-slim

ARG DSH_VERSION=0.1.5-rc.3
# mise gives the box any toolchain (python, go, rust, another node) without rebuilding
# this image. Its data lives on the volume, so installs persist across redeploys.
ARG MISE_VERSION=v2026.9.7
ARG MISE_SHA256_AMD64=6cc34785ae10c38061e569b64b290fc8ac26e94d12c3f1aeb721790fa8f09196
ARG MISE_SHA256_ARM64=d8d38909537af5864822f3ad545d48f1cefae15db266b20052a32da7f834fd50
ARG TARGETARCH

# Workstation tooling for the agent's shell. git is a hard requirement: the agent
# works in repositories. gosu drops privileges after the entrypoint fixes volume
# ownership; tini reaps the caddy sidecar and the agent's child processes.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl git openssh-client gosu tini \
        ripgrep jq less nano procps \
    && rm -rf /var/lib/apt/lists/*

# `dsh --profile web` binds loopback only and rejects --host 0.0.0.0 by design, so the
# gateway must live in the same container. Caddy's static binary is copied from its
# own pinned image rather than installed from a moving apt repository.
COPY --from=caddy:2.11-alpine /usr/bin/caddy /usr/local/bin/caddy

# The install is arch-specific (sharp, koffi, a system addon), so it must happen in
# the build for the target platform rather than be copied in.
# lockfile, not from the version alone: the package's own ranges are `^0.1.5-rc.N`,
# so a plain global install mixes the pinned core with whatever plugin packages
# upstream published since. On 2026-09-22 that turned every fresh deploy of rc.1 into
# a boot crash ("plugin(s) failed to load: @deepseek-ai/dsh-sandbox-local") behind a
# green healthcheck, because Caddy answers /up. `npm ci` installs exactly the lock;
# DSH_VERSION MUST match package.json so the weekly assessment keeps reading the pin.
COPY package.json package-lock.json /opt/dsh/
RUN cd /opt/dsh \
    && node -e 'const w=require("./package.json").dependencies["@deepseek-ai/dsh"]; if (w!==process.env.DSH_VERSION) throw new Error(`DSH_VERSION ${process.env.DSH_VERSION} != package.json ${w}`)' \
    && npm ci --omit=dev \
    && npm cache clean --force \
    && ln -s /opt/dsh/node_modules/.bin/dsh /usr/local/bin/dsh \
    && dsh --version

RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) march="x64";   msha="${MISE_SHA256_AMD64}" ;; \
        arm64) march="arm64"; msha="${MISE_SHA256_ARM64}" ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/mise.tar.gz \
        "https://github.com/jdx/mise/releases/download/${MISE_VERSION}/mise-${MISE_VERSION}-linux-${march}.tar.gz"; \
    echo "${msha}  /tmp/mise.tar.gz" | sha256sum -c -; \
    tar xzf /tmp/mise.tar.gz -C /tmp; \
    mv /tmp/mise/bin/mise /usr/local/bin/mise; \
    rm -rf /tmp/mise /tmp/mise.tar.gz; \
    mise --version

# The agent runs as a non-root user whose home is ON THE VOLUME, set in /etc/passwd
# and not only in ENV: gosu resets HOME from the passwd entry, and an ENV-only home
# leaves the volume empty while state lands in the image layer and dies on redeploy.
# -M because /data does not exist at build time; the entrypoint creates it. The node
# base image already owns uid 1000 as `node`, so that account is removed first.
RUN userdel node 2>/dev/null || true; rm -rf /home/node; \
    useradd -u 1000 -d /data/home -M -s /bin/bash dsh

# Constants are baked so no service variable can be nulled into a required composer
# field. DSH_HOME holds the profile, sessions, settings and the credential store
# (including the browser-session cookie secret), so it sits on the volume.
ENV PORT=8080 \
    DSH_PORT=7000 \
    HOME=/data/home \
    DSH_HOME=/data/dsh \
    DSH_WORKSPACE=/data/workspace \
    NPM_CONFIG_PREFIX=/data/npm-global \
    MISE_DATA_DIR=/data/mise \
    MISE_CONFIG_DIR=/data/mise/config \
    MISE_CACHE_DIR=/data/mise/cache \
    MISE_YES=1 \
    PATH=/data/mise/shims:/data/npm-global/bin:/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin

# A login shell runs /etc/profile, which rebuilds PATH and would drop the mise shims
# and npm prefix. The agent's own shell tool spawns non-login shells; this covers
# `bash -l` and `railway ssh`.
RUN printf '%s\n' \
    'case ":$PATH:" in' \
    '  *:/data/mise/shims:*) ;;' \
    '  *) PATH="/data/mise/shims:/data/npm-global/bin:$PATH"; export PATH ;;' \
    'esac' \
    > /etc/profile.d/10-workstation-path.sh

COPY Caddyfile /etc/caddy/Caddyfile
COPY longmemory.cordis.patch.yml /etc/dsh/longmemory.cordis.patch.yml
COPY --chmod=755 entrypoint.sh /usr/local/bin/railway-entrypoint

WORKDIR /data/workspace
EXPOSE 8080
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/railway-entrypoint"]
