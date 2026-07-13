# Reference — salvaged from `lab-bootstrap`

Preserved verbatim from the (deleted) `alshawwaf/lab-bootstrap` repo on 2026-07-05, before its one-time job was retired. Its migration work is done and both apps it imported (OpenClaw, CP Demo Server) are now part of the standard [`dokploy_config.json`](../../automation/dokploy_config.json) catalog — but two artifacts remain valuable:

- **[`lab-bootstrap-README.md`](lab-bootstrap-README.md)** — contains the *Dokploy v0.29.8 API notes*: hard-won, live-verified gotchas for scripting Dokploy's API (compact single-line JSON bodies, `project.all` vs the unreliable `*.one` queries, undocumented `nonoptional` create fields revealed via `zodError`, async deploys, and a nasty bash `${body:-{}}` brace trap). **Read this first if a deploy fails with `zodError` or `400 Invalid JSON`.**
- **[`bootstrap-apps.sh`](bootstrap-apps.sh)** — a complete, live-verified reference implementation of driving the Dokploy v0.29.8 API from bash (`x-api-key` auth, create project → service → domain → deploy → poll, idempotent, dry-run, gated cutover). Not invoked by anything in this repo; kept as the known-good example of every API call shape.
