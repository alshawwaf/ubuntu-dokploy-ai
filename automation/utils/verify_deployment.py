#!/usr/bin/env python3
"""Deployment verification for the ubuntu-dokploy-ai stack.

Unlike a one-shot status print, this WAITS for the asynchronous Dokploy builds
to finish and checks that each app's containers actually came up:

  * polls every compose's deployment status (idle -> running -> done|error),
  * cross-checks the real Docker containers for each app (running / healthy),
  * prints concise status transitions while it waits (nice inside the installer's
    live log box), and
  * ends with a per-app table + a non-zero exit code if anything failed or timed
    out, so the installer can report an honest result instead of assuming success.

Runs on the box (needs the local `docker` CLI + Dokploy at --url).
"""
import argparse
import json
import re
import subprocess
import sys
import time

import requests

TERMINAL_OK = {"done"}
TERMINAL_BAD = {"error"}


def login(session, url, email, password):
    r = session.post(f"{url}/api/auth/sign-in/email",
                     json={"email": email, "password": password}, timeout=30)
    return r.status_code == 200


def _trpc_get(session, url, path, inp):
    import urllib.parse
    q = urllib.parse.quote(json.dumps({"0": {"json": inp}}))
    r = session.get(f"{url}/api/trpc/{path}?batch=1&input={q}", timeout=30)
    r.raise_for_status()
    return r.json()[0]["result"]["data"]["json"]


def discover_composes(session, url):
    """Return [{name, composeId, appName, status}] across every project/env."""
    out = []
    projects = _trpc_get(session, url, "project.all", None)
    for p in projects:
        detail = _trpc_get(session, url, "project.one", {"projectId": p["projectId"]})
        for env in detail.get("environments", []):
            env_detail = _trpc_get(session, url, "environment.one",
                                   {"environmentId": env["environmentId"]})
            for c in env_detail.get("compose", []):
                out.append({
                    "name": c["name"],
                    "composeId": c["composeId"],
                    "status": c.get("composeStatus") or "idle",
                })
    return out


def refresh_status(session, url, compose_id):
    try:
        c = _trpc_get(session, url, "compose.one", {"composeId": compose_id})
        return c.get("composeStatus") or "idle"
    except Exception:
        return "unknown"


def _slug(name):
    return re.sub(r"-+", "-", re.sub(r"[^a-z0-9]+", "-", name.lower())).strip("-")


def docker_all_projects():
    """{project_label: (running, total, healthy, unhealthy)} for every container.

    Dokploy names each compose project '<slug>-<random>' (e.g.
    'ai-guardrails-playground-7vxvxr') and does not expose that suffix over the
    API, so we read the real compose-project label off the containers and match
    apps by slug prefix.
    """
    try:
        out = subprocess.run(
            ["docker", "ps", "-a", "--format",
             '{{.Label "com.docker.compose.project"}}|{{.State}}|{{.Status}}'],
            capture_output=True, text=True, timeout=20).stdout
    except Exception:
        return {}
    projects = {}
    for line in out.splitlines():
        proj, _, rest = line.partition("|")
        state, _, status = rest.partition("|")
        if not proj:
            continue
        r, t, h, u = projects.get(proj, (0, 0, 0, 0))
        t += 1
        if state == "running":
            r += 1
        if "(healthy)" in status:
            h += 1
        if "(unhealthy)" in status:
            u += 1
        projects[proj] = (r, t, h, u)
    return projects


def app_health(projects, name):
    """(running, total, healthy, unhealthy) summed over the app's project(s)."""
    sl = _slug(name)
    r = t = h = u = 0
    for proj, (pr, pt, ph, pu) in projects.items():
        if proj == sl or proj.startswith(sl + "-"):
            r += pr; t += pt; h += ph; u += pu
    return (r, t, h, u)


def board_state(st, run, tot):
    """Collapse (deploy-status, containers) into one live-board state.

    Keyed on the DEPLOY status first, to match the final verdict: once Dokploy
    reports the compose "done", the app is UP even if run < tot — one-shot / init
    / model-pull / migration containers exit after they finish, so a healthy
    stack routinely runs fewer containers than it has (e.g. 31/36). Requiring
    run == tot wrongly pinned such apps at "building" forever.

    up       — deploy done, at least one container running
    degraded — deploy done, but nothing is running
    building — deploy still in progress (or containers just appearing)
    failed   — deploy errored
    queued   — not started yet
    """
    if st in TERMINAL_BAD:
        return "failed"
    if st in TERMINAL_OK:
        return "up" if run > 0 else "degraded"
    if st == "running" or run > 0:
        return "building"
    return "queued"


def verify(url, email, password, timeout, interval, board=False, wanted=None):
    s = requests.Session()
    if not login(s, url, email, password):
        print("  verify: Dokploy login failed — cannot verify.")
        return 2

    apps = discover_composes(s, url)
    if wanted is not None:
        # Tiered verify: only wait on the apps in the requested tier.
        apps = [a for a in apps if a["name"] in wanted]
    if not apps:
        print("  verify: no compose apps found to verify.")
        return 0
    print(f"  verify: waiting for {len(apps)} app(s) to build and come up "
          f"(timeout {timeout // 60}m)...", flush=True)

    last_emit = {}
    last_board = {}
    start = time.time()
    deadline = start + timeout
    last_beat = 0.0

    while True:
        projects = docker_all_projects()
        pending = []
        for a in apps:
            st = refresh_status(s, url, a["composeId"])
            # A transient tRPC/HTTP hiccup returns "unknown"; don't let it
            # downgrade an app we've already seen (especially one that reached
            # done) — that could flip a healthy tile red and cause a spurious
            # timeout at the deadline. Keep the last known status on a failed read.
            if st == "unknown" and a.get("status"):
                st = a["status"]
            a["status"] = st
            run, tot, hlz, unh = app_health(projects, a["name"])
            a["run"], a["tot"], a["healthy"], a["unhealthy"] = run, tot, hlz, unh
            bs = board_state(st, run, tot)
            # Board mode: emit a machine-readable snapshot for EVERY app each poll
            # (tab-delimited; install.sh routes "@APP…" into the live grid). Names
            # may contain spaces — tabs keep the fields unambiguous.
            if board:
                print(f"@APP\t{a['name']}\t{bs}\t{run}/{tot}", flush=True)
            # Human transition line only on a meaningful change (tidy activity feed).
            key = f"{st}/{run}/{tot}"
            if last_emit.get(a["composeId"]) != key:
                last_emit[a["composeId"]] = key
                if board:
                    if last_board.get(a["composeId"]) != bs:
                        last_board[a["composeId"]] = bs
                        evi = {"up": "✔", "failed": "✖", "building": "⚙",
                               "degraded": "▲", "queued": "·"}.get(bs, "·")
                        print(f"    {evi} {a['name']} → {bs} ({run}/{tot})", flush=True)
                else:
                    icon = {"done": "✔", "error": "✖", "running": "…"}.get(st, "·")
                    print(f"    {icon} {a['name'][:34]:34} {st:8} containers {run}/{tot}"
                          + (f" ({hlz} healthy)" if hlz else "")
                          + (" UNHEALTHY" if unh else ""))
            terminal = st in TERMINAL_OK or st in TERMINAL_BAD
            if not terminal:
                pending.append(a["name"])
        if not pending:
            break
        now = time.time()
        # Non-board heartbeat every ~8s so the old streamer keeps moving during a
        # long silent build. Board mode doesn't need it: the grid + the installer's
        # own 1s clock already show liveness.
        if not board and now - last_beat >= 8:
            last_beat = now
            mins, secs = divmod(int(now - start), 60)
            up = sum(1 for a in apps if a["status"] in TERMINAL_OK and a.get("run", 0) > 0)
            building = [a["name"] for a in apps if a["status"] == "running"]
            print(f"    ⧗ {mins:02d}:{secs:02d}  {up}/{len(apps)} up  ·  "
                  f"building: {', '.join(building[:2]) or '—'}  ·  "
                  f"queued {len(pending) - len(building)}")
        if now > deadline:
            print(f"  verify: timed out with {len(pending)} still building: "
                  f"{', '.join(pending[:6])}", flush=True)
            break
        time.sleep(interval)

    # ---- final report ----
    print("\n  ── app verification ──")
    ok = degraded = failed = 0
    rows = []
    for a in sorted(apps, key=lambda x: x["name"]):
        st = a["status"]
        run = a.get("run", 0)
        tot = a.get("tot", 0)
        if st in TERMINAL_BAD:
            verdict, failed = "FAILED", failed + 1
        elif st in TERMINAL_OK and run > 0:
            verdict, ok = "up", ok + 1
        elif st in TERMINAL_OK and run == 0:
            verdict, degraded = "no-containers", degraded + 1
        else:
            verdict, degraded = "timeout", degraded + 1
        mark = {"up": "✔", "FAILED": "✖", "no-containers": "▲",
                "timeout": "▲"}.get(verdict, "·")
        rows.append(f"  {mark} {a['name'][:34]:34} {verdict:14} "
                    f"deploy={st:8} containers={run}/{tot}")
    print("\n".join(rows))
    print(f"\n  result: {ok} up, {degraded} degraded/timeout, {failed} failed "
          f"(of {len(apps)}).")
    return 0 if (failed == 0 and degraded == 0) else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Verify Dokploy deployments (waits for containers).")
    parser.add_argument("--url", required=True, help="Dokploy URL")
    parser.add_argument("--email", required=True, help="Admin email")
    parser.add_argument("--password", required=True, help="Admin password")
    parser.add_argument("--timeout", type=int, default=2700, help="Max seconds to wait (default 2700 = 45m).")
    parser.add_argument("--interval", type=int, default=15, help="Poll interval seconds (default 15).")
    parser.add_argument("--board", action="store_true",
                        help="Emit machine-readable @APP snapshot lines for the installer's live board.")
    parser.add_argument("--config", help="Path to dokploy_config.json, used to resolve --tier app names.")
    parser.add_argument("--tier", default="all",
                        help="Verify only this tier's apps (all|core|heavy); requires --config.")
    args = parser.parse_args()
    wanted = None
    if args.tier and args.tier != "all" and args.config:
        try:
            _cfg = json.load(open(args.config))
            wanted = {e["name"] for e in _cfg
                      if (e.get("tier") or "core").lower() == args.tier.lower()}
        except Exception as e:
            print(f"  verify: could not read --config {args.config} ({e}); verifying all apps.")
    sys.exit(verify(args.url.rstrip("/"), args.email, args.password,
                    args.timeout, args.interval, board=args.board, wanted=wanted))
