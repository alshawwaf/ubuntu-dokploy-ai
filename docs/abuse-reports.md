# Abuse Reports — INC-2026-03-31-002
Attacker IP: **203.0.113.11** (Beanfield Technologies, Toronto CA, AS21949)
Date of attack: 2026-03-24 | Reported: 2026-03-31

---

## 1. AbuseIPDB (do this first — takes 60 seconds)

URL: https://www.abuseipdb.com/report

- **IP Address:** `203.0.113.11`
- **Categories:** Hacking (15), Port Scan (14)
- **Comment:**
```
IP used to compromise our server (203.0.113.10) on 2026-03-24 via CVE-2026-33017
(unauthenticated RCE in Langflow). Post-exploitation actions from this IP included
injecting SSH authorized keys into root and admin accounts, and adding a UFW firewall
rule to allow RDP (port 3389) from this IP as a persistent backdoor. Two XMRig-family
Monero miners were deployed inside a Docker container consuming ~3200% CPU.
```

---

## 2. Beanfield Technologies (attacker's ISP)

**To:** abuse@beanfield.com
**Subject:** Abuse Report — IP 203.0.113.11 — Server Compromise & Cryptomining (2026-03-24)

```
Hello Beanfield Abuse Team,

We are reporting a server compromise originating from IP 203.0.113.11 on your network
(AS21949).

INCIDENT SUMMARY
----------------
Date:        2026-03-24
Attacker IP: 203.0.113.11 (Beanfield Technologies, Toronto CA)
Victim IP:   203.0.113.10 (our server, YUL-SKUNK)
CVE:         CVE-2026-33017 — Unauthenticated RCE in Langflow (CVSS 9.3)

ACTIONS TAKEN FROM 203.0.113.11
--------------------------------
1. Exploited CVE-2026-33017 via HTTP POST to Langflow API (port 7860), achieving
   remote code execution inside a Docker container.

2. Deployed XMRig-family Monero cryptocurrency miners inside the container:
   - /tmp/AGZcgo9b  (~1600% CPU)
   - /tmp/h8ydm8oH  (~1600% CPU)
   - /tmp/moneroocean/xmrig (MoneroOcean mining pool)

3. Injected 6 SSH authorized keys into /home/skunkyul/.ssh/authorized_keys
   and 1 key into /root/.ssh/authorized_keys for persistent backdoor access.

4. Added UFW firewall rule to allow RDP (port 3389) from 203.0.113.11:
   "3389 ALLOW IN 203.0.113.11"
   This indicates the IP was under the attacker's direct control.

EVIDENCE
--------
- Full incident report: attached (docs/incident-report-2026-03-31.md)
- This was our second compromise in one week. The first used a different entry point.

Please investigate and take appropriate action against this subscriber.

Thank you,
[YOUR NAME / ORGANIZATION]
[CONTACT EMAIL]
[PHONE - OPTIONAL]
```

**Attachment:** `docs/incident-report-2026-03-31.md`

---

## 3. Canadian Centre for Cyber Security (CCCS)

**URL:** https://www.cyber.gc.ca/en/incident-management
**Form:** https://www.cyber.gc.ca/en/report

Fill in:
- **Incident type:** Unauthorized access / Cryptomining
- **Attacker origin:** Canada (Toronto, ON — Beanfield Technologies, AS21949)
- **Vulnerability exploited:** CVE-2026-33017
- **Description:**
```
Server compromised via CVE-2026-33017 (unauthenticated RCE in Langflow AI platform).
Attacker IP 203.0.113.11 (Beanfield Technologies, Toronto CA) deployed XMRig Monero
miners, injected SSH backdoor keys, and added a persistent firewall rule for RDP access.
This is the second compromise of the same server within one week. First compromise was
via exposed PostgreSQL with default credentials (CVE-unrelated). Full incident report
available on request.
```

---

## 4. CISA — Active CVE-2026-33017 Exploitation

**URL:** https://www.cisa.gov/forms/report
**Alt email:** central@cisa.dhs.gov
**Subject:** Active Exploitation Report — CVE-2026-33017 (Langflow RCE)

```
To CISA,

We are reporting active exploitation of CVE-2026-33017 (unauthenticated RCE in
Langflow) against our server on 2026-03-24, approximately 7 days after public
disclosure of the CVE.

KEY DETAILS
-----------
CVE:           CVE-2026-33017 (CVSS 9.3 — Critical)
Affected app:  Langflow v1.7.3 / v1.8.3 (langflowai/langflow Docker image)
Attack vector: POST /api/v1/build_public_tmp/{flow_id}/flow (unauthenticated)
Payload:       Python exec() of os.system() call to download/run XMRig miner
Attacker IP:   203.0.113.11 (Beanfield Technologies, Toronto CA, AS21949)
Post-exploit:  SSH key injection, UFW backdoor rule (port 3389)

NOTE: As of 2026-03-31, the patched version (1.9.0) is NOT yet available on Docker Hub.
The current "latest" tag is still 1.8.3. Many deployments remain vulnerable.

We have taken our Langflow instance offline pending availability of the patch.

Full incident report available on request.

[YOUR NAME / ORGANIZATION]
[CONTACT EMAIL]
```

---

## 5. Langflow / DataStax (vendor)

**GitHub:** https://github.com/langflow-ai/langflow/security
**Email:** security@langflow.org (if available)
**Subject:** Active mass exploitation of CVE-2026-33017 — patch not yet on Docker Hub

```
Hi Langflow Security Team,

We were compromised on 2026-03-24 via CVE-2026-33017. We want to flag two things:

1. ACTIVE EXPLOITATION: This CVE is being mass-exploited in the wild. Automated
   scanners are targeting all internet-exposed Langflow instances. We were hit
   within 7 days of public disclosure.

2. PATCH NOT AVAILABLE: As of 2026-03-31, langflowai/langflow:latest on Docker Hub
   is still version 1.8.3. The patched version (1.9.0) has not been published.
   Every Docker-based Langflow deployment is still vulnerable.

Please expedite the Docker Hub release of 1.9.0 and consider publishing a security
advisory with mitigation steps (e.g., disable the public flow build endpoint,
add authentication middleware) for users who cannot upgrade immediately.

[YOUR NAME / ORGANIZATION]
```

---

## Checklist

- [ ] AbuseIPDB — https://www.abuseipdb.com/report
- [ ] Email Beanfield — abuse@beanfield.com
- [ ] CCCS report — https://www.cyber.gc.ca/en/incident-management
- [ ] CISA report — https://www.cisa.gov/forms/report
- [ ] Langflow vendor — https://github.com/langflow-ai/langflow/security
