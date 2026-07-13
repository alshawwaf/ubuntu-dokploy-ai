#!/usr/bin/env python3
"""
bootstrap_secrets.py — resolve, generate, and persist every secret the
ubuntu-dokploy-ai stack needs, then materialize the per-app `.env` files (and
the dev-hub compose) from their committed `*.example` templates.

Design goals
------------
- Idempotent: generated secrets are persisted to a store (default
  /etc/dokploy-ai/secrets.env, mode 0600) and REUSED on every re-run, so a
  redeploy never rotates a live database password out from under its database.
- No secrets in git: bring-your-own (BYO) values are read from an answers file
  and/or the environment; the rendered `.env` files are already covered by
  .gitignore, and no secret is ever written into a tracked file.
- Graceful: a missing BYO key leaves the template default in place and is
  reported at the end — it never aborts the run. The app degrades instead of
  failing the whole deploy (see docs/one-line-install.md).

Typical use (invoked by install.sh):
    python3 automation/bootstrap_secrets.py \
        --domain example.com \
        --answers answers.env \
        --store /etc/dokploy-ai/secrets.env \
        --envs-dir automation/envs \
        --dev-hub-compose automation/dev_hub_compose.yml
"""

import argparse
import os
import re
import secrets
import string
import sys

# ---------------------------------------------------------------------------
# Secret catalogue. Every key here is generated locally with strong entropy;
# nothing in this set should ever come from an external provider.
#   password -> 24 chars, [A-Za-z0-9] only (URL- and .env-safe, no quoting)
#   token    -> URL-safe base64, ~43 chars
#   hex      -> 64 hex chars
# ---------------------------------------------------------------------------
GENERATABLE = {
    # CP Agentic MCP Playground
    "POSTGRES_PASSWORD": "password",
    "N8N_ENCRYPTION_KEY": "hex",
    "N8N_USER_MANAGEMENT_JWT_SECRET": "hex",
    "N8N_ADMIN_PASSWORD": "password",
    "N8N_BASIC_AUTH_PASSWORD": "password",
    "OPEN_WEBUI_ADMIN_PASSWORD": "password",
    # Dev Hub (scoped keys — consumed via ${...} in dev_hub_compose.yml)
    "DEV_HUB_DB_PASSWORD": "password",
    "DEV_HUB_SECRET_KEY": "hex",
    "DEV_HUB_SUPERADMIN_PASSWORD": "password",
    # AI Guardrails Demo
    "FLASK_SECRET_KEY": "hex",
    "DEFAULT_ADMIN_PASSWORD": "password",
    # Training Portal
    "DB_PASSWORD": "password",
    "GUACAMOLE_SECRET_KEY": "hex",
    "SUPERADMIN_PASSWORD": "password",
    # OpenClaw
    "OPENCLAW_GATEWAY_TOKEN": "token",
    # Identity Provider (IdP) simulator
    "IDP_ADMIN_PASSWORD": "password",
    "IDP_SECRET_KEY": "hex",
    # SCIM inbound token — generated + shared with the cp-agentic SCIM agent
    "IDP_SCIM_TOKEN": "token",
    # PolicyPilot
    "PILOT_SESSION_SECRET": "hex",
    "PILOT_ENCRYPTION_KEY": "hex",
    "PILOT_ADMIN_PASSWORD": "password",
    # Drawbridge (Datacenter Simulator)
    "DCSIM_SESSION_SECRET": "hex",
    "DCSIM_ENCRYPTION_KEY": "hex",
    "DCSIM_ADMIN_PASSWORD": "password",
    # Agent MCP bearer tokens. Shared secrets: the cp-agentic n8n agents
    # authenticate to the PolicyPilot / dev-hub MCP endpoints with these, so the
    # SAME value is rendered into every template that carries the matching KEY=
    # line (PILOT_MCP_TOKEN -> agentic + policypilot; DEVHUB_MCP_TOKEN -> agentic
    # + the dev-hub compose). The producer seeds an API key from it; the n8n
    # importer builds a bearer credential from the same value.
    "PILOT_MCP_TOKEN": "token",
    "DEVHUB_MCP_TOKEN": "token",
    # CP Script Builder (its env vars are literally SECRET_KEY / APP_PASSWORD)
    "SECRET_KEY": "hex",
    "APP_PASSWORD": "password",
    # Observability — Langfuse (self-hosted tracing). NEXTAUTH_SECRET/SALT/
    # LANGFUSE_ENCRYPTION_KEY are standard secrets; the pk-lf/sk-lf pair lets
    # Langfuse headless-init bootstrap the project so Langflow's trace keys match
    # on a fresh deploy with no UI step.
    "NEXTAUTH_SECRET": "hex",
    "SALT": "hex",
    "LANGFUSE_ENCRYPTION_KEY": "hex",
    "LANGFUSE_PUBLIC_KEY": "langfuse_pk",
    "LANGFUSE_SECRET_KEY": "langfuse_sk",
    # LiteLLM proxy master key (n8n + Langflow -> Langfuse tracing path). The
    # cp-agentic compose falls back to a training default when this is absent;
    # generating a real one here hardens fresh installs. The n8n OpenAI/Azure
    # credentials and every committed Langflow flow authenticate with it.
    "LITELLM_MASTER_KEY": "litellm_key",
}

# Bring-your-own: supplied by the operator (answers.env / environment). If a
# key is absent the template default survives and the app degrades gracefully.
BYO = {
    "DOC_CLIENT_ID", "DOC_SECRET_KEY", "DOC_REGION",
    "MANAGEMENT_HOST", "MANAGEMENT_API_KEY",
    "SMS_API_KEY", "TE_API_KEY", "REPUTATION_API_KEY",
    # Gaia OS agent — reachable gateway + its Gaia login (headless env fallback for the
    # otherwise-interactive dialog). Blank = the Gaia tools stay inert.
    "GAIA_GATEWAY_IP", "GAIA_GATEWAY_PORT", "GAIA_USERNAME", "GAIA_PASSWORD",
    "SPARK_MGMT_CLIENT_ID", "SPARK_MGMT_SECRET_KEY",
    "SPARK_MGMT_REGION", "SPARK_MGMT_INFINITY_PORTAL_URL",
    "HARMONY_SASE_API_KEY", "HARMONY_SASE_MANAGEMENT_HOST", "HARMONY_SASE_REGION",
    # IPS MCP — Infinity Portal IPS service (client id/access key + its auth/service URLs).
    "IPS_CLIENT_ID", "IPS_ACCESS_KEY", "IPS_AUTH_URL", "IPS_SERVICE_URL",
    "VSPHERE_HOST", "VSPHERE_USER", "VSPHERE_PASSWORD",
    "DEMO_API_KEY", "DEMO_PROJECT_ID",
    "OPENAI_API_KEY", "GEMINI_API_KEY", "ANTHROPIC_API_KEY",
    "LAKERA_API_KEY", "LAKERA_PROJECT_ID", "QDRANT_API_KEY",
    "AZURE_OPENAI_API_KEY", "AZURE_OPENAI_ENDPOINT", "AZURE_OPENAI_DEPLOYMENT",
    "AZURE_CONTENT_SAFETY_KEY", "AZURE_CONTENT_SAFETY_ENDPOINT",
    # Optional docker-compose service profile(s); default stays "cpu" (the template
    # value) when unset. Set e.g. cpu,security-lab to enable the security-lab profile.
    "COMPOSE_PROFILES",
}

# Keys consumed directly by install.sh (Dokploy admin + Cloudflare tunnel ingress) —
# legitimate answers.env entries that bootstrap does not resolve. Listed here so the
# unknown-key warning below treats them as known rather than flagging them as typos.
INSTALL_KEYS = {
    "DOKPLOY_ADMIN_EMAIL", "DOKPLOY_ADMIN_PASSWORD",
    "CLOUDFLARE_API_TOKEN", "CLOUDFLARE_ACCOUNT_ID", "CLOUDFLARE_TUNNEL_NAME",
    "CLOUDFLARE_RECREATE_TUNNEL",
    "DOKPLOY_GATE_USER", "DOKPLOY_GATE_PASSWORD",
}

_ENV_LINE = re.compile(r"^(\s*)([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$")


def gen(kind):
    if kind == "password":
        alphabet = string.ascii_letters + string.digits
        return "".join(secrets.choice(alphabet) for _ in range(24))
    if kind == "token":
        return secrets.token_urlsafe(32)
    if kind == "hex":
        return secrets.token_hex(32)
    if kind == "langfuse_pk":
        return "pk-lf-" + secrets.token_urlsafe(24)
    if kind == "langfuse_sk":
        return "sk-lf-" + secrets.token_urlsafe(24)
    if kind == "litellm_key":
        # OpenAI-style prefix: LiteLLM clients (n8n credentials, Langflow flows)
        # send it as a Bearer / api-key value.
        return "sk-" + secrets.token_urlsafe(32)
    raise ValueError(f"unknown secret kind: {kind}")


def read_env_file(path):
    """Parse a KEY=VALUE file into a dict (ignores comments/blank lines)."""
    values = {}
    if not path or not os.path.exists(path):
        return values
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            m = _ENV_LINE.match(line.rstrip("\n"))
            if not m or line.lstrip().startswith("#"):
                continue
            values[m.group(2)] = m.group(3)
    return values


def write_store(path, values):
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write("# Auto-generated by bootstrap_secrets.py — do NOT commit.\n")
        fh.write("# Reused verbatim on re-runs so live credentials stay stable.\n")
        for key in sorted(values):
            fh.write(f"{key}={values[key]}\n")
    os.replace(tmp, path)
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass


def substitute_domain(text, domain):
    """Replace the {{DOMAIN}} placeholder and any literal example.com host.

    example.com is only replaced on word boundaries so substrings like
    example.commercial are left untouched.
    """
    text = text.replace("{{DOMAIN}}", domain)
    return re.sub(r"\bexample\.com\b", domain, text)


def resolve(domain, answers_path, store_path):
    """Build the full value map, generating+persisting missing secrets."""
    store = read_env_file(store_path)
    answers = read_env_file(answers_path)

    # Legacy key migration: the IdP simulator's secret keys are now IDP_*.
    # Carry any persisted values from earlier key names over so a redeploy
    # never rotates live credentials — but NEVER carry a placeholder value
    # (e.g. a stale SCIM_IDP_TOKEN=CHANGE_ME_...), or it would be reused as a
    # real secret and, for generatable keys, block fresh generation.
    def _is_placeholder(v):
        s = (v or "").strip().lower()
        return (not s) or any(m in s for m in (
            "change_me", "changeme", "your-", "your_", "placeholder",
            "generated-at-install", "xxxx",
        ))
    for old, new in (("SAML_IDP_ADMIN_PASSWORD", "IDP_ADMIN_PASSWORD"),
                     ("SAML_IDP_SECRET_KEY", "IDP_SECRET_KEY"),
                     ("KHALIDP_ADMIN_PASSWORD", "IDP_ADMIN_PASSWORD"),
                     ("KHALIDP_SECRET_KEY", "IDP_SECRET_KEY"),
                     ("SCIM_IDP_TOKEN", "IDP_SCIM_TOKEN")):
        if store.get(old) and not store.get(new) and not _is_placeholder(store[old]):
            store[new] = store[old]
        # Drop the retired key from the store either way, so a stale placeholder
        # under the old name can't linger in the persisted secrets file.
        store.pop(old, None)

    resolved = {"DOMAIN": domain}
    newly_generated = 0
    for key, kind in GENERATABLE.items():
        # Precedence: explicit operator value (answers/env) rotates the store and
        # wins; otherwise reuse the persisted value; otherwise generate a new one.
        supplied = answers.get(key) or os.environ.get(key)
        if supplied:
            resolved[key] = supplied
            store[key] = supplied
        elif store.get(key):
            resolved[key] = store[key]
        else:
            resolved[key] = gen(kind)
            store[key] = resolved[key]
            newly_generated += 1

    missing_byo = []
    for key in BYO:
        val = answers.get(key) or os.environ.get(key)
        if val:
            resolved[key] = val
        else:
            missing_byo.append(key)

    # Surface answers.env keys we know nothing about (typo / removed key). They are
    # silently ignored otherwise, which is how earlier BYO gaps went unnoticed. This
    # only WARNS — an unknown key never aborts the run.
    known = set(GENERATABLE) | BYO | INSTALL_KEYS | {"DOMAIN"}
    unknown_answers = sorted(k for k in answers if k not in known)

    write_store(store_path, store)
    return resolved, missing_byo, newly_generated, unknown_answers


def render_env_file(example_path, out_path, resolved, domain):
    """Render a .env from its .example: fill known keys, domain-template the rest."""
    with open(example_path, "r", encoding="utf-8") as fh:
        lines = fh.readlines()

    out = []
    for line in lines:
        stripped = line.rstrip("\n")
        m = _ENV_LINE.match(stripped)
        if not m or stripped.lstrip().startswith("#"):
            out.append(substitute_domain(line.rstrip("\n"), domain))
            continue
        indent, key, orig_val = m.group(1), m.group(2), m.group(3)
        if key in resolved and resolved[key] not in (None, ""):
            out.append(f"{indent}{key}={resolved[key]}")
        else:
            out.append(f"{indent}{key}={substitute_domain(orig_val, domain)}")

    text = "\n".join(out) + "\n"
    # Keep any DATABASE_URL password in sync with a co-located DB secret so the
    # app and its database always agree within a single rendered file.
    db_pw = resolved.get("DB_PASSWORD") or resolved.get("POSTGRES_PASSWORD")
    if db_pw:
        # Anchor to the DATABASE_URL key at line start (so RO_/CELERY_DATABASE_URL
        # are not matched), allow +-style drivers (postgresql+psycopg://), and
        # rewrite only the first occurrence.
        text = re.sub(
            r"(?m)^(\s*DATABASE_URL=[A-Za-z0-9+.\-]+://[^:@\s]+:)[^@\s]+(@)",
            lambda mm: mm.group(1) + db_pw + mm.group(2),
            text,
            count=1,
        )

    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(text)
    try:
        os.chmod(out_path, 0o600)
    except OSError:
        pass


def render_dev_hub_compose(template_path, resolved, domain):
    """Interpolate ${VAR} in the (now secret-free) dev-hub compose to a
    git-ignored rendered copy next to the template."""
    if not os.path.exists(template_path):
        return None
    with open(template_path, "r", encoding="utf-8") as fh:
        content = fh.read()
    content = substitute_domain(content, domain)

    def repl(match):
        if match.group(1):  # "$$" -> literal "$" (Docker-Compose escape)
            return "$"
        name = match.group(2) or match.group(3)
        return resolved.get(name, match.group(0))

    content = re.sub(
        r"(\$\$)|\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)", repl, content
    )
    out_path = os.path.join(os.path.dirname(template_path), "dev_hub_compose.rendered.yml")
    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write(content)
    try:
        os.chmod(out_path, 0o600)
    except OSError:
        pass
    return out_path


def main():
    ap = argparse.ArgumentParser(description="Generate secrets and render .env files.")
    ap.add_argument("--domain", default=os.environ.get("ROOT_DOMAIN"), help="Root domain (or ROOT_DOMAIN env).")
    ap.add_argument("--answers", default="answers.env", help="Answers file with BYO secrets + domain.")
    ap.add_argument("--store", default="/etc/dokploy-ai/secrets.env", help="Persisted secret store (0600).")
    ap.add_argument("--envs-dir", default="automation/envs", help="Directory of .env_*.example templates.")
    ap.add_argument("--dev-hub-compose", default="automation/dev_hub_compose.yml", help="Dev-hub compose template to render.")
    args = ap.parse_args()

    if not args.domain:
        print("ERROR: a domain is required (--domain or ROOT_DOMAIN, or DOMAIN in answers.env).", file=sys.stderr)
        # Last resort: pull DOMAIN out of the answers file.
        args.domain = read_env_file(args.answers).get("DOMAIN")
        if not args.domain:
            sys.exit(2)

    resolved, missing_byo, newly, unknown_answers = resolve(args.domain, args.answers, args.store)

    rendered = []
    if os.path.isdir(args.envs_dir):
        for name in sorted(os.listdir(args.envs_dir)):
            if not name.endswith(".example"):
                continue
            example_path = os.path.join(args.envs_dir, name)
            out_path = os.path.join(args.envs_dir, name[: -len(".example")])
            render_env_file(example_path, out_path, resolved, args.domain)
            rendered.append(out_path)

    dev_hub_rendered = render_dev_hub_compose(args.dev_hub_compose, resolved, args.domain)

    print(f"Secrets store:      {args.store}")
    print(f"Newly generated:    {newly} secret(s) (existing ones reused)")
    print(f"Rendered env files: {len(rendered)}")
    for p in rendered:
        print(f"  - {p}")
    if dev_hub_rendered:
        print(f"Rendered dev-hub compose: {dev_hub_rendered}")
        print(f"  export DEV_HUB_COMPOSE_PATH={dev_hub_rendered}")
    if missing_byo:
        print("\nBring-your-own keys NOT supplied (apps needing these will run degraded):")
        for k in sorted(missing_byo):
            print(f"  - {k}")
        print("Add them to answers.env and re-run install.sh to enable those integrations.")
    if unknown_answers:
        print("\nWARNING: unrecognized answers.env key(s) — IGNORED, not applied "
              "(typo, or a key removed from the templates?):", file=sys.stderr)
        for k in unknown_answers:
            print(f"  - {k}", file=sys.stderr)


if __name__ == "__main__":
    main()
