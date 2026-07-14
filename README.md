# Ubuntu Dokploy AI

**One command turns a fresh Ubuntu server into the full Check Point AI & agentic demo stack** — [Dokploy](https://dokploy.com) PaaS, Traefik TLS, and ~15 apps: hardened, deployed, and verified for you.

[![Part of the Dev Hub ecosystem](https://img.shields.io/badge/part_of-Dev_Hub_ecosystem-8B5CF6?style=flat-square)](https://github.com/alshawwaf/dev-hub)
![Ubuntu 22.04 / 24.04](https://img.shields.io/badge/Ubuntu-22.04_·_24.04-E95420?style=flat-square&logo=ubuntu&logoColor=white)
![One-command install](https://img.shields.io/badge/install-one_command-22C55E?style=flat-square&logo=gnubash&logoColor=white)

```bash
curl -fsSL https://raw.githubusercontent.com/alshawwaf/ubuntu-dokploy-ai/main/install.sh | sudo bash -s -- --domain yourdomain.com
```

You bring **Ubuntu and a domain**. The script installs Docker and Dokploy, generates every secret, sets up ingress (Let's Encrypt **or** Cloudflare Tunnel), deploys the whole suite from one config file, and verifies every app actually serves before it says "done". Images are **prebuilt on GHCR** — the box pulls, it never compiles. The run **survives SSH drops**, shows a **live dashboard** while it works, and tears everything down again with `--uninstall`.

**Contents:**
[What you get](#what-you-get) ·
[Quick start](#quick-start) ·
[Prerequisites](#prerequisites) ·
[How it works](#how-installsh-works) ·
[Live dashboard](#the-live-dashboard) ·
[Configuration](#configuration) ·
[Access](#accessing-your-stack) ·
[Uninstall](#uninstall) ·
[Security](#security) ·
[Reference](#reference) ·
[Repository layout](#repository-layout) ·
[Troubleshooting](#operations--troubleshooting)

---

## What you get

Every app is published at its own `https://<app>.<DOMAIN>` subdomain via Traefik. The catalog, domains, and ports live in [`automation/dokploy_config.json`](automation/dokploy_config.json) — that file is the source of truth; this table is a snapshot.

| App | URL | What it is |
|---|---|---|
| **Dev Hub** | `hub.<DOMAIN>` | macOS-desktop-style portal that ties the suite together and embeds each app in a window |
| **CP Agentic MCP Playground** | `n8n.` · `chat.` · `flowise.` · `langflow.<DOMAIN>` | Build AI agents (n8n, Open WebUI, Flowise, Langflow) over Check Point MCP servers, with Langfuse tracing at `trace.<DOMAIN>` |
| **PolicyPilot** | `policypilot.<DOMAIN>` | Turn plain-language / ticket requests into safe Check Point access-policy changes |
| **Drawbridge** | `dcsim.<DOMAIN>` | Datacenter Simulator serving Check Point / CloudGuard-format datacenter feeds for PoV demos |
| **AI Guardrails Playground** | `guardrails.<DOMAIN>` | Test LLM prompt-injection / jailbreak guardrails across providers |
| **AI-Infra-Guard** | `aig.<DOMAIN>` | AI red-teaming: MCP security scanning + jailbreak evaluation |
| **Threat Prevention Server** | `threat.<DOMAIN>` | Check Point threat-prevention demo / data server |
| **Training Portal** | `training.<DOMAIN>` | Hands-on lab portal (Apache Guacamole remote access) |
| **AI Basic Training** | `learn.<DOMAIN>` | Introductory AI / security training portal |
| **Docs to Swagger** | `swagger.<DOMAIN>` | Convert Check Point API docs into browsable OpenAPI / Swagger |
| **Identity Provider (IdP)** | `idp.<DOMAIN>` | SAML / SCIM Identity Provider simulator for SSO demos |
| **OpenClaw** | `claw.<DOMAIN>` | Third-party agentic browser, embedded in the hub |
| **Script Builder** | `scriptbuilder.<DOMAIN>` | Check Point script builder (private repo — see [Private repositories](#private-repositories-script-builder)) |
| Ollama · PostgreSQL · Qdrant · Langfuse | *internal* | Backends for the agentic stack — never exposed to the internet |

**Preconfigured agents.** The agentic app auto-imports ready-to-run n8n workflows on deploy: a Docker MCP Gateway fronting every Check Point MCP server (a direct-connection agent and a `*-via-gateway` twin for each), plus PolicyPilot and Dev Hub agents — bearer tokens and `<DOMAIN>` substituted at import time. See [cp-agentic-mcp-playground](https://github.com/alshawwaf/cp-agentic-mcp-playground), [PolicyPilot](https://github.com/alshawwaf/PolicyPilot), and [dev-hub](https://github.com/alshawwaf/dev-hub). For the wider story — audience, architecture, the MCP fleet — read [docs/PLATFORM_OVERVIEW.md](docs/PLATFORM_OVERVIEW.md).

---

## Quick start

There are two ingress modes — pick the one that matches your host:

| Mode | Use when | How apps get TLS |
|---|---|---|
| `letsencrypt` *(default)* | The host has **public inbound** `80`/`443` (VPS, cloud VM) | Traefik issues Let's Encrypt certs via HTTP-01; a wildcard DNS `A` record points at the host |
| `tunnel` | The host has **no public inbound** (home server, NAT, CGNAT) | A Cloudflare Tunnel dials out to Cloudflare's edge; edge TLS is free — no port-forwarding, no public `A` record |

### Public host — Let's Encrypt (default)

Add the wildcard `A` record (see [Prerequisites](#prerequisites)), then on the box, as root:

```bash
curl -fsSL https://raw.githubusercontent.com/alshawwaf/ubuntu-dokploy-ai/main/install.sh | sudo bash -s -- --domain yourdomain.com
```

### Private / NAT host — Cloudflare Tunnel

Put your Cloudflare credentials in an answers file first (see [Configuration](#answersenv)), then:

```bash
curl -fsSL https://raw.githubusercontent.com/alshawwaf/ubuntu-dokploy-ai/main/install.sh | sudo bash -s -- --domain yourdomain.com --ingress tunnel --answers /path/to/answers.env
```

To prepare the answers file:

```bash
git clone https://github.com/alshawwaf/ubuntu-dokploy-ai.git && cd ubuntu-dokploy-ai
cp answers.env.example answers.env
# edit answers.env: DOMAIN, CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID + any BYO API keys
sudo ./install.sh --domain yourdomain.com --ingress tunnel --answers answers.env
```

### The wipe → redeploy cycle

The two commands for a repeatable lab. Terminate (keeping the image cache and LLM weights, so the redeploy is fast):

```bash
curl -fsSL https://raw.githubusercontent.com/alshawwaf/ubuntu-dokploy-ai/main/install.sh | sudo bash -s -- --uninstall --yes --keep-images --keep-models --answers /path/to/answers.env
```

Reapply:

```bash
curl -fsSL https://raw.githubusercontent.com/alshawwaf/ubuntu-dokploy-ai/main/install.sh | sudo bash -s -- --domain yourdomain.com --ingress tunnel --answers /path/to/answers.env
```

For a wipe back to **bare Ubuntu**, swap the keep flags for `--remove-docker --purge-secrets`.

### Good to know

- **Idempotent** — generated secrets persist and are reused, installs are guarded, firewall rules re-apply cleanly. Re-running redeploys the apps.
- **Self-updating** — piped runs refresh their on-disk clone (`/opt/ubuntu-dokploy-ai`) from `main` at startup, so every run uses the latest installer.
- **Everything is logged** — the live panel shows the tail; the full raw output of every command lands in `/var/log/dokploy-ai-install.log`.
- **No `curl`?** Use the `wget` form: `wget -qO- https://raw.githubusercontent.com/alshawwaf/ubuntu-dokploy-ai/main/install.sh | sudo bash -s -- --domain yourdomain.com`.
- **Timing** — fresh Ubuntu ≈ 15–20 min (bandwidth-bound image pulls); wipe→redeploy with the keep flags ≈ 6–10 min.

---

## Prerequisites

### Both modes

- **Ubuntu 22.04 / 24.04 LTS** with root (the installer runs under `sudo bash`).
- A **domain you control**.

That's the whole list. You do **not** install Docker or anything else first — the script installs the Docker engine, the OS/Python packages, Dokploy, and every dependency itself, then deploys and verifies the stack. Already manage Docker yourself? Add `--skip-docker` and the script leaves it alone.

### Let's Encrypt mode

- A **public IP** with inbound `80`/`443` reachable from the internet.
- A **wildcard DNS `A` record** pointing at the host — the one manual step:

  ```text
  Type: A    Name: *    Value: <SERVER_IP>    TTL: 3600
  ```

  The installer verifies it and prints exactly what to add if it's missing, but does not create it. Traefik needs it to issue certificates for every `*.yourdomain.com` subdomain.

### Cloudflare Tunnel mode

For a home server or any NAT'd/CGNAT box with no reachable inbound ports. Full walkthrough in [docs/tunnel-ingress.md](docs/tunnel-ingress.md); in brief:

- The **domain hosted on Cloudflare** (nameservers pointed at Cloudflare; the free plan is fine).
- A **Cloudflare API token** ([create one](https://dash.cloudflare.com/profile/api-tokens)) with scopes `Account > Cloudflare Tunnel > Edit`, `Zone > DNS > Edit`, `Zone > Zone > Read`, plus your **account id**. Put both in `answers.env` (`CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`).
- **No port-forwarding and no `A` record** — the installer creates a proxied wildcard `CNAME` (`*.yourdomain.com` → the tunnel) and runs `cloudflared` as a systemd service.

> **Cert depth on the free plan:** Cloudflare's free Universal SSL covers the zone apex and **one** wildcard level (`yourdomain.com` + `*.yourdomain.com`). Pass the **zone apex** as `--domain` so apps land at `<app>.yourdomain.com`. A subdomain like `--domain ai.yourdomain.com` puts apps two levels deep, where the free cert does **not** reach — the installer warns you and names the zone to use. To go deeper, enable Cloudflare Advanced Certificate Manager / Total TLS first.

### Private repositories (Script Builder)

Most apps clone from public HTTPS repos and need nothing extra. **Script Builder** is the exception — it clones over SSH from a private repo, so it is **skipped by default** (a clear message, not a failure); every other app still deploys. To include it:

1. Print the key the installer generated (after at least one install attempt):

   ```bash
   sudo cat /root/.ssh/id_rsa.pub
   ```

2. On GitHub: **repo → Settings → Deploy keys → Add deploy key** — paste the key, leave *Allow write access* unchecked, save.
3. Re-run with `ALLOW_SSH_REPOS=1 sudo ./install.sh --domain yourdomain.com`.

---

## How `install.sh` works

A fixed **14-step pipeline**, each step a row on the [live dashboard](#the-live-dashboard):

| # | Step | What happens |
|---|---|---|
| 1 | **Preflight** | Piped runs (`curl \| bash`) first **materialize the repo on disk and re-exec from the file** — a dropped SSH session can never cut off the script's source mid-run. Then root/OS checks and domain/ingress resolution. |
| 2 | **Base packages** | Apt packages only (`python3-requests`, `python3-paramiko`, `python3-yaml`, `git`, `ufw`, `fail2ban`, `unattended-upgrades`) — no PyPI/pip. Detects the public IP and WAN interface. |
| 3 | **Base firewall** | `ufw` default-deny; allow `22/80/443` (only `22` in tunnel mode — the tunnel dials out). |
| 4 | **Docker engine** | Installed if absent, then Docker's address pools are **pinned to `10.201/10.202.0.0/16`** — the stock pools spill into `192.168.0.0/16` after ~16 networks and can black-hole SSH on a `192.168.x` management LAN. `--skip-docker` leaves an existing engine untouched. |
| 5 | **Dokploy platform** | Installed if absent. On resumed installs it also verifies the **`dokploy-traefik` container** exists and creates it if not — without it every app deploys but nothing listens on 80/443. |
| 6 | **Traefik hubframe middleware** | Strips `X-Frame-Options` / sets a permissive `frame-ancestors` CSP as a default middleware, so every app can embed in the Dev Hub desktop. |
| 7 | **Host hardening** | `DOCKER-USER` iptables chain (all app ports forced through Traefik), `fail2ban`, unattended upgrades, root key-only sshd, an `authorized_keys` audit — and on **vmxnet3** vNICs, NIC offloads are disabled (persisted) to stop corrupted-stream SSH drops under load. Skip with `--skip-harden`. |
| 8 | **Loopback SSH key** | Generated + self-authorized so Dokploy manages the box over `127.0.0.1` with no external exposure. |
| 9 | **Secrets & env rendering** | [`bootstrap_secrets.py`](automation/bootstrap_secrets.py) generates strong secrets into `/etc/dokploy-ai/secrets.env` (0600, reused every run) and renders every app `.env` from [`automation/envs/`](automation/envs/). |
| 10 | **Cloudflare Tunnel ingress** | *(tunnel mode)* [`setup_tunnel.py`](automation/setup_tunnel.py) provisions `cloudflared`, the named tunnel, the proxied wildcard `CNAME`, and the systemd service; neutralizes Traefik's forced-HTTPS redirect (edge TLS terminates at Cloudflare); gates the Dokploy dashboard behind basic auth at `dokploy.<DOMAIN>`. |
| 11 | **Agentic playground fetch** | Fetches [cp-agentic-mcp-playground](https://github.com/alshawwaf/cp-agentic-mcp-playground) to `/opt/cp-agentic-mcp-playground`. Idempotent — an existing checkout is updated in place, never re-cloned. |
| 12 | **DNS pre-check** | *(letsencrypt mode)* [`dns_precheck.py`](automation/dns_precheck.py) confirms the wildcard + every subdomain resolve; aborts with the exact record to add if not. `--skip-dns-check` / `--dns-warn-only` override. |
| 13 | **Core apps — hub + essentials** | [`dokploy_automate.py`](automation/dokploy_automate.py) registers the Dokploy admin and **triggers** the hub + lightweight apps. Dokploy deploys in submission order, so **`https://hub.<DOMAIN>` is reachable in a couple of minutes**. |
| 14 | **AI stack — models + agentic bundle** | Immediately queues the heavy tier behind core (`--tier heavy --no-purge` — it *adds* to the deployment, never clean-slates it), then runs **one verification pass over the whole board**: every app must have running containers *and* actually serve on its hosts. |

### Why installs are fast — prebuilt images

Every first-party app image is **prebuilt and published to GHCR** by its own repo's `publish-image.yml` workflow (buildx, `:latest` + `:sha` tags, public packages). The deploy composes *pull* (`pull_policy: always`) instead of compiling from source — which used to dominate install time with multi-GB on-box builds. The old `build:` blocks stay commented in each compose for local development.

**LLM model weights are fire-and-forget**: the download is triggered during the deploy and continues in the background after "Provisioning complete" — chat/agent apps are up immediately and answer prompts once their model lands. Watch progress with `docker logs -f ollama-pull-models-cpu`; a model appears in `ollama list` when ready. Uninstalling with `--keep-models` makes the next pull a no-op.

---

## The live dashboard

The installer picks a renderer automatically:

- **Rich dashboard** (interactive terminals) — painted in place on the *alternate screen*, so your shell and scrollback stay untouched. It **detects your real window size even through sudo's pty** and centers itself horizontally and vertically.
- **Plain mode** (piped output, `nohup`, dumb terminals) — clean numbered-step lines that read well in a log. Force with `--plain` or `NO_RICH_UI=1`.

The rich dashboard shows:

- The **14-step checklist** — animated spinner on the running step; `✔` done / `▲` warned / `⤼` skipped / `○` pending, each with its duration.
- A **contained live-output box** titled with the running step: output tail-follows *inside* the frame (the screen never scrolls), progress-style lines (docker layers, `overall progress: N/M`, apt) **update in place** on their own row, and the bottom border points at the full log. **Press `d`** any time to collapse the box to one line and again to expand it.
- **Two labeled progress bars** during the deploy waves: `overall` tracks the 14-step plan, `apps` tracks the live board — total progress never disappears mid-deploy.
- The **live app board**: each app's state in real time — `○` queued · `⠦` building · `✔` up · `▲` degraded · `✖` failed — with container counts, flipping to `✔ hub is live → https://hub.<DOMAIN>` the moment the hub answers.
- `--big` renders the whole dashboard in double-width (2×) text on terminals that support it.

And its guarantees:

- **The final view holds until you press a key — on success, failure, and uninstall.** A green `✔ provisioning complete` / `✔ uninstall complete` chip (or a red `✖ FAILED` banner naming the step) anchors under the frame until you dismiss it; then the run-summary table prints to your scrollback. Headless/CI runs and `HOLD=0` never block; `UI_HOLD_TIMEOUT` (default 600s) bounds a walk-away.
- **Nothing prints below the dashboard** — while the frame is up, all command output diverts into `/var/log/dokploy-ai-install.log` (the box shows the tail), so stray output can't scroll or flash the screen.
- **A dropped SSH session cannot kill the run.** The installer demotes itself to headless and finishes the deploy; re-attach with `sudo tail -f /var/log/dokploy-ai-install.log`. Want the *dashboard* to be reconnectable too? Run inside `tmux`.
- **Verification is real.** [`verify_deployment.py`](automation/utils/verify_deployment.py) polls Dokploy's deploy status *and* the actual containers *and* probes each app's hosts through Traefik — an app counts as up only when it serves. Tune with `VERIFY_TIMEOUT` (default 2700s) and `VERIFY_INTERVAL` (default 3s).

---

## Configuration

### `answers.env`

Copy [`answers.env.example`](answers.env.example) → `answers.env` (git-ignored). Only `DOMAIN` is required; everything else is optional. Bring-your-own keys you omit are reported at the end and simply leave that one integration disabled — the app still deploys.

| Key | When | Purpose |
|---|---|---|
| `DOMAIN` | **required** | Root domain the apps hang off |
| `DOKPLOY_ADMIN_EMAIL` / `DOKPLOY_ADMIN_PASSWORD` | optional | Override the Dokploy admin login (else generated + persisted) |
| `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` | tunnel mode | Cloudflare API token + account id |
| `CLOUDFLARE_TUNNEL_NAME` | tunnel, optional | Named tunnel to create/reuse (default `devhub`) |
| `DOKPLOY_GATE_USER` / `DOKPLOY_GATE_PASSWORD` | tunnel, optional | Basic-auth for `dokploy.<DOMAIN>` (default `admin` / the Dokploy admin password) |
| `OPENAI_API_KEY` · `GEMINI_API_KEY` · `ANTHROPIC_API_KEY` · `LAKERA_API_KEY` | optional | LLM / guardrail provider keys for the agentic + guardrails apps |
| `AZURE_OPENAI_API_KEY` · `AZURE_OPENAI_ENDPOINT` · `AZURE_OPENAI_DEPLOYMENT` | optional | Azure OpenAI is the default model behind every n8n agent — supply all three |
| `AZURE_CONTENT_SAFETY_KEY` / `AZURE_CONTENT_SAFETY_ENDPOINT` | optional | Azure Content Safety for the guardrails demo |
| `MANAGEMENT_HOST` · `MANAGEMENT_API_KEY` · `SMS_API_KEY` · `TE_API_KEY` · `REPUTATION_API_KEY` | optional | Check Point Quantum management / SMS / Threat Emulation / Reputation MCP integrations |
| `SPARK_MGMT_*` · `HARMONY_SASE_*` · `DOC_*` · `IPS_*` | optional | Spark, Harmony SASE, product-docs, and Infinity Portal IPS MCP integrations |
| `GAIA_GATEWAY_IP` · `GAIA_USERNAME` · `GAIA_PASSWORD` | optional | Gaia gateway for the Gaia MCP sidecar |
| `IDP_SCIM_TOKEN` | optional | SCIM bearer token for the IdP simulator |
| `COMPOSE_PROFILES` | optional | Agentic compose profiles; default `cpu`, add `security-lab` to enable those services |
| `DEMO_API_KEY` / `DEMO_PROJECT_ID` | optional | Lakera Guard credentials for the AI Guardrails demo |
| `VSPHERE_HOST` · `VSPHERE_USER` · `VSPHERE_PASSWORD` | optional | vSphere creds so the Training Portal can provision lab VMs + Guacamole consoles |

### Secrets model

Three buckets, all handled for you:

- **Generated** — DB passwords, JWT/encryption keys, admin passwords, gateway tokens: created with strong entropy, persisted to `/etc/dokploy-ai/secrets.env`, and **reused on every re-run** so a redeploy never rotates a live database password out from under its database. An explicit value in `answers.env` overrides and re-persists.
- **Bring-your-own** — external provider keys from the table above.
- **Derived** — hostnames and URLs built from `DOMAIN`.

No secret is ever written to a tracked file. To print the generated Dokploy admin password:

```bash
sudo awk -F= '/DOKPLOY_ADMIN_PASSWORD/{print $2}' /etc/dokploy-ai/secrets.env
```

### Ollama models

`OLLAMA_MODELS` (and the Open WebUI default via `OPEN_WEBUI_DEFAULT_MODELS`) in `automation/envs/.env_agentic` control what gets pulled. The CPU-friendly default is a small chat model, a light tool-calling model, and an embedding model; a commented-out extended set (reasoning + guardrail-target models) ships in the file. `OLLAMA_MAX_LOADED_MODELS=2` caps resident models. See [Operations → Ollama model management](docs/operations.md#ollama-model-management).

---

## Accessing your stack

Once DNS resolves and certs issue (or the tunnel connects), every app is live at `https://<app>.<DOMAIN>` — see [What you get](#what-you-get) for the full list.

The **Dokploy dashboard** depends on ingress mode:

- **`letsencrypt` mode** — port `3000` is firewalled off by design. Reach it via an SSH tunnel, then open `http://localhost:3000`:

  ```bash
  ssh -L 3000:localhost:3000 root@<SERVER_IP>
  ```

- **`tunnel` mode** — published at `https://dokploy.<DOMAIN>` behind a Traefik basic-auth gate (user `admin`, password = the Dokploy admin password, overridable via `DOKPLOY_GATE_USER` / `DOKPLOY_GATE_PASSWORD`).

---

## Uninstall

Full teardown of everything the installer put on the host, with the same live dashboard (9 steps) and the same hold-until-keypress ending:

```bash
sudo ./install.sh --uninstall [--answers answers.env] [--yes] \
                  [--keep-images] [--keep-models] [--purge-secrets] [--remove-docker]
```

**What it removes:** every container, swarm state, Docker volumes/networks (and images unless `--keep-images`), `/etc/dokploy`, `cloudflared` plus the Cloudflare **tunnel and only the DNS records pointing at it** (never anything else in the zone), the agentic clone, rendered `.env`/compose files, and the loopback `authorized_keys` entry.

**What it keeps:** host hardening (ufw/fail2ban/sshd/unattended-upgrades) is **always** kept — dropping it would expose the box. The Docker engine and the secrets store are kept unless you pass the matching purge flag. **Your `--answers` file is never deleted** — the uninstall only *reads* it (for the Cloudflare credentials), even with `--purge-secrets`.

| Flag | Effect |
|---|---|
| `--yes` | Skip the interactive `type "yes"` confirmation. **Required** for non-interactive uninstalls |
| `--keep-images` | Keep Docker images + build cache — a reinstall reuses the local cache |
| `--keep-models` | Keep the LLM weight volumes (Ollama model store) — the next install skips the multi-GB model downloads. Pair with `--keep-images` for the fastest cycle |
| `--purge-secrets` | Delete the *generated* secrets store (`/etc/dokploy-ai/secrets.env`) only — never your answers file; the next install regenerates all passwords |
| `--remove-docker` | `apt purge` the Docker engine and remove `/var/lib/docker` + `/var/lib/containerd` |
| `--answers <file>` | Read (never modify or delete) Cloudflare credentials for the tunnel + DNS cleanup |

> **Cloudflare safety:** the tunnel/DNS cleanup needs `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID`. If a tunnel is matched only by name and still has **active connectors** but no local credentials on this host, the uninstall refuses to delete it — it cannot take down a live tunnel another box is serving.

---

## Security

The hardening is grounded in two real 2026 compromises of the lab host — [docs/incident-report-2026-03-24.md](docs/incident-report-2026-03-24.md) (exposed PostgreSQL + default creds → cryptominer) and [docs/incident-report-2026-03-31.md](docs/incident-report-2026-03-31.md) (unauthenticated Langflow RCE + direct-port bypass).

Applied on every install (unless `--skip-harden`):

- **`ufw` default-deny** — only `22/80/443` inbound (`22` only in tunnel mode). A firewall alone would have prevented the first incident.
- **`DOCKER-USER` iptables chain** — all container traffic forced through Traefik on `80/443`, closing the direct-port bypass behind the second incident. The installer aborts if it can't detect the WAN interface (pass `WAN_IFACE=<iface>` to override).
- **No shipped secrets** — tracked composes reference `${VARS}` and fail closed if unset; strong values are generated at install.
- **`fail2ban`** (SSH jail), **unattended security upgrades**, **root key-only sshd**, and a baseline user/`authorized_keys` audit at `/etc/dokploy-ai/audit-baseline.txt`.
- **vmxnet3 offload workaround** — on ESXi VMs, NIC checksum/segmentation offloads are disabled (persisted via systemd) to stop long-lived connections dying under load with `ssh: message authentication code incorrect`.

**Port exposure policy** — database ports bind to `127.0.0.1` only; services talk over Docker networks:

| Port | Service | Binding |
|---|---|---|
| 5432 | PostgreSQL (agentic) | `127.0.0.1:5432` |
| 5433 | PostgreSQL (training) | `127.0.0.1:5433` |
| 11434 | Ollama | host-published, blocked externally by the `DOCKER-USER` chain |

---

## Reference

### `install.sh` flags

| Flag | Description |
|---|---|
| `--domain <d>` | Root domain (required; or `ROOT_DOMAIN` env, or `DOMAIN=` in `answers.env`) |
| `--answers <file>` | Answers file with domain + BYO secrets (default `answers.env`) |
| `--admin-email <e>` | Dokploy admin email (default `admin@<domain>`) |
| `--admin-password <p>` | Dokploy admin password (default: generated + persisted) |
| `--store <path>` | Secret store path (default `/etc/dokploy-ai/secrets.env`) |
| `--ingress <mode>` | `letsencrypt` (default) or `tunnel` |
| `--skip-harden` | Skip host hardening |
| `--skip-docker` | Don't install or reconfigure Docker — use the existing engine untouched |
| `--skip-dns-check` | Deploy even if DNS isn't ready (ignored in tunnel mode) |
| `--dns-warn-only` | Report DNS problems but continue |
| `--clean` | Tear down the existing project/servers before redeploying |
| `--plain` | Force plain numbered-step output |
| `--big` | Double-width (2×) dashboard text, on terminals that support DEC double-width |
| `--uninstall` | Full teardown mode (see [Uninstall](#uninstall)) |
| `--yes` / `--keep-images` / `--keep-models` / `--purge-secrets` / `--remove-docker` | Uninstall modifiers (see [Uninstall](#uninstall)) |
| `-h`, `--help` | Usage |

### `dokploy_automate.py` arguments

| Argument | Required | Default | Description |
|---|---|---|---|
| `--url` | yes | — | Dokploy URL, e.g. `http://1.2.3.4:3000` |
| `--email` / `--password` | yes | — | Dokploy admin credentials |
| `--domain` | yes | — | Root domain (or `ROOT_DOMAIN` env) |
| `--ip` | no | derived from `--url` | Server public IP |
| `--local-server` | no | off | Deploy on the Dokploy host itself; skip remote SSH setup |
| `--ssh-user` / `--ssh-password` | no | `adminuser` / — | SSH login for remote-server registration |
| `--ssh-private` / `--ssh-public` | no | `~/.ssh/id_rsa[.pub]` | SSH key paths |
| `--config` | no | `dokploy_config.json` | Apps config JSON |
| `--project` | no | `Agentic Demos` | Dokploy project name |
| `--app <name>` | no | — | Only process this single app |
| `--tier` | no | `all` | Deploy only `core`, `heavy`, or `all` (per-app `"tier"` in the config) |
| `--no-purge` | no | off | Don't clean-slate the environment first — **required on the second/heavy wave**, otherwise it deletes the first wave's apps |
| `--skip-harden` | no | off | Skip the built-in `harden_server` step |
| `--clean` | no | off | Fresh rebuild (delete project/servers first) |

### Environment variables

| Variable | Purpose |
|---|---|
| `ROOT_DOMAIN` | Root domain (alternative to `--domain`) |
| `INGRESS_MODE` | `letsencrypt` or `tunnel` (alternative to `--ingress`) |
| `ALLOW_SSH_REPOS` | `1` includes private SSH-repo apps once a deploy key is registered |
| `WAN_IFACE` | Interface the `DOCKER-USER` chain guards |
| `DOKPLOY_HOST_IP` | Host IP used for the AI Guardrails → Ollama URL and DNS check |
| `DEV_HUB_COMPOSE_PATH` / `AGENTIC_COMPOSE_PATH` | Compose paths (rendered dev-hub / cloned agentic playground) |
| `NO_RICH_UI` | `1` forces plain output (same as `--plain`) |
| `BIG` | `1` enables double-width text (same as `--big`) |
| `HOLD` / `UI_HOLD_TIMEOUT` | `HOLD=0` skips the end-of-run hold; the timeout bounds it (default `600`s) |
| `RUN_LOG` | Install log path (default `/var/log/dokploy-ai-install.log`) |
| `VERIFY_TIMEOUT` / `VERIFY_INTERVAL` | Full-board verification timeout / poll interval (defaults `2700`s / `3`s) |
| `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` | *(tunnel)* Cloudflare credentials |
| `CLOUDFLARE_TUNNEL_NAME` / `CLOUDFLARE_RECREATE_TUNNEL` | *(tunnel)* tunnel name (default `devhub`) / force recreate |
| `DOKPLOY_GATE_USER` / `DOKPLOY_GATE_PASSWORD` | *(tunnel)* basic-auth for `dokploy.<DOMAIN>` |

### Deploy to a remote host from your laptop

The one-liner runs on the box. To provision a **remote** host from your workstation, drive [`dokploy_automate.py`](automation/dokploy_automate.py) directly — it installs Docker + Dokploy over SSH, registers the server, and deploys:

```bash
# 1. DNS: wildcard A record (see Prerequisites)

# 2. Generate secrets + render env files locally (writable store, not /etc)
cp answers.env.example answers.env      # set DOMAIN + any BYO keys
python3 automation/bootstrap_secrets.py --domain yourdomain.com \
  --answers answers.env --store ./secrets.env
export DEV_HUB_COMPOSE_PATH="$PWD/automation/dev_hub_compose.rendered.yml"
export WAN_IFACE=eth0                    # the REMOTE host's default interface

# 3. Deploy (requests + paramiko must be importable locally)
python3 automation/dokploy_automate.py \
  --url "http://<SERVER_IP>:3000" \
  --domain "yourdomain.com" \
  --email "admin@yourdomain.com" --password "<ADMIN_PASSWORD>" \
  --ssh-user "<SSH_USER>" --ssh-private ~/.ssh/id_rsa \
  --clean
```

Omit `--local-server` here — registering the remote box as a Dokploy server is the correct laptop→remote path. Set `WAN_IFACE` to the remote host's WAN interface so the `DOCKER-USER` chain guards the right one.

---

## Repository layout

```text
install.sh                    # One-line, on-the-box provisioner (harden → deploy → verify) + --uninstall
answers.env.example           # Operator inputs (domain + bring-your-own API keys)

automation/
├── dokploy_automate.py       # Orchestrator: Dokploy API, server, apps, domains
├── bootstrap_secrets.py      # Generates/persists secrets; renders .env files + dev-hub compose
├── setup_tunnel.py           # (tunnel mode) cloudflared + Cloudflare Tunnel + wildcard CNAME
├── dns_precheck.py           # Pre-deploy wildcard/subdomain DNS resolution check
├── dokploy_config.json       # App definitions (source of truth: services, ports, domains, tiers)
├── dev_hub_compose.yml       # Dev Hub compose template (${VARS} rendered at install)
├── openclaw-compose.yml      # OpenClaw compose template (+ openclaw-pair.sh pairing helper)
├── idp-compose.yml           # Identity Provider (IdP) simulator compose template
├── policypilot-compose.yml   # PolicyPilot compose template
├── drawbridge-compose.yml    # Drawbridge compose template
├── seed_expanded.py          # Reference Dev Hub DB seeder (runs inside Dev Hub; not called here)
├── envs/                     # .env_*.example templates (rendered → .env_* at install)
└── utils/                    # verify_deployment.py, check_*, bootstrap.py, cleanup_and_install.sh

docs/
├── PLATFORM_OVERVIEW.md      # The platform story: audience, architecture, MCP fleet
├── operations.md             # Day-2 runbook & troubleshooting
├── tunnel-ingress.md         # Cloudflare Tunnel ingress: setup, topology, troubleshooting
├── openclaw.md               # OpenClaw deployment runbook
├── manual_setup_guide.md     # Manual deployment reference
├── incident-report-*.md      # Incident post-mortems (the basis of the hardening)
├── abuse-reports.md          # Filed abuse reports from the incidents
└── reference/                # Salvaged Dokploy API notes + known-good bash reference impl
```

---

## Operations & troubleshooting

The day-2 runbook — Ollama models and errors, network topology, the Docker address-pool SSH trap, intermittent 404s, SSH drops mid-install, missing-Traefik recovery, compose project-name gotchas, and more — lives in **[docs/operations.md](docs/operations.md)**.

If a deploy fails with a `zodError` or `400 Invalid JSON`, the salvaged **[Dokploy API notes](docs/reference/lab-bootstrap-README.md)** are the fastest way to unstick it.
