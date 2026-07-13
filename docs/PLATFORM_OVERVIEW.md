# Check Point AI & Security Demonstration Platform

*An always-on Proof-of-Value environment for AI-driven security operations*

---

## Executive summary

This platform is a self-contained, always-on demonstration environment that a Check Point Security Engineer stands up with a single command to run live Proof-of-Value and demo sessions for customers. On one hardened Ubuntu host it hosts roughly fifteen purpose-built applications — from agentic AI workflows that drive Check Point management over the Model Context Protocol (MCP), to identity, threat-prevention, and GenAI-guardrail demonstrations — each published at its own `https://<app>.<domain>` address. Rather than assembling a fragile demo from scratch for every meeting, the SE has a permanent, reproducible environment where customers can see AI and Check Point security working together, hands-on, in minutes.

---

## Platform at a glance

The mechanics are deliberately simple so the SE can focus on the story, not the plumbing:

- **One-command install.** A single `curl … | sudo bash -- --domain yourdomain.com` turns a fresh Ubuntu 22.04/24.04 host into the full stack. The run is idempotent — re-running redeploys apps and never rotates a live secret out from under its database.
- **Two ingress modes.** `letsencrypt` (default) issues per-subdomain TLS via Traefik + HTTP-01 for any host with public inbound `80/443`. `tunnel` uses a **Cloudflare Tunnel** for home labs, NAT, or CGNAT with no public inbound and no port-forwarding — useful when the demo box lives behind a corporate or residential firewall.
- **A modern PaaS underneath.** [Dokploy](https://dokploy.com) manages application lifecycle; **Traefik** provides the reverse proxy and TLS; **Docker** runs every workload. Each app is reachable at a clean `https://<app>.<domain>` subdomain.
- **A Docker MCP Gateway** fronts the fleet of Check Point MCP servers — roughly a dozen sidecars (the current build ships 13) exposing on the order of 180 tools spanning Quantum Management, Management Logs, Threat Emulation/Prevention, Reputation, HTTPS Inspection, Gaia, Harmony SASE, Spark, CPInfo analysis, and product documentation. The gateway aggregates them behind one authenticated endpoint so an agent connects once and reaches everything.
- **Agents with swappable LLMs.** The n8n agents default to Azure OpenAI and can be repointed at OpenAI, Anthropic, Google Gemini, AWS Bedrock, or a fully local **Ollama** model — the last making air-gapped, offline demos possible with no data leaving the box.
- **Secrets handled for you.** Strong secrets are generated and persisted; bring-your-own provider keys are optional, and any you omit simply leave that integration gracefully disabled while everything else still deploys.
- **Security grounded in real hardening.** `ufw` default-deny, a `DOCKER-USER` chain that forces all app traffic through Traefik, `fail2ban`, unattended upgrades, and always-on TLS verification to Check Point systems — a posture shaped by two real 2026 incidents on the lab host and documented in the repo's post-mortems.
- **Data survives redeploys.** State lives in named Docker volumes and databases, so updating an app or rebuilding the box loses nothing.

---

## What it hosts

### The front door — Dev Hub  ·  `hub.<domain>`

Dev Hub is the launcher and landing page for the whole stack, presented as a **macOS-style desktop**: every app appears as an icon on the desktop and in the dock, and opens in a draggable, resizable window embedded in place. It adds Spotlight-style search (⌘K), folders, live widgets, and per-user layouts that follow each signed-in user across devices. For an SE it is the single link to send a customer — one login, then the entire demo estate laid out like a familiar operating system, with a server-side probe that shows a clean launcher card for any app that can't be framed inline.

### Agentic AI and Check Point MCP — the Playground  ·  bundle

The **CP Agentic MCP Playground** is the heart of the platform's AI story: a multi-service stack where AI agents drive Check Point through MCP tools. It bundles the builder tools an SE needs to show agentic security operations end-to-end:

| Sub-tool | Role in the demo |
|---|---|
| **n8n** (`n8n.<domain>`) | The workflow/agent orchestrator. Ships pre-built Check Point agents (imported automatically on deploy) that call the MCP tools using n8n's native MCP client node. |
| **Open WebUI** (`chat.<domain>`) | A polished chat interface over local or remote LLMs — the front-end for conversational demos and for talking to n8n agents. |
| **Flowise** (`flowise.<domain>`) | A low-code LLM-orchestration builder for assembling flows visually. |
| **Langflow** (`langflow.<domain>`) | A visual AI flow builder for prototyping agent and RAG pipelines. |
| **Ollama** (internal) | Local LLM runtime (CPU or NVIDIA GPU) for offline, no-data-egress demos. |
| **AI-Infra-Guard** (`aig.<domain>`) | An AI red-teaming platform — MCP security scanning and jailbreak evaluation — for showing how AI systems themselves get attacked. |

The **customer story**: an agent reads firewall logs, checks a reputation service, and proposes a policy change — in plain language, with a human approving the write. The **Check Point value** is that Check Point's own MCP servers expose real management, logging, threat, and Gaia capabilities as governed tools, so customers see agentic automation built on Check Point's actual API surface rather than a mock-up. (Supporting services — PostgreSQL, Ollama, and a Qdrant vector store for embeddings/RAG — run internally and are never exposed to the internet.)

### Access and policy automation

**PolicyPilot**  ·  `policypilot.<domain>` — Agentic Check Point access automation, validated against a live **R82.10** Management Server. You describe the access you want in one sentence; the engine decides whether it already exists, can be granted by widening an existing rule, or needs a new one, computes the **first-match-safe** placement, reuses existing objects instead of minting duplicates, previews the change, applies it on approval, and records an inverse op-list for one-click rollback. It writes *every* access-rule column (not just source/destination/service), reasons in identity space ("does the finance role reach the DMZ zone?"), and can either update the SMS policy or push a dynamic layer straight to a gateway. The same brain is drivable from the portal, a REST API, a ServiceNow/Jira ticket webhook, or an LLM agent over 29 MCP tools — with independent, opt-in publish gates so an agent never touches live policy unless an admin allows it. This is the SE's answer to "can AI safely make firewall changes?" — the answer being *yes, with the guardrails and the audit trail to prove it.*

**Drawbridge**  ·  `dcsim.<domain>` — A Datacenter Simulator that serves CloudGuard-format inventory feeds (mock vCenter, NSX-T, and other datacenter sources) so CloudGuard can import objects and build identity/context-aware policy in a PoV **without a real datacenter present**. It lets an SE demonstrate the full cloud/datacenter onboarding and dynamic-object story on the demo box alone.

**Script Builder**  ·  `scriptbuilder.<domain>` — A web tool that generates paste-ready Check Point configuration scripts for multi-site, dual-gateway deployments (R81.20+) applied over serial console. It captures per-site data and emits Gaia clish, BGP/IPSec-to-Azure-vWAN, dynamic objects, kernel params, and full SMS policy scripts across a three-stage deployment workflow — the practical companion to any datacenter or rollout conversation.

**Docs to Swagger**  ·  `swagger.<domain>` — Converts Check Point's published API documentation into Swagger/OpenAPI specifications and an interactive explorer. It gives automation teams a machine-readable, testable view of the Management and Gaia APIs — the foundation for every scripted or agent-driven integration.

### AI, threat, and identity security demos

**AI Guardrails Playground**  ·  `guardrails.<domain>` — A hands-on prompt-security demonstration (Lakera-style input/output screening). A split-screen playground scans prompts inbound (prompt injection, jailbreaks, PII) and responses outbound (data leakage, harmful content), with a library of 50+ documented attack vectors, batch scanning, an analytics dashboard, and side-by-side benchmarking against Azure AI Content Safety and the open-source LLM Guard. This is the SE's centerpiece for the fastest-growing customer question in the market: *how do we let our people use GenAI without leaking data or getting prompt-injected?*

**Threat Prevention Server**  ·  `threat.<domain>` — A safe, self-contained target for exercising Check Point threat controls: 40+ IPS signature triggers, 225 real malware samples (AES-encrypted at rest and decrypted only in memory at download), and threat-emulation file generation across 14 formats, all behind a login. It lets an SE demonstrate IPS, Anti-Virus, and Threat Emulation catching real threats on demand, with a JSON API for scripted tests.

**Identity Provider (IdP)**  ·  `idp.<domain>` — A full identity-provider simulator for Check Point security POCs: SAML 2.0 SSO, SCIM 2.0 provisioning (inbound *and* outbound to Check Point SASE), and RADIUS/TACACS+ on the same box. Its SAML flow is validated end-to-end against five Check Point products (SmartConsole admin login, Infinity Portal, Identity Awareness captive portal, Remote Access VPN, and Identity & Trust). Instead of standing up Entra ID or Okta just to demo SSO or user provisioning, the SE controls the entire identity side of a Zero-Trust story from one lightweight service.

### AI gateway and enablement

**OpenClaw**  ·  `claw.<domain>` — A self-hosted AI assistant gateway (WebSocket gateway + control dashboard + CLI agent) protected by a gateway token and per-device pairing. It provides a governed, on-box conversational AI endpoint for the platform.

**Training Portal**  ·  `training.<domain>` — Hands-on lab provisioning for structured, self-paced Check Point enablement.

**AI Basic Training**  ·  `learn.<domain>` — An introductory AI-fundamentals learning app for bringing customers and teams up to speed on the concepts the rest of the platform demonstrates.

---

## Demo narratives

These are end-to-end "customer story" flows that chain several apps into a single, credible demonstration.

**1. Agentic SOC — from alert to enforced rule.** An n8n agent pulls recent activity through the Management Logs MCP, checks a suspicious host or file against the Reputation and Threat Emulation MCP tools, and — when a threat is confirmed — hands off to PolicyPilot to draft a first-match-safe Drop rule, preview it, and (behind PolicyPilot's publish gate, on human approval) apply it. The analyst's chat runs through the AI Guardrails engine so a prompt-injection attempt in the conversation is caught before it reaches the agent. *Apps: Playground (n8n + MCP) → PolicyPilot → AI Guardrails.* The takeaway: autonomous investigation with a governed, reversible enforcement step — not a black box.

**2. Zero-Trust onboarding — identity to least-privilege access.** The IdP simulator provisions a new contractor via SCIM into a Check Point SASE tenant and places them in an access role. PolicyPilot then grants least-privilege access in identity terms — "allow the Contractors role to reach the build server" — reusing existing objects and placing the rule safely, and revokes it cleanly at offboarding. *Apps: Identity Provider → PolicyPilot.* The takeaway: identity-driven access that a machine can grant and revoke with a full audit trail.

**3. Datacenter migration — CloudGuard onboarding with no datacenter.** Drawbridge serves CloudGuard-format inventory from a simulated vCenter/NSX-T environment; CloudGuard imports the objects; PolicyPilot writes context- and zone-aware policy against them. *Apps: Drawbridge → CloudGuard → PolicyPilot.* The takeaway: the complete cloud/datacenter onboarding and dynamic-policy story, demonstrable on the demo box alone.

**4. GenAI safety — a guardrail in front of the model.** A user sends a chatbot (Open WebUI or OpenClaw, backed by a local Ollama model) a prompt containing secrets, PII, or an injection payload. The AI Guardrails engine screens the request inbound and the response outbound, blocks what it should, and the dashboard shows the caught attacks benchmarked against Azure AI Content Safety and LLM Guard. *Apps: AI Guardrails → Open WebUI/OpenClaw → Ollama.* The takeaway: exactly what changes when a Check Point-grade guardrail sits between employees and their LLMs.

---

## What to add next — where the puck is going

The platform already tells the "AI *for* security" story well. The strategic frontier for 2026 is the inverse — **security *for* AI** — because every customer now runs LLMs, copilots, and (increasingly) autonomous agents, and almost none of them have secured that layer. The suggestions below map current market pull to Check Point's direction, and each ties back to an app already on the box.

**1. LLM Firewall — evolve AI Guardrails from a demo into inline runtime protection.** Prompt injection sits at the top of the OWASP LLM risk list, and Check Point's acquisition of Lakera puts a genuine GenAI-security engine in the portfolio. Reposition the AI Guardrails app as an inline **reverse proxy** that sits in front of a real LLM endpoint (or the OpenClaw gateway) and enforces in real time, not just scans on demand. The customer conversation: *"put this in the path of your GenAI traffic and it screens every prompt and response, at scale."*

**2. MCP and agent security & governance — make the gateway a visible policy choke point.** This platform *runs* agents, which makes it the perfect place to show how to secure them — tool-call authorization, per-tool RBAC, rate limits, and a full audit of what an agent invoked and why. Turn the Docker MCP Gateway into a demonstrable control plane and pair it with PolicyPilot's opt-in publish gates. The conversation: *"your developers are wiring agents to production tools right now — here's how you authorize and audit every tool call."* This is the strongest "physician, heal thyself" story on the box.

**3. Identity for AI agents (non-human identities).** Agents need credentials, and non-human identities (NHIs) now outnumber human ones in most enterprises while being far less governed. Extend the IdP simulator to issue short-lived, scoped agent identities (OAuth client-credentials / workload identity), and have PolicyPilot write identity-aware rules that treat an *agent* as a first-class principal. The conversation: *"who is your AI agent, what can it authenticate to, and how do you revoke it?"*

**4. AI Security Posture Management (AI-SPM) — discover and grade the AI estate.** As CNAPP expands to cover AI assets, customers want an inventory of the models, datasets, agents, and API keys running in their environment, plus the misconfigurations and exposed secrets among them. Add a lightweight discovery app (or a Dev Hub widget) that enumerates AI endpoints and MCP servers on the box and scores their posture. The conversation: *"do you even know how many AI services and agents are live in your environment?"*

**5. Shadow AI discovery.** Unsanctioned GenAI use — employees pasting source code and customer data into public chatbots — is a top data-loss vector, and it's a natural fit for network and SASE visibility. Combine the Threat Prevention Server's traffic-generation capability with the Harmony SASE MCP tools to demonstrate detecting and controlling GenAI usage. The conversation: *"we can show you which GenAI tools your users are actually reaching, then let you allow, coach, or block."*

**6. GenAI data-loss prevention (DLP).** The outbound half of the guardrail story — stopping sensitive data from leaving through a prompt — aligns directly with Check Point's GenAI-protection direction. Extend the AI Guardrails outbound scanning into a focused DLP demo with realistic data types (secrets, PII, source code, regulated data). The conversation: *"your DLP program has a GenAI-shaped hole in it."*

**7. RAG and vector-store data governance.** Retrieval-augmented generation is how enterprises put AI on their own data, and the vector store (the Qdrant instance already on the box) becomes a new, poorly-guarded data boundary — vulnerable to poisoning, over-broad retrieval, and leakage. Build a demo that shows access control and content screening around the RAG pipeline. The conversation: *"the knowledge base feeding your copilot is now a security perimeter — is anyone watching it?"*

**8. Continuous, automated AI red-teaming.** One-off testing doesn't keep up with models that change weekly; automated adversarial testing does. Productize the AI-Infra-Guard capability into scheduled red-team runs that produce a scorecard and feed results back into guardrail tuning. The conversation: *"prove your AI defenses hold — on a schedule, not once at launch."*

**9. Agentic SOC with autonomous, governed response.** Extend Demo Narrative #1 into a fuller autonomous-response playbook — triage, enrichment, and a proposed remediation that a human approves — closing the loop through PolicyPilot and, over time, into Check Point's automation and exposure-management direction. The conversation: *"how much of tier-1 can an agent safely own, and where does the human stay in the loop?"*

**10. Infinity AI Copilot — the "buy vs. build" framing.** Place a demonstration of Check Point's own Infinity AI Copilot next to PolicyPilot and the agent workflows to contrast the turnkey vendor assistant with a customer-built agent driving Check Point over MCP. The conversation: *"use our Copilot for guided operations, and build your own governed agents on the same API surface — here is both, side by side."*

---

## Closing

One host, one command, and a permanent environment where customers can watch AI and Check Point security operate together — and where the platform's next chapter is securing the very AI it now demonstrates.
