#!/usr/bin/env python3
"""
dns_precheck.py — verify that the stack's hostnames resolve to this host BEFORE
deploying, so Traefik/Let's Encrypt don't silently fail to issue certificates.

It enumerates every app hostname from dokploy_config.json (plus a wildcard
probe), resolves each, and compares against the expected public IP. On any
mismatch it prints exactly what DNS record to add and exits non-zero — unless
--warn-only is passed.

    python3 automation/dns_precheck.py --domain example.com --ip 203.0.113.10 \
        [--config automation/dokploy_config.json] [--warn-only]
"""

import argparse
import json
import os
import socket
import sys


def collect_hostnames(config_path, domain):
    """Pull every {{DOMAIN}}-templated hostname out of the app config."""
    hosts = set()
    # A wildcard probe: a random-ish label that can only resolve via the *.
    # wildcard A record, proving the wildcard (not just explicit records) works.
    hosts.add(f"dokploy-wildcard-check.{domain}")
    try:
        with open(config_path, "r", encoding="utf-8") as fh:
            apps = json.load(fh)
    except Exception as exc:  # noqa: BLE001 - config is best-effort here
        print(f"WARNING: could not read {config_path} ({exc}); checking wildcard only.")
        return sorted(hosts)

    def add(value):
        if isinstance(value, str) and "{{DOMAIN}}" in value:
            hosts.add(value.replace("{{DOMAIN}}", domain))

    for app in apps if isinstance(apps, list) else []:
        add(app.get("domain"))
        for exp in app.get("exposures", []) or []:
            add(exp.get("domain"))
    return sorted(hosts)


def resolve(host):
    try:
        infos = socket.getaddrinfo(host, None, family=socket.AF_INET)
        return sorted({info[4][0] for info in infos})
    except socket.gaierror:
        return []


def main():
    ap = argparse.ArgumentParser(description="Pre-deploy DNS resolution check.")
    ap.add_argument("--domain", default=os.environ.get("ROOT_DOMAIN"), required=False)
    ap.add_argument("--ip", default=os.environ.get("DOKPLOY_HOST_IP"), help="Expected public IP of this host.")
    ap.add_argument("--config", default="automation/dokploy_config.json")
    ap.add_argument("--warn-only", action="store_true", help="Report problems but exit 0.")
    args = ap.parse_args()

    if not args.domain:
        print("ERROR: --domain (or ROOT_DOMAIN) is required.", file=sys.stderr)
        return 2
    if not args.ip:
        print("ERROR: --ip (or DOKPLOY_HOST_IP) is required — the public IP DNS should point to.", file=sys.stderr)
        return 2

    hosts = collect_hostnames(args.config, args.domain)
    print(f"Checking {len(hosts)} hostname(s) resolve to {args.ip} ...\n")

    bad = []
    for host in hosts:
        ips = resolve(host)
        ok = args.ip in ips
        status = "OK  " if ok else "FAIL"
        detail = ", ".join(ips) if ips else "(no A record)"
        print(f"  [{status}] {host} -> {detail}")
        if not ok:
            bad.append(host)

    if not bad:
        print("\nAll hostnames resolve to this host. DNS is ready for Let's Encrypt.")
        return 0

    print(f"\n{len(bad)} hostname(s) do not resolve to {args.ip}.")
    print("Add a WILDCARD A record at your DNS provider, then re-run:")
    print(f"    Type: A   Name: *   Value: {args.ip}   TTL: 3600")
    print("(A wildcard covers every current and future *." + args.domain + " subdomain.)")
    if args.warn_only:
        print("\n--warn-only set: continuing despite DNS gaps (certs may fail to issue).")
        return 0
    print("\nAborting before deploy. Re-run with --skip-dns-check / SKIP_DNS_CHECK=1 to override.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
