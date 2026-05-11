# hevy-mcp: design journal

A chronological, append-only log of decisions and surprises while adapting
`chrisdoc/hevy-mcp` (a stdio-only MCP for the Hevy Fitness API) into a remote
HTTPS endpoint deployable as a custom connector in claude.ai.

> **Where the playbook lives:** the generalisable architecture and step-by-step
> are in `~/dev/ai-skills-develop/skills/devops/remote-mcp-wrap/SKILL.md`.
> This journal only captures **Hevy-specific** decisions, surprises, and
> deviations. If something is generic to "wrap any stdio MCP for claude.ai
> remote consumption", it belongs in the skill, not here.

## Goal

Expose the user's Hevy workout/routine data to claude.ai as a remote MCP
connector, joining the existing fitness-data stack: IcuSync (intervals.icu),
FatSecret (nutrition), and the Wahoo Kickr.

Target: `https://hevy-mcp.christhonie.co.za/mcp`.

## Starting context (upstream survey)

From the upstream at `~/dev/hevy-mcp/` (fork of `chrisdoc/hevy-mcp`):

| Aspect                          | State                                                                                                                                |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| MCP SDK                         | `^1.29.0` (current) — newer than what fatsecret-mcp started with.                                                                    |
| Transport                       | **stdio only** ([src/index.ts:42, :99](../src/index.ts) — `StdioServerTransport`).                                                   |
| Upstream auth model             | **Single API key**, env `HEVY_API_KEY` or CLI `--hevy-api-key=…` ([src/utils/config.ts:34](../src/utils/config.ts)). No OAuth dance. |
| Tool count                      | 25, across `workouts.ts`, `routines.ts`, `templates.ts`, `folders.ts`, `body-measurements.ts`, `webhooks.ts`.                        |
| API client generation           | Kubb generates typed clients from `openapi-spec.json`. Generated files in `src/generated/` — do not edit.                            |
| Dockerfile                      | Stub; deprecated upstream (intentionally fails to build). Will be replaced.                                                          |
| Existing remote-deployment docs | None — `docs/` contains only `TYPE_SAFETY_GUIDE.md`.                                                                                 |
| Node                            | requires `>=24.0.0` ([package.json:94](../package.json)).                                                                            |

## Why this is much easier than FatSecret

The dominant cost in the FatSecret build was OAuth 1.0a 3-legged auth to the
upstream API — the bootstrap CLI, the access-token persistence, debugging
HMAC-SHA1 signature generation, the 24-hour IP whitelist propagation. None
of that applies here:

- **No upstream OAuth.** A single `HEVY_API_KEY` lives in the Secret. No
  bootstrap CLI to build, no human-in-loop authorize step, no token
  refresh.
- **No discovered IP whitelist on the Hevy API** _yet — research item below._
- **The MCP SDK is already current.** No version bump needed for transport
  support.

The reused architecture for claude.ai-facing auth (OAuth 2.1 + PKCE
authorization server, `MinimalOAuthProvider`, `mcpAuthRouter`,
`requireBearerAuth`) is identical to FatSecret and copies verbatim.

## Research findings

- **API base URL:** `https://api.hevyapp.com` (`src/index.ts:53`,
  `src/utils/hevyClientKubb.ts:56`). Single env-var, no per-region wrinkle.
- **IP restrictions:** unknown — Hevy's public docs are a Swagger UI SPA
  that doesn't render via WebFetch, and no third-party source mentions
  IP allow-lists. The upstream client/spec contains no 429 / IP-related
  code paths. **Plan: don't pre-whitelist. If we hit an IP-block error
  at runtime, run the egress probe documented in the skill and add the
  three node IPs.** Likelihood: low (most API-key services don't IP-gate).
- **Rate limits:** also unknown from the docs. No `X-RateLimit-*` handling
  in the upstream. **Plan: rely on observation. Add backoff only if we
  see 429s.**
- **Webhooks:** outbound from Hevy to a user-configured URL. The MCP
  tools (`get/create/delete_webhook_subscription`) are _CRUD on Hevy's
  subscription resource_ — they let the user point Hevy at a webhook
  URL, but they don't require this server to _receive_ anything.
  **Plan: ship the tools as-is. Do not add a webhook-receiver endpoint
  in v0.1.0; that's a separate project (receive POST, push event to
  claude.ai via some channel — non-trivial and not on the critical
  path).** If the user calls `create_webhook_subscription`, the
  webhook URL they supply must be a separate service.

## Decisions to make at plan time

1. **Image registry & tag.** Follow FatSecret pattern:
   `docker.io/christhonie/hevy-mcp:0.1.0`, public Docker Hub.
2. **K8s namespace.** Reuse `mcp` (matches FatSecret) or create `hevy-mcp`?
   Leaning `mcp` — keeps related connectors co-located, smaller blast
   radius, one ingress class config to maintain.
3. **Hostname.** `hevy-mcp.christhonie.co.za` (consistent with fatsecret).
4. **Webhooks.** Implement now or defer? Depends on the research above.

## Pattern reused from fatsecret-mcp (no rederivation needed)

- Streamable HTTP transport wrapper with per-session `McpServer`
  instances — copy `src/http-server.ts` and swap the upstream class
  import + env-var names.
- OAuth 2.1 provider — copy `src/oauth-provider.ts` verbatim.
- Dockerfile (node:20-alpine multistage, non-root uid 1001, port 8000,
  HEALTHCHECK on /healthz) — replaces the upstream's deprecated stub.
- K8s `Deployment` / `Service` / `Ingress` / `secret.template.yaml` —
  copy from `~/dev/fatsecret-mcp/k8s/` and rename.
- ArgoCD `Application` manifest in
  `~/dev/idl-xnl-jhb-rc01/argocd/hevy-mcp.yml` — clone fatsecret's,
  point at this repo.
- The bearer-token misstep from fatsecret-mcp v0.1.0 is **not** repeated
  — we go straight to OAuth 2.1.

## Append below as work progresses

Each new entry: date, what was done, what was surprising or required a
decision. Newest at the bottom.

### 2026-05-12 — initial journal + execution start

- Wrote this document. Captured upstream survey + research findings.
- Three FatSecret-pattern capture artifacts also shipped:
  - `~/dev/ai-skills-develop/skills/devops/remote-mcp-wrap/SKILL.md`
    (generalisable playbook, auto-discovered by Claude).
  - `~/dev/fatsecret-mcp/README.md` — Generalising-this-pattern section.
  - This journal.

### 2026-05-12 — upstream surprises that need handling

- **Sentry is baked in.** `src/index.ts:32` initialises Sentry with a
  hardcoded DSN pointing at the upstream maintainer's project
  (`o4508975499575296.ingest.de.sentry.io`). Every tool call's tracing
  data would leak to a third party. **Decision:** patch the DSN to be
  env-overridable (`process.env.SENTRY_DSN ?? <upstream default>`);
  deployment sets `SENTRY_DSN=""` to disable. Minimal upstream-merge
  surface (one line). Considered fully ripping Sentry out but kept the
  optional capability for local debugging.
- **Node 24+ required** per `package.json:94`. Dockerfile uses
  `node:24-alpine` (FatSecret was on 20). Confirmed `node:24-alpine`
  exists on Docker Hub.
- **Build is `tsdown`, not `tsc`.** Outputs `dist/*.mjs`. New
  http-server entry point must be added to `tsdown.config.ts:entry`.
- **`buildServer(apiKey)` factory exists** (`src/index.ts:65`) and is
  cleanly reusable. Per-session integration is one call. Cleaner than
  FatSecret, which embedded the McpServer construction in a class.
