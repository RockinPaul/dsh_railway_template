# DSH + LongMemory on Railway

[DSH](https://github.com/deepseek-ai/deepseek-harness) — DeepSeek Harness, DeepSeek's open-source
coding agent — served from its browser UI on Railway, with a
[LongMemory](https://github.com/CaviraOSS/LongMemory) server wired in as an MCP tool server, so the
agent keeps memory across sessions. Your workspace, sessions, settings and installed toolchains live
on a volume and survive redeploys.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/dsh-longmemory)

Built on DeepSeek Harness; not affiliated with or endorsed by DeepSeek.

## Services

| Service | Runs | Public | Role |
|---|---|---|---|
| `dsh` | `@deepseek-ai/dsh` 0.1.5-rc.3 on `node:22-bookworm-slim`, Caddy 2.11 in front, mise | **yes** | The agent, its browser UI and its shell, home on `/data`. |
| `longmemory` | LongMemory server, built from a pinned commit by [longmemory_railway_template](https://github.com/RockinPaul/longmemory_railway_template) | no | REST + MCP memory store on its own `/data` volume, reachable only on the private network. |

`dsh --profile web` binds loopback only and refuses `--host 0.0.0.0`, so the gateway has to live in
the same container. Caddy answers the platform health check itself and forwards everything else to
the harness on `127.0.0.1:7000`, passing the browser's `Host` through untouched — see below for why
that is not optional.

## Variables

| Service | Variable | Default | Purpose |
|---|---|---|---|
| `dsh` | `DEEPSEEK_API_KEY` | **you set it** | The model credential, and it has to be set here. DSH gates its settings pane on the page being loopback, so on a Railway domain *Settings → Models* reports "settings are unavailable in this browser". |
| `dsh` | `LONGMEMORY_MCP_URL` | `http://${{longmemory.RAILWAY_PRIVATE_DOMAIN}}:8080/mcp` | Where the MCP client dials. Unset it to run without LongMemory. |
| `dsh` | `LONGMEMORY_API_KEY` | `${{longmemory.LONGMEMORY_API_KEY}}` | Bearer token for that endpoint. |
| `dsh` | `DSH_TRUSTED_HOSTS` | *(empty)* | Extra hostnames, comma-separated, for custom domains. `RAILWAY_PUBLIC_DOMAIN` is always trusted. |
| `dsh` | `DSH_GATE_PASSWORD` / `DSH_GATE_USER` | generated / `dsh` | The sign-in. HTTP basic auth at the edge, and the interlock for automatic sign-in: clear the password and both turn off together. |
| `dsh` | `DEEPSEEK_BASE_URL` | *(official API)* | Point the DeepSeek provider at a compatible gateway. |
| `longmemory` | `LONGMEMORY_API_KEY` | generated | Protects the REST API and `/mcp`. |
| `longmemory` | `OPENAI_API_KEY` or `GEMINI_API_KEY` | *(empty)* | Optional embedding provider. Without one, recall matches on shared **words**, not meaning, and the service says so loudly in its log. |

Baked into the `dsh` image: `PORT=8080`, `DSH_PORT=7000`, `HOME=/data/home`, `DSH_HOME=/data/dsh`,
`DSH_WORKSPACE=/data/workspace`, `NPM_CONFIG_PREFIX=/data/npm-global`, mise directories under
`/data/mise`.

## First run

1. Open **`https://<your-dsh-domain>/`**. The browser asks for a username and password.
2. Copy `DSH_GATE_USER` and `DSH_GATE_PASSWORD` from the `dsh` service's **Variables** tab. They are
   generated for your deployment and do not rotate.
3. That is the sign-in. The gateway walks your browser through DSH's own token exchange behind the
   prompt, so you land on a clean `/` with a signed 30-day cookie.
4. If you did not set `DEEPSEEK_API_KEY` at deploy time, set it on the `dsh` service's Variables
   tab. It cannot be entered in the app: upstream allows editing settings only from a loopback
   page, so on a public domain *Settings → Models* reports "settings are unavailable in this
   browser". The same applies to every other pane under Settings.
5. Start a session. The LongMemory tools appear to the model as `mcp__longmemory__*` — recall,
   ingest, remember a decision, update task state, code graph and more.

**Existing browser sessions survive a redeploy**, because the cookie's signing secret lives in
`$DSH_HOME/.credentials.yaml` on the volume. To revoke every session, delete that record and
redeploy.

### Without the gate

Clearing `DSH_GATE_PASSWORD` turns off the edge gate *and* the automatic sign-in, and the deployment
falls back to DSH's own flow: open the `dsh` service's deploy logs, find

```
dsh web: http://127.0.0.1:7000/?token=…
```

and open `https://<your-dsh-domain>/?token=…` with that token. The loopback host in the printed URL
is correct and not a bug — `dsh --profile web` binds loopback by design; only the token matters. That
token is minted per process, so a redeploy prints a new one.

The two settings are deliberately coupled. Automatic sign-in means whoever reaches the index is
handed a DSH session, so the gate is what decides who may do that. Arming the convenience without
the credential would publish the harness.

## How it fits together

- **The `/api` trust fence is why `Host` must pass through.** Every DSH API call and WebSocket is
  checked before authentication: the request `Host` must be loopback or a `--trusted-host`, and an
  attached `Origin` must equal that `Host`. The entrypoint passes `RAILWAY_PUBLIC_DOMAIN` as a
  trusted host and Caddy leaves `Host` alone. Rewrite it and the page loads while every WebSocket
  answers **403** — measured, not inferred.
- **Authentication is DSH's own.** The index route accepts the launch token once, on `GET /`, and
  answers **401** to anything without a valid cookie; static assets stay public. A bad `Host` or
  `Origin` on `/api` is **403**. There is no method-level loopback bypass.
- **The edge gate is the sign-in, and it must run first.** Caddy applies HTTP basic auth when
  `DSH_GATE_PASSWORD` is set; `/up` bypasses it so the health check keeps working. The gate and the
  auto sign-in redirect live in a `route`, not a `handle`, because inside `handle` Caddy's directive
  order puts `redir` ahead of `basic_auth` — an unauthenticated `GET /` then answers **302** with the
  live token while every other path still answers 401, so the gate looks like it works and does not.
  `test-gateway.sh` probes exactly that case; it is the reason the file exists.
- **LongMemory is an MCP client row**, applied as a Cordis overlay (`--patch`) only when
  `LONGMEMORY_MCP_URL` is set. The client connects at boot; if LongMemory is still starting, the
  harness comes up without its tools and reconnects with backoff. Nothing in the overlay is
  deployment-specific — URL and key come from the environment.
- **Everything the agent accumulates is on the volume.** `/data/home` is the user's home (set in
  `/etc/passwd`, not only in `ENV`, because `gosu` resets `HOME` from passwd), `/data/dsh` is the
  harness home including the auto-initialised `profiles/web`, `/data/workspace` is where the agent
  works, and `mise use -g python@3.13` puts a toolchain under `/data/mise`.
- **The process runs as `dsh` (uid 1000)**, Caddy included. The entrypoint runs as root only long
  enough to create the volume subdirectories beside Railway's root-owned `lost+found`.

## Not included

- **Stable releases.** Upstream has shipped only alphas and release candidates; npm's `latest` tag
  is an rc. The pin is a version, not a tag, and it moves often.
- **The LongMemory dashboard.** Deploy the [LongMemory template](https://railway.com/deploy/longmemory)
  for that; this one runs the server only, privately.
- **Semantic recall out of the box.** Set `OPENAI_API_KEY` or `GEMINI_API_KEY` on `longmemory`.
- **Running sessions across redeploys.** Files survive; terminals and in-flight agent turns do not.
- **Docker inside the box.** Railway containers are unprivileged.

## Upgrading

- DSH: bump `DSH_VERSION` in `dsh/Dockerfile` and push. Check the
  [release notes](https://github.com/deepseek-ai/deepseek-harness/releases) — the web surface, the
  trust fence and the MCP client are all young and change between rcs.
- mise: bump `MISE_VERSION` and the two digests.
- LongMemory: pinned in its own template repository.

## Files

```
dsh/Dockerfile                    node:22 + @deepseek-ai/dsh + Caddy binary + mise
dsh/entrypoint.sh                 volume prep, trusted hosts, optional gate, LongMemory overlay, gosu
dsh/Caddyfile                     /up for the health check; Host passthrough to 127.0.0.1:7000
dsh/longmemory.cordis.patch.yml   the MCP client row
dsh/railway.json                  builder and health check
```

## Licences

DSH is [MIT](https://github.com/deepseek-ai/deepseek-harness/blob/main/LICENSE). "DeepSeek Harness"
is a trademark of DeepSeek; this project follows upstream's
[brand guidelines](https://github.com/deepseek-ai/deepseek-harness/blob/main/BRAND_GUIDELINES.md)
and uses the "DSH" designation. LongMemory is
[Apache-2.0](https://github.com/CaviraOSS/LongMemory/blob/main/LICENSE). The glue here is MIT.
