# lab-bootstrap

Reproducible provisioning for the AI lab host (**YUL‑SKUNK**) — working toward the goal:

> deploy a fresh Ubuntu box, run **one** thing, and end up exactly where the lab is
> now — nothing lost, fully working.

The guiding rule: **everything the lab runs is a git‑backed [Dokploy](https://dokploy.com) project**, created through Dokploy's API — never a container dropped on the host by hand. Hand‑run containers are invisible to Dokploy (and to the DevHub portal, which lists apps from Dokploy's `project.all`), so they can't be managed, monitored, or reproduced.

> Status: `bootstrap-apps.sh` **verified end‑to‑end on 2026‑07‑05** against Dokploy **v0.29.8**.

---

## Contents

- [What's here](#whats-here)
- [Quick start](#quick-start)
- [Options & environment](#options--environment)
- [How it works](#how-it-works)
- [Safety & idempotency](#safety--idempotency)
- [Dokploy v0.29.8 API notes](#dokploy-v0298-api-notes) — the hard‑won gotchas
- [Troubleshooting](#troubleshooting)
- [Roadmap](#roadmap)
- [Repo layout](#repo-layout)

---

## What's here

### `bootstrap-apps.sh`

Imports two previously hand‑run apps into Dokploy as tracked projects, so they appear in Dokploy and in the DevHub portal's app picker with full **start / stop / restart / redeploy** controls.

| App | Becomes | Source | Domain | Data |
|-----|---------|--------|--------|------|
| **OpenClaw** | Dokploy **Compose** project | the existing raw `openclaw-prod` compose (embedded in the script) | `claw.ai.alshawwaf.ca` → `:18789` | reuses the existing `openclaw-prod_openclaw-config` / `openclaw-prod_openclaw-workspace` volumes via `external:` refs — **nothing lost** |
| **Threat Prevention** | Dokploy **Application** | built from [`alshawwaf/cp_demo_server`](https://github.com/alshawwaf/cp_demo_server) branch **`GA`**, via its `Dockerfile` | `demo.ai.alshawwaf.ca` → `:8080`, HTTPS/Let's Encrypt | stateless |

For each app it: creates the project → resolves the default environment → creates the service → applies its config (raw compose + env, or git provider + Dockerfile build) → attaches the domain → deploys → waits until it's up → **then** retires the old thing (stop the old compose / remove the old container + stale Traefik route).

---

## Quick start

**Prerequisites**
- Run **on the Dokploy host** (or anywhere that can reach it). Needs `curl`, `jq`, `docker`.
- A **Dokploy API key**: Dokploy → **Settings → API**.

```bash
export DOKPLOY_TOKEN='<your-dokploy-api-key>'

./bootstrap-apps.sh --dry-run   # preview: reads only, prints intended mutations (secrets redacted)
./bootstrap-apps.sh             # apply: prompts before each destructive cutover
```

`DOKPLOY_URL` defaults to `http://localhost:3000`. Re‑running is safe — it skips anything already created (see [Safety & idempotency](#safety--idempotency)).

---

## OpenClaw pairing (`openclaw-pair.sh`)

OpenClaw's Control UI pairs **per device** — an unapproved browser gets "pairing required". This helper (run on the host) manages that:

```bash
./openclaw-pair.sh list      # show pending + paired devices
./openclaw-pair.sh approve   # approve the most recent pending browser (unblocks it)
./openclaw-pair.sh url       # print a tokenized dashboard URL for the public domain
```

`url` prints `https://claw.ai.alshawwaf.ca/#token=…` — paste it into **dev‑hub → OpenClaw → Edit App → Embed URL** (stored encrypted) so the OpenClaw window opens **already connected**, no pairing. The URL embeds a live operator token, so it's printed to your terminal only and never committed. Override the domain with `OPENCLAW_PUBLIC_URL`.

---

## Options & environment

| Flag | Effect |
|------|--------|
| `-n`, `--dry-run` | Print the mutations that *would* run (secret‑bearing bodies redacted); change nothing. |
| `-y`, `--yes` | Skip the confirmation prompts on destructive cutover steps. |
| `-h`, `--help` | Usage. |

| Env var | Default | Notes |
|---------|---------|-------|
| `DOKPLOY_TOKEN` | *(required)* | Dokploy API key. Read from the env only — never printed or stored. |
| `DOKPLOY_URL` | `http://localhost:3000` | Base URL of the Dokploy API. |
| `ASSUME_YES` | `0` | Same as `--yes`. |

---

## How it works

Dokploy's control API lives at `<DOKPLOY_URL>/api/<procedure>` (a `trpc-openapi` surface), authenticated with the `x-api-key` header. The script drives it with two small helpers:

- **`api METHOD PROC [BODY]`** — mutations (`POST`) and the plain `project.all` read (`GET`). Bodies are sent as **compact JSON** with `Content-Type: application/json`. On any non‑2xx it prints Dokploy's exact response (e.g. the `zodError`) and exits — so a schema mismatch is obvious and nothing half‑applies.
- **`projects_json`** — a tolerant `GET project.all`. **All** state reads (status polling, "does this service already exist?", "is the domain attached?") go through this one call, because it's the only query that returns reliably on this build (see the API notes). It returns every project → `environments[]` → `applications[]` / `compose[]`, each carrying its status, domains, and env.

The create → configure → deploy → verify → cutover sequence per app is described in [What's here](#whats-here).

---

## Safety & idempotency

- **Idempotent.** Re‑running detects existing projects/services via `project.all` and skips creation. OpenClaw is left **completely untouched** when it's already running (no needless redeploy).
- **Secret‑safe.** `DOKPLOY_TOKEN` comes from the env and is never echoed. OpenClaw's env values are read from the host's `.env` at runtime and passed straight into the API call — never printed. `--dry-run` redacts the `env` field.
- **Destructive steps are gated.** Stopping the old compose, `docker rm` of the old container, and Traefik‑route removal happen **only** after the replacement is confirmed up, **and** behind a confirm prompt (unless `--yes`). Data volumes are never deleted (`compose down` **without** `-v`); removed Traefik route files are backed up (`.bak-<timestamp>`) first.
- **Fails safe.** On any API validation error the script stops before mutating further; on a deploy that doesn't come up, the old thing is left in place.

---

## Dokploy v0.29.8 API notes

Hard‑won while getting this to run — **not obvious from the source**, and likely to bite anyone scripting Dokploy:

1. **Mutation bodies must be compact, single‑line JSON.** `jq` pretty‑prints by default; a multi‑line body makes Dokploy return `400 "Invalid JSON"` (it's `@trpc`'s `PARSE_ERROR`). Pipe every body through `jq -c`.
2. **Reads go through `project.all`, not the `*.one` queries.** `project.one` / `compose.one` / `application.one` / `domain.byApplicationId` don't return usefully on this build; `project.all` (a plain `GET`, no input) does, and it already contains status + domains + environments. Using `*.one` hung the status poll and broke idempotency.
3. **Several create fields are `nonoptional` but undocumented** — revealed one at a time via `zodError`:
   - `application.saveGitProvider` → `watchPaths: []`
   - `application.saveBuildType` → `herokuVersion: ""`, `railpackVersion: ""` (plus `dockerfile`, `dockerContextPath`)
   - `domain.create` → `internalPath: "/"`, `forwardAuthEnabled: false` (plus `path`, `stripPath`)
4. **Return shapes:** `project.create` → `{ project: { projectId } }`; `compose.create` / `application.create` return the object with `.composeId` / `.applicationId`.
5. **`deploy` is asynchronous** — `compose.deploy` / `application.deploy` trigger the build; poll `project.all` for `composeStatus` / `applicationStatus` reaching `running`/`done`.
6. **A subtle bash trap** (not Dokploy's fault) cost the most time: `--data "${body:-{}}"` does **not** mean "body or `{}`". Bash parses `${x:-{}}` as `${x:-{}` (default `{`) + a literal `}`, so a non‑empty body gets a stray `}` appended → invalid JSON. Use a clean default: `b="${body:-}"; [ -n "$b" ] || b="{}"`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `400 Invalid JSON` on a mutation | Body wasn't compact JSON (see API note 1), or the `${body:-{}}` brace trap (note 6). |
| `415 Unsupported/Missing content-type` | Mutations need `-H "Content-Type: application/json"`. |
| `zodError: <field> ... expected nonoptional` | A required field is missing from that call's body — add it (see note 3). |
| Clone fails: `Remote branch <x> not found` | Wrong branch. `cp_demo_server`'s default branch is **`GA`** (`git ls-remote --heads <repo>` to check). |
| `demo.ai` returns 404 after a failed deploy | The old container/route was already removed and the new build failed → nothing serving. Fix the build cause and re‑run; Dokploy re‑creates the route on a successful deploy. |
| Status poll shows blank/`unknown` forever | `project.all` couldn't be read, or the service id didn't match — check `DOKPLOY_TOKEN` and that `project.all` returns JSON. |

> **Known caveat:** the "app is serving" gate can be fooled during cutover if the *old* service still answers the domain (it once let cutover remove a container while the new build was actually failing). Prefer `--dry-run` first, and watch the deploy log. Hardening this gate (require a genuinely successful new deployment before retiring the old one) is on the list.

---

## Roadmap — full‑host reproducibility

1. ✅ **Import the two hand‑run apps** as Dokploy projects (`bootstrap-apps.sh`).
2. **Externalize** each app's compose/Dockerfile into git so every project is buildable from scratch (`cp_demo_server` already is; OpenClaw's compose is embedded here for now).
3. **`install-host.sh`** — on a bare Ubuntu box: install Docker + Dokploy, restore Traefik config, then create every project via the same API pattern used here.
4. **`bootstrap.sh`** — one entrypoint that runs the whole chain end‑to‑end.

---

## Repo layout

```
bootstrap-apps.sh   # import OpenClaw + Threat Prevention into Dokploy (idempotent)
openclaw-pair.sh    # approve OpenClaw devices / print a tokenized dashboard URL
README.md           # this file
.gitignore          # blocks .env / keys / *.bak so no secret is committed
```

## Notes

- **No secrets are committed.** The Dokploy token and app `.env` values are supplied at runtime (env / the host's existing `.env` files). `.gitignore` blocks `.env`, `*.key`, `*.pem`, `*.bak-*`.
- Pinned to Dokploy **v0.29.8**. If Dokploy is upgraded, re‑verify the API contract in the [API notes](#dokploy-v0298-api-notes) — field names and required‑field sets do change between versions.
