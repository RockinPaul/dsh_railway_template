# Deploy and Host DSH with LongMemory on Railway

[DSH](https://github.com/deepseek-ai/deepseek-harness) is DeepSeek Harness, DeepSeek's open-source
coding agent: a model that reads your files, runs shell commands and keeps working through a long
task, with a browser UI. This template runs DSH 0.1.5-rc.1 on Railway and pairs it with a
[LongMemory](https://github.com/CaviraOSS/LongMemory) server as an MCP tool server, so the agent
can recall, store decisions and track task state across sessions. Built on DeepSeek Harness; not
affiliated with or endorsed by DeepSeek.

## About Hosting DSH

DSH's web surface is built to run on your own machine: it binds loopback only and refuses to listen
on all interfaces. This template therefore puts Caddy in the same container, answering the platform
health check itself and forwarding to the harness. The forwarding has one non-negotiable property —
the browser's `Host` header passes through untouched — because DSH checks every API call and
WebSocket against a trust fence that requires the request `Host` to be a trusted authority and any
`Origin` to match it. The template registers your Railway domain as trusted at boot.

Sign-in is a password you copy once from the service's Variables tab. Underneath it is still DSH's
own session: DSH mints a fresh launch token at every process start and trades it for a signed 30-day
cookie, and the token cannot be preset by flag, environment or config. Left alone that would mean
reading a token out of the deploy logs on every first visit, so the gateway does the exchange for
you — it holds the current token and walks your browser through DSH's ordinary sign-in the moment
you clear the password prompt. The password is a normal service variable, so it does not rotate,
and the cookie's signing secret lives on the volume, so redeploys do not sign you out. Your
workspace, sessions, settings, credentials and any toolchain you install also live on the volume.

## Common Use Cases

- Run a coding agent on a machine that stays awake, and check on it from any browser.
- Give the agent memory that outlives a session: decisions, task state and project context stored
  in LongMemory and recalled through MCP tools.
- Keep a project's toolchain and repositories in one persistent place, separate from your laptop.

## Dependencies for DSH Hosting

- A **DeepSeek API key**, set at deploy time or later under *Settings → Models*.
- Two volumes, created by the template: one for the agent's home and workspace, one for
  LongMemory's database.
- Optionally, an OpenAI or Gemini key on the `longmemory` service for semantic recall. Without one,
  LongMemory matches on shared words rather than meaning, and says so in its log.

### Deployment Dependencies

- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) — upstream project (MIT);
  [documentation](https://deepseek-harness.github.io/deepseek-harness/).
- [LongMemory](https://github.com/CaviraOSS/LongMemory) — memory server (Apache-2.0).
- [Template repository](https://github.com/RockinPaul/dsh_railway_template) (MIT) and the
  [LongMemory template repository](https://github.com/RockinPaul/longmemory_railway_template) it
  builds the memory service from.
- [Caddy](https://caddyserver.com) (Apache-2.0) and [mise](https://mise.jdx.dev) (MIT).

### Implementation Details

Two services:

- **dsh** — the only public service. `node:22-bookworm-slim` with `@deepseek-ai/dsh` 0.1.5-rc.1
  installed from npm (the package hard-depends on the built web frontend), the Caddy 2.11 binary,
  and mise for toolchains. Health check `/up`, answered by Caddy. Volume at `/data` holding the
  home directory, the harness home, the workspace, the npm prefix and mise data. Runs as an
  unprivileged user whose home is on the volume.
- **longmemory** — private, no public domain. Built from a pinned upstream commit, SQLite on its own
  `/data` volume, health check `/health`. Its API key is generated per deployment and handed to
  `dsh` as a service reference, along with its private-network address.

The LongMemory connection is a Cordis configuration overlay applied at boot when the service
reference is present. The MCP client negotiates at startup and exposes thirteen tools to the model
as `mcp__longmemory__*` — recall, ingest, remember a decision, update task state, explain, code
graph and more. If LongMemory is still starting, the harness comes up without those tools and
reconnects with backoff.

**First run:** open your `dsh` domain. The browser asks for a username and password: they are
`DSH_GATE_USER` and `DSH_GATE_PASSWORD` on the `dsh` service's Variables tab, generated for your
deployment. That is the whole sign-in — DSH's own session is established for you behind it. If you
left the API key blank, paste it under *Settings → Models*.

Clearing `DSH_GATE_PASSWORD` turns the gate off, and with it the automatic sign-in: the deployment
falls back to DSH's own token URL, printed on the `dsh web:` line of the deploy logs, which you open
as `https://<your-dsh-domain>/?token=…`. The two move together on purpose. The gate is what decides
who may reach the sign-in exchange, so a deployment that removed the gate but kept the convenience
would hand a session to whoever loaded the page.

Three things to know. Upstream has shipped only alphas and release candidates so far, and releases
land every few days; the pinned version moves accordingly. Running sessions end on redeploy — files
survive, in-flight agent turns do not. And the gate, the exchange, the fence and the MCP client were
all measured against the running service: without the gate password every path answers 401 while the
health check stays open, a foreign `Host` or `Origin` on the API is 403, and a cookie issued before a
redeploy authenticates after it.

## Why Deploy DSH on Railway?

Railway is a singular platform to deploy your infrastructure stack. Railway will host your
infrastructure so you don't have to deal with configuration, while allowing you to vertically and
horizontally scale it.

By deploying DSH on Railway, you are one step closer to supporting a complete full-stack
application with minimal burden. Host your servers, databases, AI agents, and more on Railway.
