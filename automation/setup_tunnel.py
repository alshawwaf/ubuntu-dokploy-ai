#!/usr/bin/env python3
"""
setup_tunnel.py — provision a Cloudflare Tunnel that fronts the Dokploy/Traefik
stack, so a home/NAT'd box with DEAD public inbound still serves every app at
https://<app>.<domain> with edge TLS.

Topology (replicates the hand-built live box exactly):
  - cloudflared runs as a systemd service from a LOCAL credentials-file config
    (NOT the dashboard token-managed mode).
  - /etc/cloudflared/config.yml points the tunnel at Traefik on loopback :80.
  - A single PROXIED wildcard CNAME `*.<domain>` -> <uuid>.cfargotunnel.com
    covers every current + future app (free Universal SSL covers *.<zone>).
  - The tunnel forwards PLAIN HTTP to Traefik (edge+tunnel are already
    encrypted); install.sh neutralizes Traefik's :80->:443 redirect so apps
    don't loop.

Idempotent + safe to re-run: an existing tunnel with the same name is reused
(unless its local credentials file is missing, in which case it is recreated so
we can obtain the secret again — but NOT when that tunnel still has ACTIVE
connectors, e.g. the live production box, unless recreation is explicitly opted
in via --recreate-tunnel / CLOUDFLARE_RECREATE_TUNNEL=true); per-host CNAMEs left
stale by a recreate are repointed at the new tunnel; the wildcard DNS record is
upserted; the systemd unit is re-installed and restarted.

    python3 automation/setup_tunnel.py \
        --domain example.com \
        --account-id <cf-account-id> \
        --api-token <cf-api-token> \
        [--tunnel-name devhub] \
        [--recreate-tunnel] \
        [--cloudflared-url <deb url>]

API token scopes required:
  Account > Cloudflare Tunnel > Edit
  Zone    > DNS > Edit
  Zone    > Zone > Read
"""

import argparse
import base64
import json
import os
import platform
import secrets
import shutil
import subprocess
import sys

try:
    import requests
except ImportError:  # keep py_compile / --help working off-target
    requests = None

try:
    import yaml
except ImportError:
    yaml = None

CF_API = "https://api.cloudflare.com/client/v4"
CFD_DIR = "/etc/cloudflared"
UNIT_PATH = "/etc/systemd/system/cloudflared.service"
CFD_RELEASE = "https://github.com/cloudflare/cloudflared/releases/latest/download"


def log(msg):
    print(f"\n==> {msg}", flush=True)


def warn(msg):
    print(f"WARN: {msg}", file=sys.stderr, flush=True)


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def env_flag(name):
    """True when env var <name> is set to a truthy value (1/true/yes/on)."""
    return os.environ.get(name, "").strip().lower() in ("1", "true", "yes", "on")


# ---------------------------------------------------------------------------
# Cloudflare API helper
# ---------------------------------------------------------------------------
class CF:
    def __init__(self, token):
        self.s = requests.Session()
        self.s.headers.update(
            {
                "Authorization": f"Bearer {token}",
                "Content-Type": "application/json",
            }
        )

    def call(self, method, path, **kw):
        url = f"{CF_API}{path}"
        try:
            r = self.s.request(method, url, timeout=30, **kw)
        except Exception as exc:  # noqa: BLE001
            die(f"Cloudflare API request failed ({method} {path}): {exc}")
        try:
            body = r.json()
        except ValueError:
            body = {}
        if not r.ok or not body.get("success", False):
            errs = body.get("errors") or [{"message": r.text}]
            detail = "; ".join(
                f"{e.get('code', '?')}: {e.get('message', e)}" for e in errs
            )
            die(
                f"Cloudflare API error on {method} {path} "
                f"(HTTP {r.status_code}): {detail}\n"
                "Check the API token scopes: Account>Cloudflare Tunnel>Edit, "
                "Zone>DNS>Edit, Zone>Zone>Read."
            )
        return body.get("result")


# ---------------------------------------------------------------------------
# cloudflared install
# ---------------------------------------------------------------------------
def install_cloudflared(deb_url):
    if shutil.which("cloudflared"):
        log(f"cloudflared already present: {shutil.which('cloudflared')}")
        return
    if not deb_url:
        machine = platform.machine().lower()
        if machine in ("x86_64", "amd64"):
            arch = "amd64"
        elif machine in ("aarch64", "arm64"):
            arch = "arm64"
        else:
            die(f"unsupported architecture for cloudflared: {machine}")
        deb_url = f"{CFD_RELEASE}/cloudflared-linux-{arch}.deb"
    log(f"Installing cloudflared from {deb_url}")
    deb_path = "/tmp/cloudflared.deb"
    rc = subprocess.call(["curl", "-fsSL", "-o", deb_path, deb_url])
    if rc != 0:
        die(f"failed to download cloudflared .deb from {deb_url}")
    rc = subprocess.call(["dpkg", "-i", deb_path])
    if rc != 0:
        die("dpkg -i cloudflared failed.")
    if not shutil.which("cloudflared"):
        die("cloudflared not on PATH after install.")


# ---------------------------------------------------------------------------
# Tunnel lifecycle
# ---------------------------------------------------------------------------
def creds_path(uuid):
    return os.path.join(CFD_DIR, f"{uuid}.json")


def find_tunnel(cf, account_id, name):
    """Return an existing, non-deleted tunnel dict with this name, or None."""
    result = cf.call(
        "GET",
        f"/accounts/{account_id}/cfd_tunnel",
        params={"name": name, "is_deleted": "false"},
    )
    for t in result or []:
        if t.get("name") == name and not t.get("deleted_at"):
            return t
    return None


def create_tunnel(cf, account_id, name):
    """Create a tunnel with a locally-generated secret; return (uuid, secret_b64)."""
    secret_b64 = base64.b64encode(secrets.token_bytes(32)).decode("ascii")
    result = cf.call(
        "POST",
        f"/accounts/{account_id}/cfd_tunnel",
        data=json.dumps({"name": name, "tunnel_secret": secret_b64}),
    )
    return result["id"], secret_b64


def delete_tunnel(cf, account_id, uuid):
    cf.call("DELETE", f"/accounts/{account_id}/cfd_tunnel/{uuid}")


def tunnel_active_connections(cf, account_id, uuid):
    """Return the tunnel's list of active connector connections (may be empty).

    Used to refuse deleting a tunnel that still has live connectors (e.g. the
    production box) when its local credentials file merely happens to be missing
    on THIS host.
    """
    result = cf.call(
        "GET", f"/accounts/{account_id}/cfd_tunnel/{uuid}/connections"
    )
    return result or []


def ensure_tunnel(cf, account_id, name, recreate=False):
    """Idempotently produce a tunnel we hold the secret for.

    Reuse an existing tunnel only if its local credentials file survives (the
    secret is unreadable via API). Otherwise delete+recreate to regain a secret
    — but REFUSE to delete a tunnel that still has ACTIVE connectors (that would
    tear down a live deployment, e.g. the production box) unless the caller
    explicitly opts in via recreate. A tunnel with no active connections is the
    legitimate stale-tunnel path and is recreated as before.

    Returns (uuid, secret_b64_or_None, old_uuid_or_None). secret is None when
    reusing; old_uuid is the deleted tunnel's id when we recreated (so callers
    can repoint DNS records left pointing at it).
    """
    existing = find_tunnel(cf, account_id, name)
    old_uuid = None
    if existing:
        uuid = existing["id"]
        if os.path.exists(creds_path(uuid)):
            log(f"Reusing existing tunnel '{name}' ({uuid}) with local credentials.")
            return uuid, None, None
        conns = tunnel_active_connections(cf, account_id, uuid)
        if conns and not recreate:
            die(
                f"tunnel '{name}' ({uuid}) has {len(conns)} ACTIVE connector(s) but "
                "its local credentials file is missing on this host. Deleting it to "
                "recreate the secret would tear down a tunnel that is still serving "
                "another box (e.g. the live production deployment). Refusing.\n"
                "Safe options: (1) pick a different tunnel name — set "
                "CLOUDFLARE_TUNNEL_NAME to a fresh value and re-run (note: if this "
                "install also shares the live box's ZONE, use a different --domain "
                "too, or the wildcard-CNAME reconcile will refuse the foreign "
                "wildcard); or (2) if you are SURE this tunnel is yours to take "
                "over, opt in with --recreate-tunnel (or CLOUDFLARE_RECREATE_TUNNEL=true)."
            )
        if conns:
            warn(
                f"tunnel '{name}' ({uuid}) has {len(conns)} active connector(s); "
                "deleting+recreating anyway (recreation was opted in)."
            )
        else:
            warn(
                f"tunnel '{name}' ({uuid}) exists but its local credentials file is "
                "missing and it has no active connectors; recreating so the secret "
                "can be re-obtained."
            )
        delete_tunnel(cf, account_id, uuid)
        old_uuid = uuid
    log(f"Creating tunnel '{name}'")
    uuid, secret_b64 = create_tunnel(cf, account_id, name)
    log(f"Tunnel created: {uuid}")
    return uuid, secret_b64, old_uuid


def write_credentials(account_id, uuid, secret_b64):
    os.makedirs(CFD_DIR, exist_ok=True)
    path = creds_path(uuid)
    payload = {
        "AccountTag": account_id,
        "TunnelID": uuid,
        "TunnelSecret": secret_b64,
    }
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh)
    os.chmod(path, 0o600)
    log(f"Wrote credentials file {path} (0600)")


def write_config(domain, uuid):
    os.makedirs(CFD_DIR, exist_ok=True)
    config = {
        "tunnel": uuid,
        "credentials-file": creds_path(uuid),
        "ingress": [
            {"hostname": f"*.{domain}", "service": "http://localhost:80"},
            {"service": "http_status:404"},
        ],
    }
    path = os.path.join(CFD_DIR, "config.yml")
    with open(path, "w", encoding="utf-8") as fh:
        yaml.safe_dump(config, fh, default_flow_style=False, sort_keys=False)
    log(f"Wrote {path}")


# ---------------------------------------------------------------------------
# DNS
# ---------------------------------------------------------------------------
def find_zone_id(cf, domain):
    """Find the Cloudflare zone that <domain> lives in and return its id.

    <domain> may be the zone apex (e.g. example.com) or a subdomain of it
    (e.g. ai.example.com). We match the zone apex first, then walk up the
    labels. When <domain> is NOT the apex we warn: Cloudflare's free Universal
    SSL only covers the apex and a ONE-level wildcard (`*.<zone>`), so apps at
    `<app>.<domain>` are two levels deep and their edge-TLS handshake will fail
    unless Advanced Certificate Manager / Total TLS is enabled for the zone.
    """
    labels = domain.split(".")
    for i in range(len(labels) - 1):
        candidate = ".".join(labels[i:])
        result = cf.call("GET", "/zones", params={"name": candidate})
        for z in result or []:
            if z.get("name") == candidate:
                if candidate != domain:
                    warn(
                        f"--domain '{domain}' is a subdomain of the Cloudflare zone "
                        f"'{candidate}'. Apps land at <app>.{domain}, which is TWO "
                        "levels below the zone. Cloudflare's FREE Universal SSL only "
                        f"covers '{candidate}' and '*.{candidate}' (one level), so the "
                        "edge-TLS handshake for the apps will FAIL. Recommended: re-run "
                        f"with --domain {candidate} (apps at <app>.{candidate}, cert-"
                        "covered), or enable Advanced Certificate Manager / Total TLS "
                        "on the zone before relying on this deployment."
                    )
                return z["id"]
    die(
        f"no Cloudflare zone found for '{domain}' (or any parent). The zone must "
        "exist in this account and the token must have Zone>Zone>Read."
    )


def list_cname_records(cf, zone_id):
    """Every CNAME record in the zone (follows pagination)."""
    records = []
    page = 1
    while True:
        batch = cf.call(
            "GET",
            f"/zones/{zone_id}/dns_records",
            params={"type": "CNAME", "per_page": 100, "page": page},
        ) or []
        records.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    return records


def repoint_cname(cf, zone_id, record, target):
    """PUT an existing CNAME onto new content, preserving name/proxied/ttl."""
    body = {
        "type": "CNAME",
        "name": record["name"],
        "content": target,
        "proxied": record.get("proxied", True),
        "ttl": record.get("ttl", 1),
    }
    cf.call(
        "PUT",
        f"/zones/{zone_id}/dns_records/{record['id']}",
        data=json.dumps(body),
    )


def reconcile_tunnel_cnames(cf, zone_id, domain, uuid, old_uuid, recreate):
    """Reconcile every *.cfargotunnel.com CNAME in the zone with our tunnel.

    A recreate mints a NEW uuid, so per-host records (<app>.<domain>) left
    pointing at the OLD <uuid>.cfargotunnel.com go stale — the apps 404 while the
    install still reports success. Here we:
      - leave records already pointing at our tunnel alone;
      - repoint records that pointed at the tunnel we just recreated (old_uuid)
        to the new uuid, logging each;
      - NEVER touch records pointing at a FOREIGN tunnel (another deployment),
        EXCEPT the WILDCARD (*.<domain>): if it points at a foreign tunnel we
        refuse to hijack it unless recreation was opted in.
    The wildcard record itself is (re)written by upsert_wildcard_cname next.
    """
    wildcard = f"*.{domain}"
    suffix = ".cfargotunnel.com"
    target = f"{uuid}.cfargotunnel.com"
    examined = repointed = foreign = 0
    for r in list_cname_records(cf, zone_id):
        content = (r.get("content") or "").strip().lower().rstrip(".")
        if not content.endswith(suffix):
            continue
        examined += 1
        rec_uuid = content[: -len(suffix)]
        name = r.get("name")
        is_wildcard = name == wildcard
        if rec_uuid == uuid:
            log(f"DNS {name} already -> {target}; leaving as-is.")
            continue
        if old_uuid and rec_uuid == old_uuid:
            if is_wildcard:
                continue  # upsert_wildcard_cname repoints the wildcard itself
            repoint_cname(cf, zone_id, r, target)
            repointed += 1
            log(f"DNS {name}: repointed from recreated tunnel {old_uuid} -> {uuid}")
            continue
        # A tunnel uuid we do not recognise -> another deployment owns it.
        if is_wildcard:
            if not recreate:
                die(
                    f"the wildcard CNAME '{wildcard}' points at a FOREIGN tunnel "
                    f"({content}), not this deployment's tunnel ({uuid}). Another "
                    "deployment appears to own this zone's wildcard; refusing to "
                    "hijack it. Re-run with --recreate-tunnel (or "
                    "CLOUDFLARE_RECREATE_TUNNEL=true) to take it over, or point "
                    "--domain at a zone this box owns."
                )
            warn(f"DNS {name} points at foreign tunnel {content}; taking it over (opt-in).")
        else:
            foreign += 1
            warn(f"DNS {name} points at foreign tunnel {content}; leaving it untouched.")
    log(
        f"DNS reconcile: examined {examined} tunnel CNAME(s); repointed "
        f"{repointed} stale record(s); left {foreign} foreign record(s) untouched."
    )


def upsert_wildcard_cname(cf, zone_id, domain, uuid):
    name = f"*.{domain}"
    target = f"{uuid}.cfargotunnel.com"
    record = {
        "type": "CNAME",
        "name": name,
        "content": target,
        "proxied": True,
        "ttl": 1,
    }
    existing = cf.call(
        "GET",
        f"/zones/{zone_id}/dns_records",
        params={"type": "CNAME", "name": name},
    )
    match = None
    for r in existing or []:
        if r.get("name") == name and r.get("type") == "CNAME":
            match = r
            break
    if match:
        cf.call(
            "PUT",
            f"/zones/{zone_id}/dns_records/{match['id']}",
            data=json.dumps(record),
        )
        log(f"Updated proxied CNAME {name} -> {target}")
    else:
        cf.call(
            "POST",
            f"/zones/{zone_id}/dns_records",
            data=json.dumps(record),
        )
        log(f"Created proxied CNAME {name} -> {target}")


# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------
def install_service():
    unit = (
        "[Unit]\n"
        "Description=Cloudflare Tunnel (ubuntu-dokploy-ai)\n"
        "After=network-online.target\n"
        "Wants=network-online.target\n"
        "\n"
        "[Service]\n"
        "Type=simple\n"
        "ExecStart=/usr/bin/cloudflared tunnel --config /etc/cloudflared/config.yml run\n"
        "Restart=on-failure\n"
        "RestartSec=5\n"
        "\n"
        "[Install]\n"
        "WantedBy=multi-user.target\n"
    )
    with open(UNIT_PATH, "w", encoding="utf-8") as fh:
        fh.write(unit)
    log(f"Wrote systemd unit {UNIT_PATH}")
    subprocess.call(["systemctl", "daemon-reload"])
    subprocess.call(["systemctl", "enable", "cloudflared"])
    active = subprocess.call(
        ["systemctl", "is-active", "--quiet", "cloudflared"]
    )
    if active == 0:
        log("Restarting cloudflared")
        subprocess.call(["systemctl", "restart", "cloudflared"])
    else:
        log("Starting cloudflared")
        subprocess.call(["systemctl", "start", "cloudflared"])


def main():
    ap = argparse.ArgumentParser(description="Provision a Cloudflare Tunnel for the stack.")
    ap.add_argument("--domain", required=True, help="Root zone, e.g. example.com.")
    ap.add_argument("--account-id", required=True, help="Cloudflare account id.")
    ap.add_argument("--api-token", required=True, help="Cloudflare API token (bearer).")
    ap.add_argument("--tunnel-name", default="devhub", help="Tunnel name (default: devhub).")
    ap.add_argument(
        "--recreate-tunnel",
        action="store_true",
        help=(
            "Opt in to deleting+recreating a same-name tunnel even when it still has "
            "active connectors, and to taking over a wildcard owned by a foreign "
            "tunnel (also honored via CLOUDFLARE_RECREATE_TUNNEL=true)."
        ),
    )
    ap.add_argument("--cloudflared-url", default="", help="Override the cloudflared .deb URL.")
    args = ap.parse_args()

    # Opt-in via flag OR env var so answers.env/the shell can carry it without a
    # CLI change (install.sh forwards its environment to this subprocess).
    recreate = args.recreate_tunnel or env_flag("CLOUDFLARE_RECREATE_TUNNEL")

    if requests is None:
        die("the 'requests' module is required (apt: python3-requests).")
    if yaml is None:
        die("the 'PyYAML' module is required (apt: python3-yaml).")

    install_cloudflared(args.cloudflared_url)

    cf = CF(args.api_token)

    uuid, secret_b64, old_uuid = ensure_tunnel(
        cf, args.account_id, args.tunnel_name, recreate=recreate
    )
    if secret_b64 is not None:
        write_credentials(args.account_id, uuid, secret_b64)
    elif not os.path.exists(creds_path(uuid)):
        die(f"reused tunnel {uuid} but its credentials file vanished; re-run.")

    write_config(args.domain, uuid)

    zone_id = find_zone_id(cf, args.domain)
    reconcile_tunnel_cnames(cf, zone_id, args.domain, uuid, old_uuid, recreate)
    upsert_wildcard_cname(cf, zone_id, args.domain, uuid)

    install_service()

    log(
        f"Cloudflare Tunnel ready. Apps are reachable at https://<app>.{args.domain} "
        f"via tunnel {uuid} (proxied *.{args.domain})."
    )


if __name__ == "__main__":
    main()
