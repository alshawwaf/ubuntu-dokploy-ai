#!/usr/bin/env bash
set -euo pipefail

# bootstrap-apps.sh
# Imports two apps into Dokploy (v0.29.8) via its API so they become tracked
# projects (visible in project.all and in any portal that reads it).
#
#   APP 1 - OpenClaw          : import the existing raw docker-compose as a Dokploy
#                               COMPOSE project, preserving its data volumes, then
#                               cut over from the old manual stack.
#   APP 2 - Threat Prevention : build a Dokploy APPLICATION from the public git
#                               repo cp_demo_server (Dockerfile), attach a domain,
#                               then remove the old standalone container + route.
#
# Idempotent (safe to re-run). Destructive steps run ONLY after the new service is
# confirmed up AND behind a confirm prompt (unless -y / ASSUME_YES=1).
# --dry-run prints intended mutations (secrets redacted) without changing anything.

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
DOKPLOY_URL="${DOKPLOY_URL:-http://localhost:3000}"
DOKPLOY_TOKEN="${DOKPLOY_TOKEN:-}"
ASSUME_YES="${ASSUME_YES:-0}"
DRY_RUN=0

OPENCLAW_PROJECT_NAME="OpenClaw"
OPENCLAW_COMPOSE_NAME="openclaw"
OPENCLAW_APPNAME="openclaw"
OPENCLAW_OLD_DIR="/etc/dokploy/compose/openclaw-prod"
OPENCLAW_OLD_ENV="${OPENCLAW_OLD_DIR}/.env"

TP_PROJECT_NAME="Threat Prevention"
TP_APP_NAME="cp-demo-server"
TP_APPNAME="cp-demo-server"
TP_GIT_URL="https://github.com/alshawwaf/cp_demo_server.git"
TP_GIT_BRANCH="GA"
TP_DOMAIN="demo.ai.alshawwaf.ca"
TP_PORT=8080
TP_OLD_CONTAINER="cp_demo_server"
TRAEFIK_DYNAMIC_DIR="/etc/dokploy/traefik/dynamic"

POLL_TIMEOUT=420
POLL_INTERVAL=10

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  C_OK=$'\033[0;32m'; C_SKIP=$'\033[0;36m'; C_WARN=$'\033[0;33m'
  C_FAIL=$'\033[0;31m'; C_BANNER=$'\033[1;35m'; C_RESET=$'\033[0m'
else
  C_OK=""; C_SKIP=""; C_WARN=""; C_FAIL=""; C_BANNER=""; C_RESET=""
fi
log_ok()   { printf '%s[ok]%s   %s\n' "$C_OK"   "$C_RESET" "$*"; }
log_skip() { printf '%s[skip]%s %s\n' "$C_SKIP" "$C_RESET" "$*"; }
log_warn() { printf '%s[warn]%s %s\n' "$C_WARN" "$C_RESET" "$*"; }
log_fail() { printf '%s[fail]%s %s\n' "$C_FAIL" "$C_RESET" "$*" >&2; }
banner()   { printf '\n%s============================================================%s\n' "$C_BANNER" "$C_RESET"
             printf '%s  %s%s\n' "$C_BANNER" "$*" "$C_RESET"
             printf '%s============================================================%s\n\n' "$C_BANNER" "$C_RESET"; }
die() { log_fail "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    -y|--yes)     ASSUME_YES=1 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    -h|--help)
      cat <<'USAGE'
Usage: bootstrap-apps.sh [--yes|-y] [--dry-run|-n]

  -y, --yes       Skip confirmation prompts for destructive cutover steps.
  -n, --dry-run   Print the mutations that WOULD run (secrets redacted); change nothing.

Environment:
  DOKPLOY_URL     Dokploy base URL (default: http://localhost:3000)
  DOKPLOY_TOKEN   Dokploy API key (required). Get it in Dokploy -> Settings -> API.
  ASSUME_YES=1    Same as --yes.
USAGE
      exit 0 ;;
    *) die "Unknown argument: $arg (try --help)" ;;
  esac
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
banner "Preflight checks"
command -v curl   >/dev/null 2>&1 || die "curl is required but not found."
command -v jq     >/dev/null 2>&1 || die "jq is required. Install: sudo apt-get update && sudo apt-get install -y jq"
command -v docker >/dev/null 2>&1 || die "docker is required but not found."
log_ok "curl, jq, docker present."
[ -n "$DOKPLOY_TOKEN" ] || die "DOKPLOY_TOKEN is not set. Create a key in Dokploy -> Settings -> API, then:
       export DOKPLOY_TOKEN='<your-key>'
     (The token is never printed or stored by this script.)"
log_ok "DOKPLOY_TOKEN is set."
log_ok "Dokploy URL: $DOKPLOY_URL"
[ "$DRY_RUN" -eq 1 ] && log_warn "DRY-RUN: no mutating calls will be sent."

# ---------------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------------
# api METHOD PROC [BODY]
#   Mutations (POST) and plain GET queries (e.g. project.all). On non-2xx: prints
#   the HTTP code + response body (surfaces the server's zodError) and exits.
#   Under --dry-run a POST is not sent; the intended body is printed with any
#   secret-bearing fields redacted.
api() {
  local method="$1" proc="$2" body="${3:-}" url="${DOKPLOY_URL}/api/${2}"

  if [ "$method" = "POST" ] && [ "$DRY_RUN" -eq 1 ]; then
    local shown
    case "$proc" in
      compose.saveEnvironment|application.saveEnvironment)
        shown="$(printf '%s' "$body" | jq -c '.env = "***REDACTED***"' 2>/dev/null || echo '{"env":"***REDACTED***"}')" ;;
      *)
        shown="$(printf '%s' "$body" | jq -c '.' 2>/dev/null || printf '%s' "$body")" ;;
    esac
    printf '%s[dry-run]%s POST %s\n' "$C_WARN" "$C_RESET" "$proc" >&2
    [ -n "$body" ] && printf '           body: %s\n' "$shown" >&2
    printf '{}'
    return 0
  fi

  local resp code out
  if [ "$method" = "GET" ]; then
    resp="$(curl -sS -w $'\n%{http_code}' -X GET "$url" \
      -H "x-api-key: ${DOKPLOY_TOKEN}" -H "Accept: application/json")" || die "curl failed: GET ${proc}"
  else
    local b send
    b="${body:-}"; [ -n "$b" ] || b="{}"
    send="$(printf '%s' "$b" | jq -c . 2>/dev/null || printf '%s' "$b")"
    resp="$(curl -sS -w $'\n%{http_code}' -X POST "$url" \
      -H "x-api-key: ${DOKPLOY_TOKEN}" -H "Content-Type: application/json" -H "Accept: application/json" \
      --data "$send")" || die "curl failed: POST ${proc}"
  fi
  code="$(printf '%s' "$resp" | tail -n1)"
  out="$(printf '%s' "$resp" | sed '$d')"
  if [ "${code:0:1}" != "2" ]; then
    log_fail "API ${method} ${proc} -> HTTP ${code}"
    printf '%s\n' "$out" >&2
    exit 1
  fi
  printf '%s' "$out"
}

# q PROC JSON_INPUT
#   For .query() procedures that take an input object. Dokploy queries are GET with
#   the input url-encoded as ?input=<json>; some builds also accept a POST body. We
#   try GET first, then fall back to POST, so this works regardless of the adapter.
#   Prints the response body on success (returns 0); returns 1 without exiting on failure.
q() {
  local proc="$1" raw="$2" body enc resp code out
  body="$(printf '%s' "$raw" | jq -c . 2>/dev/null || printf '%s' "$raw")"
  enc="$(jq -rn --arg v "$body" '$v|@uri' 2>/dev/null || printf '')"
  if [ -n "$enc" ]; then
    resp="$(curl -sS -w $'\n%{http_code}' -X GET "${DOKPLOY_URL}/api/${proc}?input=${enc}" \
      -H "x-api-key: ${DOKPLOY_TOKEN}" -H "Accept: application/json" 2>/dev/null || printf '\n000')"
    code="$(printf '%s' "$resp" | tail -n1)"; out="$(printf '%s' "$resp" | sed '$d')"
    if [ "${code:0:1}" = "2" ]; then printf '%s' "$out"; return 0; fi
  fi
  resp="$(curl -sS -w $'\n%{http_code}' -X POST "${DOKPLOY_URL}/api/${proc}" \
    -H "x-api-key: ${DOKPLOY_TOKEN}" -H "Content-Type: application/json" -H "Accept: application/json" \
    --data "$body" 2>/dev/null || printf '\n000')"
  code="$(printf '%s' "$resp" | tail -n1)"; out="$(printf '%s' "$resp" | sed '$d')"
  if [ "${code:0:1}" = "2" ]; then printf '%s' "$out"; return 0; fi
  return 1
}

# projects_json  -> the full project.all payload (plain GET, the one query that
#   reliably works here). Tolerant: prints '' on failure instead of exiting, so
#   it's safe to call inside poll loops. All status/idempotency reads go through
#   this (the *.one queries don't return on this Dokploy build).
projects_json() {
  curl -sS "${DOKPLOY_URL}/api/project.all" \
    -H "x-api-key: ${DOKPLOY_TOKEN}" -H "Accept: application/json" 2>/dev/null || printf ''
}

confirm() {
  local prompt="$1"
  if [ "$ASSUME_YES" -eq 1 ]; then log_warn "Auto-confirm (--yes): ${prompt}"; return 0; fi
  if [ ! -t 0 ]; then log_warn "No TTY and --yes not given; skipping: ${prompt}"; return 1; fi
  local reply
  read -r -p "$(printf '%s%s%s [y/N] ' "$C_WARN" "$prompt" "$C_RESET")" reply
  case "$reply" in y|Y|yes|YES) return 0 ;; *) log_skip "Declined: ${prompt}"; return 1 ;; esac
}

# find_project_id_by_name NAME  (project.all is a plain GET, no input)
find_project_id_by_name() {
  api GET "project.all" | jq -r --arg n "$1" 'map(select(.name == $n)) | (.[0].projectId // "")'
}

# default_environment_id PROJECT_ID
#   Prefer project.all (a plain GET, always works); fall back to the project.one
#   query only if environments aren't present there.
default_environment_id() {
  local pid="$1" env one
  env="$(api GET "project.all" | jq -r --arg p "$pid" 'map(select(.projectId == $p))[0].environments // [] | (map(select(.isDefault == true))[0].environmentId // .[0].environmentId // "")' 2>/dev/null || true)"
  if [ -z "$env" ] || [ "$env" = "null" ]; then
    one="$(q "project.one" "$(jq -n --arg p "$pid" '{projectId:$p}')" || true)"
    env="$(printf '%s' "$one" | jq -r '(.environments // []) | (map(select(.isDefault == true))[0].environmentId // .[0].environmentId // "")' 2>/dev/null || true)"
  fi
  printf '%s' "$env"
}

# ===========================================================================
# APP 1 - OpenClaw
# ===========================================================================
banner "APP 1 - OpenClaw (raw compose import)"

OPENCLAW_YAML="$(cat <<'OPENCLAW_COMPOSE_EOF'
networks:
  openclaw-net:
    driver: bridge
  dokploy-network:
    external: true
volumes:
  openclaw-config:
    external: true
    name: openclaw-prod_openclaw-config
  openclaw-workspace:
    external: true
    name: openclaw-prod_openclaw-workspace
services:
  openclaw-gateway:
    image: ghcr.io/openclaw/openclaw:latest
    restart: unless-stopped
    init: true
    environment:
      HOME: /home/node
      TERM: xterm-256color
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN}
      OPENAI_API_KEY: ${OPENAI_API_KEY}
      TZ: ${OPENCLAW_TZ:-UTC}
    volumes:
      - openclaw-config:/home/node/.openclaw
      - openclaw-workspace:/home/node/.openclaw/workspace
    networks: [openclaw-net, dokploy-network]
    command: ["node","dist/index.js","gateway","--bind","lan","--port","18789"]
    labels:
      - traefik.enable=true
      - traefik.docker.network=dokploy-network
      - traefik.http.routers.openclaw-web.rule=Host(`claw.ai.alshawwaf.ca`)
      - traefik.http.routers.openclaw-web.entrypoints=web
      - traefik.http.routers.openclaw-web.middlewares=redirect-to-https@file
      - traefik.http.routers.openclaw-web.service=openclaw-web
      - traefik.http.services.openclaw-web.loadbalancer.server.port=18789
      - traefik.http.routers.openclaw-websecure.rule=Host(`claw.ai.alshawwaf.ca`)
      - traefik.http.routers.openclaw-websecure.entrypoints=websecure
      - traefik.http.routers.openclaw-websecure.tls.certresolver=letsencrypt
      - traefik.http.routers.openclaw-websecure.service=openclaw-websecure
      - traefik.http.services.openclaw-websecure.loadbalancer.server.port=18789
    healthcheck:
      test: ["CMD","node","-e","fetch('http://127.0.0.1:18789/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 20s
  openclaw-cli:
    image: ghcr.io/openclaw/openclaw:latest
    restart: unless-stopped
    network_mode: "service:openclaw-gateway"
    cap_drop: [NET_RAW, NET_ADMIN]
    security_opt: ["no-new-privileges:true"]
    environment:
      HOME: /home/node
      TERM: xterm-256color
      OPENCLAW_GATEWAY_TOKEN: ${OPENCLAW_GATEWAY_TOKEN}
      BROWSER: echo
      OPENAI_API_KEY: ${OPENAI_API_KEY}
      TZ: ${OPENCLAW_TZ:-UTC}
    volumes:
      - openclaw-config:/home/node/.openclaw
      - openclaw-workspace:/home/node/.openclaw/workspace
    stdin_open: true
    tty: true
    init: true
    entrypoint: ["node","dist/index.js"]
    depends_on: [openclaw-gateway]
OPENCLAW_COMPOSE_EOF
)"

# Read the 3 env values from the old .env (never printed).
OC_ENV_BLOB=""
if [ -f "$OPENCLAW_OLD_ENV" ]; then
  read_env_val() { grep -E "^${1}=" "$OPENCLAW_OLD_ENV" | tail -n1 | cut -d= -f2- || true; }
  OC_GATEWAY_TOKEN="$(read_env_val OPENCLAW_GATEWAY_TOKEN)"
  OC_OPENAI_KEY="$(read_env_val OPENAI_API_KEY)"
  OC_TZ="$(read_env_val OPENCLAW_TZ)"; [ -n "$OC_TZ" ] || OC_TZ="UTC"
  { [ -n "$OC_GATEWAY_TOKEN" ] && [ -n "$OC_OPENAI_KEY" ]; } || log_warn "Some OpenClaw env keys are empty in ${OPENCLAW_OLD_ENV}; the stack may fail to start."
  OC_ENV_BLOB="$(printf 'OPENCLAW_GATEWAY_TOKEN=%s\nOPENAI_API_KEY=%s\nOPENCLAW_TZ=%s' "$OC_GATEWAY_TOKEN" "$OC_OPENAI_KEY" "$OC_TZ")"
  log_ok "Loaded OpenClaw env from ${OPENCLAW_OLD_ENV} (values not shown)."
else
  log_warn "Env file ${OPENCLAW_OLD_ENV} not found; compose env vars will not be set."
fi

OC_PROJECT_ID="$(find_project_id_by_name "$OPENCLAW_PROJECT_NAME")"
if [ -n "$OC_PROJECT_ID" ]; then
  log_skip "Project '${OPENCLAW_PROJECT_NAME}' exists (projectId=${OC_PROJECT_ID})."
else
  log_ok "Creating project '${OPENCLAW_PROJECT_NAME}' ..."
  OC_CREATE="$(api POST "project.create" "$(jq -n --arg n "$OPENCLAW_PROJECT_NAME" --arg d "OpenClaw gateway (imported from manual stack)" '{name:$n, description:$d}')")"
  if [ "$DRY_RUN" -eq 1 ]; then OC_PROJECT_ID="dry-run-oc-project"; log_warn "[dry-run] assuming projectId=${OC_PROJECT_ID}"
  else OC_PROJECT_ID="$(printf '%s' "$OC_CREATE" | jq -r '.project.projectId // .projectId // ""')"
       [ -n "$OC_PROJECT_ID" ] && [ "$OC_PROJECT_ID" != "null" ] || die "project.create returned no projectId."
       log_ok "Created project (projectId=${OC_PROJECT_ID})."
  fi
fi

if [ "$DRY_RUN" -eq 1 ] && [ "$OC_PROJECT_ID" = "dry-run-oc-project" ]; then
  OC_ENV_ID="dry-run-oc-env"; log_warn "[dry-run] assuming environmentId=${OC_ENV_ID}"
else
  OC_ENV_ID="$(default_environment_id "$OC_PROJECT_ID")"
  [ -n "$OC_ENV_ID" ] && [ "$OC_ENV_ID" != "null" ] || die "Could not resolve default environmentId for OpenClaw."
  log_ok "environmentId=${OC_ENV_ID}."
fi

OC_COMPOSE_ID=""
OC_ALREADY_UP=0
if [ "$DRY_RUN" -eq 0 ]; then
  OC_COMPOSE_ID="$(projects_json | jq -r --arg p "$OC_PROJECT_ID" --arg n "$OPENCLAW_COMPOSE_NAME" '[.[] | select(.projectId == $p) | .environments[]?.compose[]?] | map(select(.name == $n)) | (.[0].composeId // "")' 2>/dev/null || true)"
fi
if [ -n "$OC_COMPOSE_ID" ]; then
  ocst="$(projects_json | jq -r --arg i "$OC_COMPOSE_ID" '[.[].environments[]?.compose[]?] | map(select(.composeId == $i)) | (.[0].composeStatus // "")' 2>/dev/null || true)"
  if [ "$ocst" = "running" ] || [ "$ocst" = "done" ]; then
    OC_ALREADY_UP=1
    log_skip "Compose '${OPENCLAW_COMPOSE_NAME}' exists and is ${ocst} (composeId=${OC_COMPOSE_ID})."
  else
    log_skip "Compose '${OPENCLAW_COMPOSE_NAME}' exists (composeId=${OC_COMPOSE_ID}); re-applying config + redeploy."
  fi
else
  log_ok "Creating raw compose service '${OPENCLAW_COMPOSE_NAME}' ..."
  OC_CC="$(api POST "compose.create" "$(jq -n --arg n "$OPENCLAW_COMPOSE_NAME" --arg e "$OC_ENV_ID" --arg a "$OPENCLAW_APPNAME" '{name:$n, environmentId:$e, appName:$a, composeType:"docker-compose"}')")"
  if [ "$DRY_RUN" -eq 1 ]; then OC_COMPOSE_ID="dry-run-oc-compose"; log_warn "[dry-run] assuming composeId=${OC_COMPOSE_ID}"
  else OC_COMPOSE_ID="$(printf '%s' "$OC_CC" | jq -r '.composeId // ""')"
       [ -n "$OC_COMPOSE_ID" ] && [ "$OC_COMPOSE_ID" != "null" ] || die "compose.create returned no composeId."
       log_ok "Created compose (composeId=${OC_COMPOSE_ID})."
  fi
fi

poll_compose() {
  local id="$1" deadline status
  deadline=$(( $(date +%s) + POLL_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    status="$(projects_json | jq -r --arg i "$id" '[.[].environments[]?.compose[]?] | map(select(.composeId == $i)) | (.[0].composeStatus // "unknown")' 2>/dev/null || echo unknown)"
    [ -n "$status" ] || status="unknown"
    case "$status" in
      done|running) log_ok "OpenClaw compose status: ${status}."; return 0 ;;
      error)        log_fail "OpenClaw compose status: error."; return 1 ;;
      *)            printf '   ...compose status: %s (waiting)\n' "$status" ;;
    esac
    sleep "$POLL_INTERVAL"
  done
  log_fail "Timed out (${POLL_TIMEOUT}s) waiting for OpenClaw compose."
  return 1
}

OC_UP=0
if [ "$OC_ALREADY_UP" -eq 1 ]; then
  log_skip "OpenClaw already deployed and running — leaving it untouched (no redeploy, no cutover)."
  OC_UP=1
else
  log_ok "Setting raw compose file (sourceType=raw) ..."
  api POST "compose.update" "$(jq -n --arg id "$OC_COMPOSE_ID" --arg yaml "$OPENCLAW_YAML" '{composeId:$id, sourceType:"raw", composeType:"docker-compose", composeFile:$yaml}')" >/dev/null
  log_ok "Compose file set."

  if [ -n "$OC_ENV_BLOB" ]; then
    log_ok "Setting compose environment variables (3 keys, values not shown) ..."
    api POST "compose.saveEnvironment" "$(jq -n --arg id "$OC_COMPOSE_ID" --arg env "$OC_ENV_BLOB" '{composeId:$id, env:$env}')" >/dev/null
    log_ok "Environment set."
  else
    log_warn "No env blob loaded; skipping compose.saveEnvironment."
  fi

  log_ok "Deploying OpenClaw compose ..."
  api POST "compose.deploy" "$(jq -n --arg id "$OC_COMPOSE_ID" --arg t "bootstrap import" '{composeId:$id, title:$t}')" >/dev/null
  log_ok "Deploy triggered."

  if [ "$DRY_RUN" -eq 1 ]; then log_warn "[dry-run] skipping OpenClaw poll + cutover."
  elif poll_compose "$OC_COMPOSE_ID"; then OC_UP=1; fi

  if [ "$OC_UP" -eq 1 ]; then
    if [ -f "${OPENCLAW_OLD_DIR}/docker-compose.yml" ]; then
      if confirm "New OpenClaw compose is UP. Stop the OLD manual stack (docker compose -p openclaw-prod down, WITHOUT -v)?"; then
        log_ok "Stopping old manual OpenClaw stack (data volumes preserved) ..."
        ( cd "$OPENCLAW_OLD_DIR" && sudo docker compose -p openclaw-prod down )
        log_ok "Old OpenClaw stack stopped."
      else log_skip "Left old OpenClaw stack running."; fi
    else log_warn "Old stack ${OPENCLAW_OLD_DIR}/docker-compose.yml not found; nothing to cut over."; fi
  elif [ "$DRY_RUN" -eq 0 ]; then
    log_warn "OpenClaw new compose did NOT come up; leaving the old manual stack untouched."
  fi
fi

# ===========================================================================
# APP 2 - Threat Prevention (cp_demo_server)
# ===========================================================================
banner "APP 2 - Threat Prevention (cp_demo_server)"

TP_PROJECT_ID="$(find_project_id_by_name "$TP_PROJECT_NAME")"
if [ -n "$TP_PROJECT_ID" ]; then
  log_skip "Project '${TP_PROJECT_NAME}' exists (projectId=${TP_PROJECT_ID})."
else
  log_ok "Creating project '${TP_PROJECT_NAME}' ..."
  TP_CREATE="$(api POST "project.create" "$(jq -n --arg n "$TP_PROJECT_NAME" --arg d "cp_demo_server threat prevention demo" '{name:$n, description:$d}')")"
  if [ "$DRY_RUN" -eq 1 ]; then TP_PROJECT_ID="dry-run-tp-project"; log_warn "[dry-run] assuming projectId=${TP_PROJECT_ID}"
  else TP_PROJECT_ID="$(printf '%s' "$TP_CREATE" | jq -r '.project.projectId // .projectId // ""')"
       [ -n "$TP_PROJECT_ID" ] && [ "$TP_PROJECT_ID" != "null" ] || die "project.create returned no projectId."
       log_ok "Created project (projectId=${TP_PROJECT_ID})."
  fi
fi

if [ "$DRY_RUN" -eq 1 ] && [ "$TP_PROJECT_ID" = "dry-run-tp-project" ]; then
  TP_ENV_ID="dry-run-tp-env"; log_warn "[dry-run] assuming environmentId=${TP_ENV_ID}"
else
  TP_ENV_ID="$(default_environment_id "$TP_PROJECT_ID")"
  [ -n "$TP_ENV_ID" ] && [ "$TP_ENV_ID" != "null" ] || die "Could not resolve default environmentId for Threat Prevention."
  log_ok "environmentId=${TP_ENV_ID}."
fi

TP_APP_ID=""
if [ "$DRY_RUN" -eq 0 ]; then
  TP_APP_ID="$(projects_json | jq -r --arg p "$TP_PROJECT_ID" --arg n "$TP_APP_NAME" '[.[] | select(.projectId == $p) | .environments[]?.applications[]?] | map(select(.name == $n)) | (.[0].applicationId // "")' 2>/dev/null || true)"
fi
if [ -n "$TP_APP_ID" ]; then
  log_skip "Application '${TP_APP_NAME}' exists (applicationId=${TP_APP_ID}); re-applying config + redeploy."
else
  log_ok "Creating application '${TP_APP_NAME}' ..."
  TP_AC="$(api POST "application.create" "$(jq -n --arg n "$TP_APP_NAME" --arg a "$TP_APPNAME" --arg e "$TP_ENV_ID" '{name:$n, appName:$a, environmentId:$e, description:"Threat Prevention demo server"}')")"
  if [ "$DRY_RUN" -eq 1 ]; then TP_APP_ID="dry-run-tp-app"; log_warn "[dry-run] assuming applicationId=${TP_APP_ID}"
  else TP_APP_ID="$(printf '%s' "$TP_AC" | jq -r '.applicationId // ""')"
       [ -n "$TP_APP_ID" ] && [ "$TP_APP_ID" != "null" ] || die "application.create returned no applicationId."
       log_ok "Created application (applicationId=${TP_APP_ID})."
  fi
fi

log_ok "Attaching public git provider (${TP_GIT_URL} @ ${TP_GIT_BRANCH}) ..."
api POST "application.saveGitProvider" "$(jq -n --arg id "$TP_APP_ID" --arg url "$TP_GIT_URL" --arg br "$TP_GIT_BRANCH" '{applicationId:$id, customGitUrl:$url, customGitBranch:$br, customGitBuildPath:"/", watchPaths:[], enableSubmodules:false}')" >/dev/null
log_ok "Git provider set."

log_ok "Setting build type (Dockerfile) ..."
api POST "application.saveBuildType" "$(jq -n --arg id "$TP_APP_ID" '{applicationId:$id, buildType:"dockerfile", dockerfile:"Dockerfile", dockerContextPath:".", dockerBuildStage:"", herokuVersion:"", railpackVersion:""}')" >/dev/null
log_ok "Build type set."

TP_DOMAIN_ID=""
if [ "$DRY_RUN" -eq 0 ]; then
  TP_DOMAIN_ID="$(projects_json | jq -r --arg id "$TP_APP_ID" --arg h "$TP_DOMAIN" '[.[].environments[]?.applications[]?] | map(select(.applicationId == $id)) | (.[0].domains // []) | map(select(.host == $h)) | (.[0].domainId // "")' 2>/dev/null || true)"
fi
if [ -n "$TP_DOMAIN_ID" ]; then
  log_skip "Domain ${TP_DOMAIN} already attached (domainId=${TP_DOMAIN_ID})."
else
  log_ok "Creating domain ${TP_DOMAIN} -> port ${TP_PORT} (https, letsencrypt) ..."
  if ( api POST "domain.create" "$(jq -n --arg h "$TP_DOMAIN" --arg id "$TP_APP_ID" --argjson port "$TP_PORT" '{host:$h, applicationId:$id, domainType:"application", port:$port, https:true, certificateType:"letsencrypt", path:"/", internalPath:"/", stripPath:false, forwardAuthEnabled:false}')" >/dev/null ); then
    log_ok "Domain created."
  else
    log_warn "domain.create did not succeed (it may already exist); continuing."
  fi
fi

log_ok "Deploying Threat Prevention application ..."
api POST "application.deploy" "$(jq -n --arg id "$TP_APP_ID" --arg t "bootstrap import" '{applicationId:$id, title:$t}')" >/dev/null
log_ok "Deploy triggered."

poll_application() {
  local id="$1" deadline status
  deadline=$(( $(date +%s) + POLL_TIMEOUT ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    status="$(projects_json | jq -r --arg i "$id" '[.[].environments[]?.applications[]?] | map(select(.applicationId == $i)) | (.[0].applicationStatus // "unknown")' 2>/dev/null || echo unknown)"
    [ -n "$status" ] || status="unknown"
    case "$status" in
      done|running) log_ok "Threat Prevention app status: ${status}."; return 0 ;;
      error)        log_fail "Threat Prevention app status: error."; return 1 ;;
      *)            printf '   ...app status: %s (waiting)\n' "$status" ;;
    esac
    sleep "$POLL_INTERVAL"
  done
  log_fail "Timed out (${POLL_TIMEOUT}s) waiting for Threat Prevention app."
  return 1
}

# Reachability check tolerant of a still-issuing Let's Encrypt cert (-k) and of
# routing via loopback. Accept any non-5xx (and non-000) as "serving".
verify_tp_serving() {
  local code
  code="$(curl -skS -o /dev/null -w '%{http_code}' --max-time 15 --resolve "${TP_DOMAIN}:443:127.0.0.1" "https://${TP_DOMAIN}/" 2>/dev/null || true)"
  if [ -z "$code" ] || [ "$code" = "000" ]; then
    code="$(curl -skS -o /dev/null -w '%{http_code}' --max-time 15 "https://${TP_DOMAIN}/" 2>/dev/null || true)"
  fi
  if [ -n "$code" ] && [ "$code" != "000" ] && [ "${code:0:1}" != "5" ]; then
    log_ok "Threat Prevention endpoint responded (HTTP ${code})."; return 0
  fi
  log_warn "Threat Prevention endpoint not healthy yet (HTTP ${code:-none})."; return 1
}

TP_UP=0
if [ "$DRY_RUN" -eq 1 ]; then log_warn "[dry-run] skipping Threat Prevention poll + cutover."
elif poll_application "$TP_APP_ID"; then
  if verify_tp_serving; then TP_UP=1
  else log_warn "App is up per Dokploy but the domain isn't serving yet (cert/DNS settling). Not cutting over automatically."; fi
fi

if [ "$TP_UP" -eq 1 ]; then
  if sudo docker ps -a --format '{{.Names}}' | grep -qx "$TP_OLD_CONTAINER"; then
    if confirm "New Threat Prevention app is serving. Remove OLD standalone container '${TP_OLD_CONTAINER}' (docker rm -f)?"; then
      log_ok "Removing old container '${TP_OLD_CONTAINER}' ..."
      sudo docker rm -f "$TP_OLD_CONTAINER" >/dev/null
      log_ok "Old container removed."
    else log_skip "Left old container '${TP_OLD_CONTAINER}' in place."; fi
  else log_skip "No old container named '${TP_OLD_CONTAINER}'."; fi

  if [ -d "$TRAEFIK_DYNAMIC_DIR" ]; then
    STALE="$(sudo grep -rIl "$TP_DOMAIN" "$TRAEFIK_DYNAMIC_DIR" 2>/dev/null | grep -E '\.(ya?ml|toml)$' || true)"
    if [ -n "$STALE" ]; then
      log_warn "Stale file-based Traefik route(s) referencing ${TP_DOMAIN}:"
      printf '%s\n' "$STALE" | sed 's/^/     /'
      if confirm "Back up and remove the stale Traefik route file(s) above?"; then
        ts="$(date +%Y%m%d-%H%M%S)"
        while IFS= read -r route; do
          [ -n "$route" ] || continue
          sudo cp -a "$route" "${route}.bak-${ts}"
          sudo rm -f "$route"
          log_ok "Removed ${route} (backup: ${route}.bak-${ts})."
        done <<< "$STALE"
      else log_skip "Left stale Traefik route file(s) in place."; fi
    else log_skip "No stale file-based Traefik route for ${TP_DOMAIN}."; fi
  else log_skip "Traefik dynamic dir ${TRAEFIK_DYNAMIC_DIR} not present."; fi
elif [ "$DRY_RUN" -eq 0 ]; then
  log_warn "Threat Prevention new app not confirmed serving; leaving the old container + routes untouched."
fi

# ===========================================================================
# Summary
# ===========================================================================
banner "Summary"
printf 'OpenClaw          : %s\n' "${OPENCLAW_PROJECT_NAME} (projectId=${OC_PROJECT_ID:-?}, composeId=${OC_COMPOSE_ID:-?})"
printf 'Threat Prevention : %s\n' "${TP_PROJECT_NAME} (projectId=${TP_PROJECT_ID:-?}, applicationId=${TP_APP_ID:-?})"
echo
if [ "$DRY_RUN" -eq 1 ]; then
  log_warn "DRY-RUN complete. No changes made. Re-run without --dry-run to apply."
else
  [ "${OC_UP:-0}" -eq 1 ] && log_ok "OpenClaw deployed." || log_warn "OpenClaw not confirmed up - review logs above."
  [ "${TP_UP:-0}" -eq 1 ] && log_ok "Threat Prevention deployed." || log_warn "Threat Prevention not confirmed serving - review logs above."
fi
echo
echo "Next steps:"
echo "  1. Verify OpenClaw:          https://claw.ai.alshawwaf.ca/"
echo "  2. Verify Threat Prevention: https://${TP_DOMAIN}/"
echo "  3. Both now appear in Dokploy (project.all) and in the portal's app picker."
echo "  4. If a domain isn't serving yet, give letsencrypt/DNS a minute; cutover of the"
echo "     old stack/container only runs once the new one is confirmed up."
exit 0
