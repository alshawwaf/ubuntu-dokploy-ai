<div align="center">

# ⚡ Ubuntu Dokploy AI

**One command** turns a fresh Ubuntu host into the full Check Point AI&nbsp;&amp;&nbsp;agentic demo stack —
[Dokploy](https://dokploy.com) PaaS · Traefik TLS · **~15 apps**, hardened, deployed &amp; verified for you.

<a href="https://github.com/alshawwaf/dev-hub"><img alt="Part of the Dev Hub ecosystem" src="https://img.shields.io/badge/part_of-Dev_Hub_ecosystem-8B5CF6?style=flat-square&logo=apple&logoColor=white"></a>
<img alt="Ubuntu 22.04 / 24.04" src="https://img.shields.io/badge/Ubuntu-22.04_·_24.04-E95420?style=flat-square&logo=ubuntu&logoColor=white">
<img alt="One-command install" src="https://img.shields.io/badge/install-one_command-22C55E?style=flat-square&logo=gnubash&logoColor=white">
<br>
<sub>

**Built with** &nbsp;
<img alt="Ubuntu" src="https://img.shields.io/badge/-Ubuntu-E95420?style=flat-square&logo=ubuntu&logoColor=white">
<img alt="Docker" src="https://img.shields.io/badge/-Docker-2496ED?style=flat-square&logo=docker&logoColor=white">
<img alt="Dokploy" src="https://img.shields.io/badge/-Dokploy-A855F7?style=flat-square&logo=dokploy&logoColor=white">
<img alt="Traefik" src="https://img.shields.io/badge/-Traefik-24A1C1?style=flat-square&logo=traefikproxy&logoColor=white">
<img alt="Cloudflare Tunnel" src="https://img.shields.io/badge/-Cloudflare-F38020?style=flat-square&logo=cloudflare&logoColor=white">
<img alt="Let's Encrypt" src="https://img.shields.io/badge/-Let's_Encrypt-003A70?style=flat-square&logo=letsencrypt&logoColor=white">
<img alt="Python" src="https://img.shields.io/badge/-Python-3776AB?style=flat-square&logo=python&logoColor=white">
<img alt="GNU Bash" src="https://img.shields.io/badge/-Bash-4EAA25?style=flat-square&logo=gnubash&logoColor=white">
&nbsp;·&nbsp; **Deploys** &nbsp;
<img alt="n8n" src="https://img.shields.io/badge/-n8n-EA4B71?style=flat-square&logo=n8n&logoColor=white">
<img alt="Ollama" src="https://img.shields.io/badge/-Ollama-000000?style=flat-square&logo=ollama&logoColor=white">
<img alt="Qdrant" src="https://img.shields.io/badge/-Qdrant-DC244C?style=flat-square&logo=qdrant&logoColor=white">
<img alt="PostgreSQL" src="https://img.shields.io/badge/-PostgreSQL-4169E1?style=flat-square&logo=postgresql&logoColor=white">

</sub>

</div>

```bash
curl -fsSL https://raw.githubusercontent.com/alshawwaf/ubuntu-dokploy-ai/main/install.sh | sudo bash -s -- --domain yourdomain.com
```

This is the installer for the [Dev Hub](https://github.com/alshawwaf/dev-hub) ecosystem: a single script hardens the host, installs Docker + Dokploy, generates every secret, sets up ingress, and deploys the whole suite from one config file. It rolls out in **two waves** — the hub + lightweight apps first (so `https://hub.<DOMAIN>` is reachable in a couple of minutes), then the heavy LLM/agentic stack last — with a **live app board** while it works and a full teardown when you're done.

**Two ingress modes** (pick with `--ingress`):

| Mode | Use when | How apps get TLS |
|---|---|---|
| `letsencrypt` *(default)* | The host has **public inbound** `80`/`443` (VPS, cloud VM). | Traefik issues Let's Encrypt certs via HTTP-01; a wildcard DNS `A` record points at the host. |
| `tunnel` | The host has **no public inbound** (home server, NAT, CGNAT). | A [Cloudflare Tunnel](#no-public-inbound-cloudflare-tunnel) dials out to Cloudflare's edge; edge TLS is free, no port-forwarding or public `A` record needed. |

```bash
sudo ./install.sh --domain yourdomain.com --ingress tunnel
```

<div align="center">

**[Quick start](#quick-start)** · **[Prerequisites](#prerequisites)** · **[What you get](#what-you-get)** · **[How it works](#how-installsh-works)** · **[Live dashboard](#the-live-installer-dashboard)** · **[Configuration](#configuration)** · **[Access](#accessing-your-stack)** · **[Uninstall](#uninstall)** · **[Security](#security)** · **[Reference](#reference)** · **[Troubleshooting](#operations--troubleshooting)**

</div>

---

## Quick start

On the target Ubuntu host, as root, only the domain is required:

```bash
curl -fsSL https://raw.githubusercontent.com/alshawwaf/ubuntu-dokploy-ai/main/install.sh | sudo bash -s -- --domain yourdomain.com
```

To supply optional bring-your-own API keys (OpenAI, Azure, Check Point management, etc.) or Cloudflare Tunnel credentials, clone first and use an answers file:

```bash
git clone https://github.com/alshawwaf/ubuntu-dokploy-ai.git && cd ubuntu-dokploy-ai
cp answers.env.example answers.env      # edit: add DOMAIN + any BYO keys you have
sudo ./install.sh --domain yourdomain.com
```

The run is **idempotent** — generated secrets are persisted and reused, installs are guarded, and firewall rules re-apply cleanly. Re-running redeploys the apps. Everything the script does is streamed to a live dashboard and mirrored to `/var/log/dokploy-ai-install.log`.

## What you get

The app catalog, domains, and ports live in [`automation/dokploy_config.json`](automation/dokploy_config.json) — **that file is the source of truth**; the table below is a snapshot. Every app is published at its own `https://<app>.<DOMAIN>` subdomain via Traefik.

| App | URL | What it is |
|---|---|---|
| **Dev Hub** | `hub.<DOMAIN>` | macOS-desktop-style portal that ties the suite together and embeds each app in a window |
| **CP Agentic MCP Playground** | `n8n.` · `chat.` · `flowise.` · `langflow.<DOMAIN>` | Build AI agents (n8n, Open WebUI, Flowise, Langflow) over Check Point MCP servers, with Langfuse tracing |
| **PolicyPilot** | `policypilot.<DOMAIN>` | Turn plain-language / ticket requests into safe Check Point access-policy changes |
| **Drawbridge** | `dcsim.<DOMAIN>` | Datacenter Simulator serving Check Point / CloudGuard-format datacenter feeds for PoV demos |
| **AI Guardrails Playground** | `guardrails.<DOMAIN>` | Test LLM prompt-injection / jailbreak guardrails across providers |
| **Threat Prevention Server** | `threat.<DOMAIN>` | Check Point threat-prevention demo / data server |
| **Training Portal** | `training.<DOMAIN>` | Hands-on lab portal (Apache Guacamole remote access) |
| **AI Basic Training** | `learn.<DOMAIN>` | Introductory AI / security training portal |
| **Docs to Swagger** | `swagger.<DOMAIN>` | Convert Check Point API docs into browsable OpenAPI / Swagger |
| **Identity Provider (IdP)** | `idp.<DOMAIN>` | SAML / SCIM Identity Provider simulator for SSO demos |
| **OpenClaw** | `claw.<DOMAIN>` | Third-party agentic browser, embedded in the hub |
| **Script Builder** | `scriptbuilder.<DOMAIN>` | Check Point script builder (private repo — see [Prerequisites](#private-repositories-script-builder)) |
| Ollama · PostgreSQL · Qdrant · Langfuse | *internal* | Backends for the agentic stack — not exposed to the internet |

<sub>**Preconfigured n8n agents** — the agentic app auto-imports ready-to-run n8n workflows on deploy: a Docker MCP Gateway fronting every Check Point MCP server (a direct-connection agent and a `*-via-gateway` twin for each), plus PolicyPilot and Dev Hub agents (bearer tokens + `<DOMAIN>` substituted at import). See [cp-agentic-mcp-playground](https://github.com/alshawwaf/cp-agentic-mcp-playground) · [PolicyPilot](https://github.com/alshawwaf/PolicyPilot) · [dev-hub](https://github.com/alshawwaf/dev-hub). For the wider story — audience, architecture, MCP fleet — see [docs/PLATFORM_OVERVIEW.md](docs/PLATFORM_OVERVIEW.md).</sub>

---

## Prerequisites

<details>
<summary><b>Domain, ingress mode, and the one manual step for private repos</b></summary>

<br>

- **Ubuntu 22.04 / 24.04 LTS**, with root (the installer runs `sudo bash`).
- A **domain you control**.

**That's the whole list.** You do **not** install Docker or anything else first — the script installs the Docker engine, the OS/Python packages, Dokploy, and every dependency itself, then deploys and verifies the stack. Install Ubuntu Server, run the one command, done. (The only tool the *one-liner* itself needs is `curl`, which ships with Ubuntu Server; if it's missing, use the `wget` form: `wget -qO- https://raw.githubusercontent.com/alshawwaf/ubuntu-dokploy-ai/main/install.sh | sudo bash -s -- --domain yourdomain.com`. Already manage Docker yourself? Add `--skip-docker` and the script leaves it alone.)

The rest depends on your ingress mode.

### Public inbound: Let's Encrypt (default)

- A **public IP**, with inbound `80`/`443` reachable from the internet.
- A **wildcard DNS `A` record** pointing at the host — the one manual prerequisite:

  ```
  Type: A    Name: *    Value: <SERVER_IP>    TTL: 3600
  ```

  The installer verifies it and prints exactly what to add if it's missing, but does not create it. Traefik needs it to issue Let's Encrypt certificates for every `*.yourdomain.com` subdomain.

### No public inbound: Cloudflare Tunnel

For a home server or any NAT'd/CGNAT box with no reachable inbound ports. See the full walkthrough in **[docs/tunnel-ingress.md](docs/tunnel-ingress.md)**; in brief you need:

- The **domain hosted on Cloudflare** (nameservers pointed at Cloudflare; the free plan is fine).
- A **Cloudflare API token** ([create one](https://dash.cloudflare.com/profile/api-tokens)) with scopes: `Account > Cloudflare Tunnel > Edit`, `Zone > DNS > Edit`, `Zone > Zone > Read`, plus your **account id**. Put both in `answers.env` (`CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`).
- **No port-forwarding and no `A` record** — the installer creates a proxied wildcard `CNAME` (`*.yourdomain.com` → the tunnel) for you and runs `cloudflared` as a systemd service.

> **Cert depth (free plan):** Cloudflare's free Universal SSL covers the zone apex and **one** wildcard level only (`yourdomain.com` + `*.yourdomain.com`). Pass the **zone apex** as `--domain` so apps land at `<app>.yourdomain.com`. A subdomain like `--domain ai.yourdomain.com` puts apps two levels deep (`<app>.ai.yourdomain.com`) where the free cert does **not** reach — the installer warns you and names the zone to use. To go deeper, enable Cloudflare Advanced Certificate Manager / Total TLS first.

### Private repositories (Script Builder)

Most apps clone from public HTTPS repos and need nothing extra. **Script Builder** is the exception — it clones over SSH from a private repo (`git@github.com:alshawwaf/cp-script-builder.git`), so it is **skipped by default** (a clear message, not a failure). Every other app still deploys. To include it, register this box's key as a **read-only deploy key** and opt in:

1. Print the key the installer generated (after at least one install attempt):

   ```bash
   sudo cat /root/.ssh/id_rsa.pub
   ```

2. On GitHub: **repo → Settings → Deploy keys → Add deploy key**, paste the key, leave *Allow write access* unchecked, save.
3. Re-run with `ALLOW_SSH_REPOS=1 sudo ./install.sh --domain yourdomain.com` — or make the repo public.

</details>

---

## How `install.sh` works

<details>
<summary><b>The fixed 14-step pipeline, in order</b></summary>

<br>

The installer runs the whole pipeline on the box, in order. It is a fixed **14-step** plan; each step is a row in the [live dashboard](#the-live-installer-dashboard).

1. **Preflight** — root/OS check; locate the repo (or clone it if piped via `curl`); resolve the domain and ingress inputs.
2. **Base packages** — Ubuntu packages for the Python deps (`python3-requests`, `python3-paramiko`, `python3-yaml`) plus `git`, `ufw`, `fail2ban`, `unattended-upgrades` — installed from apt, so no PyPI/pip is needed. Also detects the public IP and WAN interface.
3. **Base firewall** — `ufw` default-deny, allowing `22/80/443` inbound (or **only `22`** in `--ingress tunnel` mode, since the tunnel dials out and needs no public inbound). See [Security](#security).
4. **Docker engine** — installed if absent (`get.docker.com`), then Docker's user-network **address pools are pinned to `10.201/10.202.0.0/16`** via `/etc/docker/daemon.json`. Docker's built-in pools run `172.17`–`172.31` and then spill into `192.168.0.0/16` once ~16 compose networks exist — which collides with a `192.168.x` management LAN and can black-hole the host's own SSH (a Docker bridge steals the route to the admin subnet). Pinning to `10.x` keeps every app network clear of common LANs. Pass `--skip-docker` to skip this step entirely and use an existing engine untouched.
5. **Dokploy platform** — installed if absent (`dokploy.com/install.sh`).
6. **Traefik hubframe middleware** — a Traefik `hubframe` headers middleware (removes `X-Frame-Options`, sets a permissive `frame-ancestors` CSP), attached as a default middleware on the web/websecure entrypoints so every app can embed in the Dev Hub desktop.
7. **Host hardening** — the `DOCKER-USER` iptables chain (forces all app ports through Traefik on the auto-detected WAN interface), `fail2ban` (SSH jail), unattended security upgrades, root-key-only sshd, and a baseline user/`authorized_keys` audit. Skip with `--skip-harden`.
8. **Loopback SSH key** — a key is generated and self-authorized so Dokploy manages the box over `127.0.0.1` with no external exposure.
9. **Secrets & env rendering** — [`bootstrap_secrets.py`](automation/bootstrap_secrets.py) generates strong secrets, persists them to `/etc/dokploy-ai/secrets.env` (`0600`, reused on every run), and renders every `.env` from `automation/envs/*.example` plus a secret-free dev-hub compose. The Dokploy admin password is resolved (flag → store → generated) and upserted into the store.
10. **Cloudflare Tunnel ingress** — *(tunnel mode only)* [`setup_tunnel.py`](automation/setup_tunnel.py) installs `cloudflared`, creates/reuses the named tunnel, writes its config, upserts the proxied wildcard `CNAME`, and installs the systemd service. It then neutralizes Traefik's forced-HTTPS redirect (the tunnel forwards plain HTTP to Traefik on loopback `:80`) and puts the Dokploy dashboard behind a Traefik basic-auth gate at `dokploy.<DOMAIN>`. Skipped in letsencrypt mode.
11. **Agentic playground fetch** — clones [`cp-agentic-mcp-playground`](https://github.com/alshawwaf/cp-agentic-mcp-playground) next to this repo so its compose can deploy.
12. **DNS pre-check** — *(letsencrypt mode only)* [`dns_precheck.py`](automation/dns_precheck.py) confirms the wildcard + every app subdomain resolve to the host; aborts with the record to add if not. Override with `--skip-dns-check` / `--dns-warn-only`. Skipped entirely in tunnel mode.
13. **Core apps — hub + essentials** — hands off to [`dokploy_automate.py`](automation/dokploy_automate.py) with `--tier core`: registers the Dokploy admin, authenticates (Better-Auth session), and deploys the **hub + lightweight apps first** on the local Dokploy server (`--local-server`), then waits on the [live app board](#the-live-installer-dashboard) until they're up — so **`https://hub.<DOMAIN>` is reachable in a couple of minutes** and the board flips to a "hub is live" banner.
14. **AI stack — models + agentic bundle** — deploys the **heavy** tier last (`--tier heavy`: the CP-Agentic bundle, AI Guardrails, OpenClaw), only after core is up, so the multi-GB model pulls don't starve the quick apps. [`verify_deployment.py`](automation/utils/verify_deployment.py) boards each app until its containers are actually up, then prints where the generated admin password lives. Tier is set per app in `dokploy_config.json` (`"tier": "heavy"`; absent = `core`).

</details>

---

## The live installer dashboard

<details>
<summary><b>Rich in-place dashboard, plain fallback, and real per-app verification</b></summary>

<br>

The installer renders its progress two ways, chosen automatically:

- **Rich dashboard** — on an interactive terminal, a status view is painted in place on the *alternate screen* (so your shell and scrollback are untouched and restored on exit): a banner, a gradient **progress bar**, the **14-step checklist** (animated spinner on the running step; `✔` done / `▲` warned / `⤼` skipped / `○` pending, each with its duration), the elapsed clock, a warning counter, and a contained live **activity panel** showing the tail of the current command.
- **Live app board** — during the two deploy waves the finished checklist collapses to one line and a per-app board takes over: each app shows its state live — `○` queued · `⠦` building (animated) · `✔` up · `▲` degraded · `✖` failed — with its container count. The progress bar + counter switch to **apps up / total**, and the summary line flips to **`✔ hub is live → https://hub.<DOMAIN>`** the instant the hub's containers are up. The clock ticks every second even while a build is silent for minutes.
- **Plain mode** — when output is piped to a file, run under `nohup`, or the terminal is dumb, it falls back to clean numbered-step lines that read well in a log. Force it with `--plain` or `NO_RICH_UI=1`.

Either way:

- The **full raw output** of every command is tee'd to **`/var/log/dokploy-ai-install.log`** (override with `RUN_LOG=<path>`), so nothing is lost even though the live panel only shows the tail.
- The run ends with a **run-summary table** (per-step status + duration) and any warnings collected along the way — a warned-but-complete run is called out honestly rather than reported as clean.
- On failure the ERR trap marks the failing step red and names it with the elapsed time, exit code, and warnings up to that point.
- **The final view is held on screen until you press a key** — on success *and* failure. The dashboard lives on the terminal's alternate screen, so instead of it vanishing the moment the script exits, the finished board/checklist (which apps came up, exactly where a failure landed) stays up until *you* choose to close it, then a summary is printed to your scrollback. `Ctrl-C` exits cleanly with an "interrupted at step N" note. With no TTY (piped output / `nohup`) the hold is skipped, so unattended runs never block.

> **Tip — long runs over SSH:** run the installer inside `tmux` (or `nohup`) so a dropped SSH session can't kill it mid-deploy: `tmux new -s deploy` then run `./install.sh …` inside; detach with `Ctrl-b d`, reattach with `tmux attach -t deploy`.

**Per-app verification.** The deploy waves don't just declare success — [`verify_deployment.py`](automation/utils/verify_deployment.py) waits for Dokploy's asynchronous builds to finish and cross-checks reality: for each app it polls the compose deployment status (`idle → running → done`/`error`) **and** inspects the real Docker containers (running / healthy / unhealthy). In `--board` mode it feeds the live app board; it self-ticks the dashboard clock ~1×/s regardless of output, and ends with a per-app table plus a non-zero exit if anything failed or timed out. Tune the heavy-wave wait with `VERIFY_TIMEOUT` (default `2700`s = 45m), the core-wave wait with `VERIFY_CORE_TIMEOUT` (default `900`s = 15m), and the poll cadence with `VERIFY_INTERVAL` (default `3`s).

</details>

---

## Configuration

<details>
<summary><b>answers.env keys, the secrets model, and Ollama models</b></summary>

<br>

### `answers.env`

Copy `answers.env.example` → `answers.env` (git-ignored). Only `DOMAIN` is required; everything else is optional. This is where bring-your-own external API keys and Cloudflare Tunnel credentials go. Real keys from [`answers.env.example`](answers.env.example):

| Key | When | Purpose |
|---|---|---|
| `DOMAIN` | **required** | Root domain the apps hang off. |
| `DOKPLOY_ADMIN_EMAIL` / `DOKPLOY_ADMIN_PASSWORD` | optional | Override the Dokploy admin login (else generated + persisted). |
| `CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` | `--ingress tunnel` | Cloudflare API token + account id (scopes above). |
| `CLOUDFLARE_TUNNEL_NAME` | tunnel, optional | Named tunnel to create/reuse (default `devhub`). |
| `DOKPLOY_GATE_USER` / `DOKPLOY_GATE_PASSWORD` | tunnel, optional | Basic-auth for `dokploy.<DOMAIN>` (default `admin` / the Dokploy admin password). |
| `OPENAI_API_KEY` · `GEMINI_API_KEY` · `ANTHROPIC_API_KEY` · `LAKERA_API_KEY` | optional | LLM / guardrail provider keys for the agentic + guardrails apps. |
| `AZURE_OPENAI_API_KEY` · `AZURE_OPENAI_ENDPOINT` · `AZURE_OPENAI_DEPLOYMENT` | optional | Azure OpenAI is the default model behind every n8n agent — supply all three or the Azure node stays unconfigured. |
| `AZURE_CONTENT_SAFETY_KEY` / `AZURE_CONTENT_SAFETY_ENDPOINT` | optional | Azure Content Safety for the guardrails demo. |
| `MANAGEMENT_HOST` · `MANAGEMENT_API_KEY` · `SMS_API_KEY` · `TE_API_KEY` · `REPUTATION_API_KEY` | optional | Check Point Quantum management / SMS / Threat Emulation / Reputation MCP integrations. |
| `SPARK_MGMT_*` · `HARMONY_SASE_*` · `DOC_*` · `IPS_*` | optional | Spark, Harmony SASE, product-docs, and Infinity Portal IPS MCP integrations. |
| `IDP_SCIM_TOKEN` | optional | SCIM bearer token for the IdP simulator. |
| `COMPOSE_PROFILES` | optional | Agentic compose profile(s); default `cpu`, add `security-lab` to enable those services. |
| `DEMO_API_KEY` / `DEMO_PROJECT_ID` | optional | Lakera Guard credentials for the AI Guardrails demo. |
| `VSPHERE_HOST` · `VSPHERE_USER` · `VSPHERE_PASSWORD` | optional | vSphere creds so the Training Portal can provision lab VMs + Guacamole consoles. |

Any BYO key you omit is reported at the end and simply leaves that one integration disabled — the app still deploys.

### Secrets model

Secrets fall into three buckets, all handled for you:

- **Generated** — DB passwords, JWT/encryption keys, admin passwords, gateway tokens. Created with strong entropy, persisted to `/etc/dokploy-ai/secrets.env`, and **reused on every re-run** so a redeploy never rotates a live database password out from under its database. An explicit value in `answers.env` overrides and re-persists.
- **Bring-your-own (BYO)** — external provider keys (see the table above). Supplied via `answers.env`. **Any you omit are reported and simply leave that integration disabled** — the app still deploys.
- **Derived** — hostnames and URLs built from `DOMAIN`.

No secret is ever written to a tracked file. To see the generated Dokploy admin password after install:

```bash
sudo awk -F= '/DOKPLOY_ADMIN_PASSWORD/{print $2}' /etc/dokploy-ai/secrets.env
```

### Ollama models

The model(s) pulled into Ollama are set by `OLLAMA_MODELS` (and the Open WebUI default by `OPEN_WEBUI_DEFAULT_MODELS`) in `automation/envs/.env_agentic`. The CPU-friendly default pulls a small chat model plus a light tool-calling model and an embedding model; the file also ships a commented-out extended set (reasoning + uncensored guardrail-target models) you can enable. `OLLAMA_MAX_LOADED_MODELS=2` caps resident models (CPU RAM guard). See [Operations → Ollama model management](docs/operations.md#ollama-model-management).

</details>

---

## Accessing your stack

<details>
<summary><b>App URLs and reaching the Dokploy dashboard (per ingress mode)</b></summary>

<br>

Once DNS resolves and certs issue (or the tunnel connects), every app is live over HTTPS at `https://<app>.<DOMAIN>` — see the [catalog](#what-you-get) for the full list (`hub.`, `chat.`, `n8n.`, `policypilot.`, `dcsim.`, `guardrails.`, …).

**Dokploy dashboard** — depends on ingress mode:

- **`letsencrypt` mode:** port `3000` is firewalled off by design (it is a Docker-published port and the `DOCKER-USER` chain blocks it). Reach it via an SSH tunnel from your laptop, then open `http://localhost:3000`:

  ```bash
  ssh -L 3000:localhost:3000 root@<SERVER_IP>
  ```

- **`tunnel` mode:** the dashboard is published at `https://dokploy.<DOMAIN>` behind a Traefik **basic-auth gate**. User defaults to `admin` and the password to the Dokploy admin password (override with `DOKPLOY_GATE_USER` / `DOKPLOY_GATE_PASSWORD`). Show the admin password with the `awk` command in [Secrets model](#secrets-model).

</details>

---

## Uninstall

<details>
<summary><b>Full teardown — flags and Cloudflare safety</b></summary>

<br>

Full teardown of everything the installer put on the host:

```bash
sudo ./install.sh --uninstall [--answers answers.env] [--yes] \
                  [--keep-images] [--purge-secrets] [--remove-docker]
```

It runs a 9-step teardown with the same [live dashboard](#the-live-installer-dashboard): inventory + confirmation, leave the Docker Swarm, remove containers, remove volumes + networks, remove images, stop `cloudflared`, Cloudflare cleanup, remove Dokploy files/clones, and optional purges + a final report.

**What it removes:** every container, swarm state, Docker volumes/networks (and images unless `--keep-images`), `/etc/dokploy`, `cloudflared` + the Cloudflare **tunnel and only the DNS records pointing at it** (never anything else in the zone), the agentic clone, rendered `.env`/compose files, and the loopback `authorized_keys` entry.

**What it keeps:** host hardening (ufw/fail2ban/sshd/unattended-upgrades) is **always** kept — dropping it would expose the box. The Docker engine and the secrets store are kept unless you pass the matching purge flag. **Your `--answers` file is never deleted** — the uninstall only *reads* it (for the Cloudflare creds), even with `--purge-secrets`, so the same file works for the next reinstall.

| Flag | Effect |
|---|---|
| `--yes` | Skip the interactive `type "yes"` confirmation. **Required** to uninstall non-interactively (it refuses otherwise). |
| `--keep-images` | Keep Docker images + build cache (a reinstall reuses the local cache — much faster). |
| `--purge-secrets` | Delete the *generated* secrets store (`/etc/dokploy-ai/secrets.env`) **only** — never your `--answers` file; the next install regenerates all passwords. |
| `--remove-docker` | `apt purge` the Docker engine and remove `/var/lib/docker` + `/var/lib/containerd`. |
| `--answers <file>` | Read (never modify or delete) Cloudflare creds from here so the tunnel + its DNS records can be cleaned up. |

> **Cloudflare safety:** the tunnel/DNS cleanup needs `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` (from `--answers` or the environment). If a tunnel is matched only by name and still has **active connectors** but no local credentials on this host, uninstall refuses to delete it — so it can't take down a live tunnel that another box (e.g. a shared production deployment) is serving. The repo checkout itself is left in place; delete it yourself if you want it gone.

</details>

---

## Security

<details>
<summary><b>Hardening applied every run + the port-exposure policy</b></summary>

<br>

The installer's hardening is grounded in two real 2026 compromises of the lab host — see [`docs/incident-report-2026-03-24.md`](docs/incident-report-2026-03-24.md) (exposed PostgreSQL + default creds → cryptominer) and [`docs/incident-report-2026-03-31.md`](docs/incident-report-2026-03-31.md) (unauthenticated Langflow RCE + direct-port bypass).

**Applied on every install** (unless `--skip-harden`):

- **`ufw` default-deny**, allowing only `22/80/443` inbound (`22` only in tunnel mode). A firewall alone would have prevented the first incident.
- **`DOCKER-USER` iptables chain** forcing all container traffic through Traefik on `80/443`, closing the direct-port bypass behind the second incident. The installer aborts if it can't detect the WAN interface (a wrong interface would silently protect nothing) — pass `WAN_IFACE=<iface>` to override.
- **No shipped secrets** — the tracked composes reference `${VARS}` and fail closed if unset; strong values are generated at install. vSphere TLS verification defaults to on.
- **`fail2ban`** (SSH jail), **unattended security upgrades**, **root key-only sshd**, and a **baseline user/`authorized_keys` audit** at `/etc/dokploy-ai/audit-baseline.txt`.

### Port exposure policy

Database ports bind to `127.0.0.1` only — never `0.0.0.0`. Services talk over Docker networks.

| Port | Service | Binding |
|---|---|---|
| 5432 | PostgreSQL (agentic) | `127.0.0.1:5432` |
| 5433 | PostgreSQL (training) | `127.0.0.1:5433` |
| 11434 | Ollama | host-published, but blocked externally by the `DOCKER-USER` chain (reached internally / via host IP by AI Guardrails) |

</details>

---

## Reference

<details>
<summary><b><code>install.sh</code> flags</b></summary>

<br>

| Flag | Description |
|---|---|
| `--domain <d>` | Root domain (required; or `ROOT_DOMAIN` env, or `DOMAIN=` in `answers.env`) |
| `--answers <file>` | Answers file with domain + BYO secrets (default `answers.env`) |
| `--admin-email <e>` | Dokploy admin email (default `admin@<domain>`) |
| `--admin-password <p>` | Dokploy admin password (default: generated + persisted) |
| `--store <path>` | Secret store path (default `/etc/dokploy-ai/secrets.env`) |
| `--ingress <mode>` | `letsencrypt` (default; public inbound + HTTP-01) or `tunnel` (Cloudflare Tunnel, no public inbound) |
| `--skip-harden` | Skip host hardening |
| `--skip-docker` | Don't install or reconfigure Docker — use the engine already on the host (fails if none). Also leaves `daemon.json` untouched |
| `--skip-dns-check` | Deploy even if DNS isn't ready (certs may not issue; ignored in tunnel mode) |
| `--dns-warn-only` | Report DNS problems but continue |
| `--clean` | Tear down existing project/servers before redeploying |
| `--plain` | Force plain numbered-step output (disable the rich dashboard) |
| `--big` | Render the dashboard in double-width text (2× larger, more legible on a big terminal). Needs a terminal that supports DEC double-width (iTerm2, Terminal.app, xterm, …); ignored gracefully elsewhere. Note: font size itself is a terminal setting — use the terminal's zoom for even larger text. |
| `--uninstall` | Full teardown mode (see [Uninstall](#uninstall)) |
| `--yes` | *(uninstall)* skip the interactive confirmation |
| `--keep-images` | *(uninstall)* keep Docker images + build cache |
| `--purge-secrets` | *(uninstall)* delete the secrets store |
| `--remove-docker` | *(uninstall)* purge the Docker engine |
| `-h`, `--help` | Print the header comment (usage) and exit |

</details>

<details>
<summary><b><code>dokploy_automate.py</code> arguments</b></summary>

<br>

| Argument | Required | Default | Description |
|---|---|---|---|
| `--url` | yes | — | Dokploy URL, e.g. `http://1.2.3.4:3000` |
| `--email` | yes | — | Dokploy admin email |
| `--password` | yes | — | Dokploy admin password |
| `--domain` | yes | — (or `ROOT_DOMAIN`) | Root domain — no hardcoded default |
| `--ip` | no | derived from `--url` | Server public IP |
| `--local-server` | no | off | Deploy on the Dokploy host itself (`serverId=null`); skip remote SSH setup |
| `--ssh-user` | no | `adminuser` | SSH username on the server |
| `--ssh-password` | no | — | SSH password for initial authorization (paramiko) |
| `--ssh-private` / `--ssh-public` | no | `~/.ssh/id_rsa[.pub]` | Local SSH key paths |
| `--config` | no | `dokploy_config.json` | Apps config JSON |
| `--project` | no | `Agentic Demos` | Dokploy project name |
| `--app` | no | — | Only process this single app (by `name`) |
| `--tier` | no | `all` | Only deploy apps in this tier: `core` (hub + light), `heavy` (LLM/agentic), or `all`. Read from each config entry's `"tier"` (absent = `core`) |
| `--skip-harden` | no | off | Skip the built-in `harden_server` step |
| `--clean` | no | off | Fresh rebuild (delete project/servers first) |

</details>

<details>
<summary><b>Environment variables</b></summary>

<br>

Set by `install.sh`; useful for laptop runs too.

| Variable | Purpose |
|---|---|
| `ROOT_DOMAIN` | Root domain (alternative to `--domain`) |
| `INGRESS_MODE` | `letsencrypt` (default) or `tunnel` (alternative to `--ingress`) |
| `ALLOW_SSH_REPOS` | Set to `1` to include private SSH-repo apps (Script Builder) once a deploy key is registered |
| `WAN_IFACE` | Interface the `DOCKER-USER` chain guards (default `eth0` in laptop mode) |
| `DOKPLOY_HOST_IP` | Host IP used for the AI Guardrails → Ollama URL and DNS check |
| `DEV_HUB_COMPOSE_PATH` | Rendered dev-hub compose (secret-filled) to deploy |
| `AGENTIC_COMPOSE_PATH` | Path to the cloned agentic playground compose |
| `NO_RICH_UI` | Set to `1` to force plain output (same as `--plain`) |
| `HOLD` / `UI_HOLD_TIMEOUT` | `HOLD=0` skips the "press a key to close" hold at the end; `UI_HOLD_TIMEOUT` bounds it (default `600`s). Auto-skipped in CI / when there's no TTY |
| `RUN_LOG` | Install log path (default `/var/log/dokploy-ai-install.log`) |
| `VERIFY_TIMEOUT` / `VERIFY_CORE_TIMEOUT` / `VERIFY_INTERVAL` | Heavy-wave / core-wave verification timeout and poll interval (defaults `2700`s / `900`s / `3`s) |
| `CLOUDFLARE_API_TOKEN` | *(tunnel)* Cloudflare API token; scopes: Account>Cloudflare Tunnel>Edit, Zone>DNS>Edit, Zone>Zone>Read |
| `CLOUDFLARE_ACCOUNT_ID` | *(tunnel)* Cloudflare account id |
| `CLOUDFLARE_TUNNEL_NAME` | *(tunnel)* named tunnel to create/reuse (default `devhub`) |
| `CLOUDFLARE_RECREATE_TUNNEL` | *(tunnel)* delete+recreate a same-name tunnel that still has active connectors |
| `DOKPLOY_GATE_USER` / `DOKPLOY_GATE_PASSWORD` | *(tunnel)* basic-auth for `dokploy.<DOMAIN>` (default `admin` / the Dokploy admin password) |

</details>

<details>
<summary><b>Deploy to a remote host from your laptop</b></summary>

<br>

The one-liner runs on the box. To provision a **remote** host from your workstation instead, drive `dokploy_automate.py` directly — it installs Docker + Dokploy over SSH, registers the server, and deploys.

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

Omit `--local-server` here — registering the remote box as a Dokploy server is the correct path for laptop→remote. `harden_server` runs at the end by default; set `WAN_IFACE` to the remote host's WAN interface so the `DOCKER-USER` chain guards the right one.

</details>

---

## Repository layout

<details>
<summary><b>Files &amp; directories</b></summary>

<br>

```
install.sh                    # One-line, on-the-box provisioner (harden → deploy → verify) + --uninstall
answers.env.example           # Operator inputs (domain + bring-your-own API keys)

automation/
├── dokploy_automate.py       # Orchestrator: Dokploy API, server, apps, domains
├── bootstrap_secrets.py      # Generates/persists secrets; renders .env files + dev-hub compose
├── setup_tunnel.py           # (tunnel mode) provisions cloudflared + Cloudflare Tunnel + wildcard CNAME
├── dns_precheck.py           # Pre-deploy wildcard/subdomain DNS resolution check
├── dokploy_config.json       # App definitions (source of truth: services, ports, domains)
├── seed_expanded.py          # Reference Dev Hub DB seeder (runs inside Dev Hub; not called here)
├── dev_hub_compose.yml       # Dev Hub compose template (${VARS} rendered at install)
├── openclaw-compose.yml      # OpenClaw compose template
├── openclaw-pair.sh          # OpenClaw device-pairing helper
├── idp-compose.yml           # Identity Provider (IdP) simulator compose template
├── policypilot-compose.yml   # PolicyPilot compose template
├── drawbridge-compose.yml    # Drawbridge compose template
├── envs/                     # .env_*.example templates (rendered → .env_* at install)
└── utils/                    # bootstrap.py, check_*, verify_deployment.py, cleanup_and_install.sh

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

</details>

---

## Operations & troubleshooting

Day-2 runbook — Ollama models & errors, network topology, compose project-name gotchas, AI Guardrails settings DB, Traefik 404s, and the Traefik file provider — lives in **[docs/operations.md](docs/operations.md)**. If a deploy fails with a `zodError` or `400 Invalid JSON`, the salvaged **[Dokploy v0.29.8 API notes](docs/reference/lab-bootstrap-README.md)** are the fastest way to unstick it.
