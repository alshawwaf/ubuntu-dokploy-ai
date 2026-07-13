# OpenClaw Deployment — ai.alshawwaf.ca

Personal AI assistant gateway deployed on a self-hosted Ubuntu server managed by Dokploy.

---

## Server

| | |
|---|---|
| **IP** | `203.0.113.10` |
| **User** | `skunkyul` |
| **PaaS** | Dokploy v0.29.7 |
| **Reverse Proxy** | Traefik v3.6.7 |
| **Network** | `dokploy-network` (used by all Traefik-routed services) |

---

## OpenClaw

### URLs
| | |
|---|---|
| **Gateway (public)** | `https://claw.ai.alshawwaf.ca` |
| **WebSocket** | `wss://claw.ai.alshawwaf.ca` |
| **Health check** | `https://claw.ai.alshawwaf.ca/healthz` |

### Docker Containers
| Container | Image | Role |
|---|---|---|
| `openclaw-gateway` | `ghcr.io/openclaw/openclaw:latest` | WebSocket gateway, serves dashboard UI on port 18789 |
| `openclaw-cli` | `ghcr.io/openclaw/openclaw:latest` | CLI agent connected to gateway |

### Compose Location
```
/etc/dokploy/compose/openclaw-prod/
├── docker-compose.yml
└── .env
```

### Environment Variables
| Variable | Description |
|---|---|
| `OPENCLAW_GATEWAY_TOKEN` | Auth token required to connect to the gateway |
| `OPENAI_API_KEY` | OpenAI API key used by the agent |
| `OPENCLAW_TZ` | Timezone (`UTC`) |

### Config File
```
/var/lib/docker/volumes/openclaw-prod_openclaw-config/_data/openclaw.json
```
```json
{
  "gateway": {
    "mode": "local",
    "auth": {
      "token": "<OPENCLAW_GATEWAY_TOKEN>"
    },
    "controlUi": {
      "allowedOrigins": ["https://claw.ai.alshawwaf.ca"]
    }
  },
  "agents": {
    "defaults": {
      "model": "openai/gpt-4o"
    }
  }
}
```

### Docker Volumes
| Volume | Mounted At | Purpose |
|---|---|---|
| `openclaw-prod_openclaw-config` | `/home/node/.openclaw` | Config, logs, state |
| `openclaw-prod_openclaw-workspace` | `/home/node/.openclaw/workspace` | Agent workspace |

### Traefik Routing
Traefik automatically picks up the gateway via Docker labels on `openclaw-gateway`:
- `Host(claw.ai.alshawwaf.ca)` → container port `18789`
- HTTP redirects to HTTPS
- TLS certificate via Let's Encrypt (`letsencrypt` resolver)

---

## Security Model

OpenClaw uses two layers of access control:

1. **Gateway Token** — must be provided in the dashboard "Connect" screen. Without it, all connections are rejected.
2. **Device Pairing** — even with the correct token, new devices appear as "pending" and require manual approval.

### Approving a New Device
When a new browser/client connects and shows **"pairing required"**:

```bash
# SSH into the server
ssh skunkyul@203.0.113.10

# List pending pairing requests
docker run --rm \
  --network container:openclaw-gateway \
  -e OPENCLAW_GATEWAY_TOKEN=<token> \
  -v openclaw-prod_openclaw-config:/home/node/.openclaw \
  ghcr.io/openclaw/openclaw:latest \
  node dist/index.js devices list

# Approve by request ID
docker run --rm \
  --network container:openclaw-gateway \
  -e OPENCLAW_GATEWAY_TOKEN=<token> \
  -v openclaw-prod_openclaw-config:/home/node/.openclaw \
  ghcr.io/openclaw/openclaw:latest \
  node dist/index.js devices approve <request-id>
```

---

## DevHub Integration

OpenClaw is registered in the DevHub at `https://hub.ai.alshawwaf.ca` as an application card.

| Field | Value |
|---|---|
| **Name** | OpenClaw |
| **Category** | AI Chat |
| **URL** | `https://claw.ai.alshawwaf.ca` |
| **GitHub** | `https://github.com/openclaw/openclaw` |
| **DB Record ID** | `36` |
| **Icon** | `https://github.com/openclaw.png` |

### Updating the DevHub Entry
```bash
# Get auth token
TOKEN=$(curl -s -X POST http://localhost:3001/api/auth/login \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'username=admin@example.com&password=<ADMIN_PASSWORD>' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

# Update app (replace <field> and <value> as needed)
curl -s -X PUT http://localhost:3001/api/apps/36 \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"<field>": "<value>"}'
```

---

## DevHub (hub.ai.alshawwaf.ca)

Custom app registry dashboard. Displays all deployed services as cards.

### Stack
| Container | Role |
|---|---|
| `dev_hub_frontend` | Nginx + React SPA, port 3001 → 80 |
| `dev_hub_backend` | FastAPI backend, port 8000 (internal) |
| `dev_hub_db` | PostgreSQL 15 |

### Compose Location
```
/etc/dokploy/compose/dev-hub-sgojuk/code/
├── backend/
│   ├── main.py
│   ├── seed.py          # seeds default apps on first run
│   ├── routers/apps.py  # CRUD endpoints for app cards
│   └── db/models.py
└── frontend/
    ├── src/components/AppCard.tsx
    └── public/logos/    # PNG logos referenced by icon field
```

### Admin Credentials
| | |
|---|---|
| **Email** | `admin@example.com` |
| **Password** | `<ADMIN_PASSWORD>` |

### Adding a New App Card
```bash
TOKEN=$(curl -s -X POST http://localhost:3001/api/auth/login \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'username=admin@example.com&password=<ADMIN_PASSWORD>' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])')

curl -s -X POST http://localhost:3001/api/apps/ \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "name": "My App",
    "description": "Short description",
    "url": "https://myapp.ai.alshawwaf.ca",
    "github_url": "https://github.com/...",
    "category": "AI Chat",
    "icon": "https://example.com/logo.png",
    "is_live": true
  }'
```

> **Icon rendering:** If `icon` starts with `http` or `/` it renders as an `<img>`. Otherwise it renders as plain text.

---

## DNS Records Required

All services use the `*.ai.alshawwaf.ca` pattern pointing to `203.0.113.10`.

| Subdomain | Service |
|---|---|
| `hub.ai.alshawwaf.ca` | DevHub |
| `claw.ai.alshawwaf.ca` | OpenClaw Gateway |

---

## Backup & Recovery

### What's Backed Up (Full Server)

| Category | Contents | Excluded |
|---|---|---|
| **PostgreSQL** | n8n, training_portal, dev_hub, dokploy databases (pg_dump) | — |
| **Docker volumes** | All named app volumes | Ollama model weights (42GB, re-pullable) |
| **Dokploy config** | All compose files, .env files, Traefik config, SSH keys, schedules | `.git`, `node_modules`, `__pycache__` |

### Backup Location
```
/opt/backups/full/<YYYY-MM-DD_HH-MM-SS>/
├── postgres/
│   ├── n8n.sql.gz
│   ├── training_portal.sql.gz
│   ├── dev_hub.sql.gz
│   └── dokploy.sql.gz
├── volumes/
│   ├── openclaw-prod_openclaw-config.tar.gz
│   ├── openclaw-prod_openclaw-workspace.tar.gz
│   ├── cp-agentic-mcp-playground-ys4oru_*.tar.gz
│   ├── training-portal-4sk9t3_*.tar.gz
│   └── ... (all named volumes)
├── dokploy/
│   ├── compose.tar.gz    (~1.1GB — all app source + compose files)
│   ├── traefik.tar.gz
│   ├── ssh.tar.gz
│   └── schedules.tar.gz
└── MANIFEST.txt
```

### Schedule
- **Runs:** Daily at **2:00 AM UTC**
- **Retention:** Last **7 days** (older backups auto-pruned)
- **Script:** `/opt/backups/full-backup.sh`
- **Logs:** `/var/log/full-backup.log`
- **Typical size:** ~3GB per backup
- **Duration:** ~3 minutes

### Run a Manual Backup
```bash
sudo /opt/backups/full-backup.sh
```

### Check Backup Status
```bash
tail -f /var/log/full-backup.log
ls -lh /opt/backups/full/
```

### Restore a Specific App (e.g. OpenClaw)
```bash
BACKUP=/opt/backups/full/<timestamp>

# Restore compose files
sudo tar xzf $BACKUP/dokploy/compose.tar.gz \
  -C /etc/dokploy --strip-components=0 compose/openclaw-prod/

# Restore volumes
sudo tar xzf $BACKUP/volumes/openclaw-prod_openclaw-config.tar.gz \
  -C /var/lib/docker/volumes/openclaw-prod_openclaw-config/_data
sudo tar xzf $BACKUP/volumes/openclaw-prod_openclaw-workspace.tar.gz \
  -C /var/lib/docker/volumes/openclaw-prod_openclaw-workspace/_data

# Fix permissions
sudo chown -R 1000:1000 /var/lib/docker/volumes/openclaw-prod_openclaw-config/_data
sudo chown -R 1000:1000 /var/lib/docker/volumes/openclaw-prod_openclaw-workspace/_data

# Start
cd /etc/dokploy/compose/openclaw-prod && docker compose up -d
```

### Restore a PostgreSQL Database
```bash
BACKUP=/opt/backups/full/<timestamp>

# Example: restore dev_hub
zcat $BACKUP/postgres/dev_hub.sql.gz | docker exec -i dev_hub_db psql -U admin dev_hub
```

### After Full Restore — Re-pull Ollama Models
Ollama model weights are excluded from backups. After restore, re-pull with:
```bash
docker exec ollama-cpu ollama list          # see what was running
docker exec ollama-cpu ollama pull <model>  # re-pull each model
```

---

## Known Issues & Fixes

### EACCES: permission denied on workspace/AGENTS.md
**Symptom:** Chat shows `Error: EACCES: permission denied, open '/home/node/.openclaw/workspace/AGENTS.md'`

**Cause:** The `openclaw-workspace` Docker volume is created owned by `root`, but the container runs as `node` (UID 1000).

**Fix:**
```bash
sudo chown -R 1000:1000 /var/lib/docker/volumes/openclaw-prod_openclaw-workspace/_data/
cd /etc/dokploy/compose/openclaw-prod && docker compose restart
```

---

## Useful Commands

```bash
# Check all running containers
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# Restart OpenClaw
cd /etc/dokploy/compose/openclaw-prod && docker compose restart

# View gateway logs
docker logs openclaw-gateway --tail 50 -f

# Test gateway health
curl https://claw.ai.alshawwaf.ca/healthz

# Edit OpenClaw config
sudo nano /var/lib/docker/volumes/openclaw-prod_openclaw-config/_data/openclaw.json
```

---

## Device pairing & dashboard access (`automation/openclaw-pair.sh`)

OpenClaw's Control UI pairs **per device** — an unapproved browser shows "pairing required". Run on the host:

```bash
./automation/openclaw-pair.sh list      # pending + paired devices
./automation/openclaw-pair.sh approve   # approve the most recent pending browser
./automation/openclaw-pair.sh url       # tokenized dashboard URL (skips pairing)
```

`url` prints `https://claw.ai.alshawwaf.ca/#token=…` — an operator token that bypasses per-device pairing. Paste it into **dev-hub → OpenClaw → Edit App → Embed URL** (stored encrypted) so the OpenClaw window opens already-connected. The token grants operator access — it's printed to your terminal only, never committed; rotate with `openclaw devices rotate` if a link leaks. Override the domain with `OPENCLAW_PUBLIC_URL`.
