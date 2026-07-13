#!/usr/bin/env bash
#
# install.sh — one-line provisioner for the ubuntu-dokploy-ai stack.
#
# Run ON a freshly installed Ubuntu host (as root):
#
#   curl -fsSL https://raw.githubusercontent.com/alshawwaf/ubuntu-dokploy-ai/main/install.sh | sudo bash -s -- --domain example.com
#
# or clone the repo and run ./install.sh --domain example.com.
#
# It is idempotent: generated secrets are persisted and reused, package/Docker/
# Dokploy installs are guarded, and firewall rules re-apply cleanly. Re-running
# redeploys the apps from automation/dokploy_config.json.
#
# Order:  preflight -> firewall -> Docker+Dokploy -> self SSH key -> secrets
#         -> DNS pre-check -> deploy (dokploy_automate.py) -> verify.
#
# Uninstall (full teardown of everything the installer put on the host):
#
#   sudo ./install.sh --uninstall [--answers answers.env] [--yes]
#                     [--keep-images] [--purge-secrets] [--remove-docker]
#
#   Removes containers, swarm state, volumes/networks/images, /etc/dokploy,
#   cloudflared + the Cloudflare tunnel and the DNS records pointing at it
#   (never anything else in the zone). Keeps host hardening always; keeps the
#   Docker engine and the secrets store unless the respective purge flag is
#   given. --yes skips the interactive confirmation.
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Defaults / configuration (flags override; env vars are the fallback).
# ---------------------------------------------------------------------------
REPO_URL="${REPO_URL:-https://github.com/alshawwaf/ubuntu-dokploy-ai.git}"
AGENTIC_REPO_URL="${AGENTIC_REPO_URL:-https://github.com/alshawwaf/cp-agentic-mcp-playground.git}"
INSTALL_DIR="${INSTALL_DIR:-/opt/ubuntu-dokploy-ai}"
STORE="${STORE:-/etc/dokploy-ai/secrets.env}"
ANSWERS="${ANSWERS:-answers.env}"
DOMAIN="${ROOT_DOMAIN:-}"
ADMIN_EMAIL="${DOKPLOY_ADMIN_EMAIL:-}"
ADMIN_PASSWORD="${DOKPLOY_ADMIN_PASSWORD:-}"
SKIP_HARDEN="${SKIP_HARDEN:-0}"
SKIP_DNS_CHECK="${SKIP_DNS_CHECK:-0}"
DNS_WARN_ONLY="${DNS_WARN_ONLY:-0}"
CLEAN=""

# Ingress mode: letsencrypt (default, public inbound + HTTP-01) or tunnel
# (Cloudflare Tunnel fronts the box; no public inbound needed).
INGRESS_MODE="${INGRESS_MODE:-letsencrypt}"
CLOUDFLARE_API_TOKEN="${CLOUDFLARE_API_TOKEN:-}"
CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
CLOUDFLARE_TUNNEL_NAME="${CLOUDFLARE_TUNNEL_NAME:-}"
CLOUDFLARE_RECREATE_TUNNEL="${CLOUDFLARE_RECREATE_TUNNEL:-}"
DOKPLOY_GATE_USER="${DOKPLOY_GATE_USER:-}"
DOKPLOY_GATE_PASSWORD="${DOKPLOY_GATE_PASSWORD:-}"

# Destructive-mode flags are deliberately NOT env-inheritable: only the explicit
# command-line flags below can arm them.
UNINSTALL=0
ASSUME_YES=0
KEEP_IMAGES=0
PURGE_SECRETS=0
REMOVE_DOCKER=0

# ---------------------------------------------------------------------------
# Progress framework.  Two renderers, chosen automatically:
#   * RICH (interactive terminal): a fixed dashboard pinned to the top of the
#     screen — banner, progress bar, current step, elapsed — with a live log
#     pane scrolling underneath it (ANSI scroll region). This is the Docker-
#     installer look.
#   * PLAIN (piped to a file / nohup / dumb TERM): the numbered-step lines you
#     get today, so log files stay clean and readable. Force with --plain or
#     NO_RICH_UI=1.
# Both collect warnings, name the failing step on error, and end with a table.
# ---------------------------------------------------------------------------
RUN_T0="$(date +%s)"
STEP_TOTAL=14
STEP_NO=0
STEP_DONE=0
STEP_TITLE=""
STEP_T0="$RUN_T0"
STEP_STATUS="done"
STEP_LINES=()
WARNINGS=()
UI_MODE_LABEL=""
UI_HOST=""
UI_OS=""
_EL=""
_ELS=""
_NAP_OK=0
UI_H=6          # fixed header rows
UI_LOGH=14      # fixed log-box rows (the live output is CONTAINED to these)
UI_ROWS=24
UI_COLS=80

# Pick the renderer: rich only on a real terminal with a capable TERM.
UI_RICH=0
if [ -t 1 ] && [ -z "${NO_RICH_UI:-}" ]; then
  case "${TERM:-dumb}" in
    dumb|"") : ;;
    *) UI_RICH=1 ;;
  esac
fi

_elapsed() { _set_elapsed _EL; printf '%s' "$_EL"; }

_step_close() {
  [ "$STEP_NO" -eq 0 ] && return 0
  local secs=$(( $(date +%s) - STEP_T0 ))
  STEP_LINES+=("$(printf '%2d|%s|%s|%ss' "$STEP_NO" "$STEP_TITLE" "$STEP_STATUS" "$secs")")
  STEP_DONE=$((STEP_DONE+1))
  case "$STEP_STATUS" in
    warn)    STEP_ST[$STEP_NO]="warn" ;;
    skipped) STEP_ST[$STEP_NO]="skip" ;;
    *)       STEP_ST[$STEP_NO]="done" ;;
  esac
  STEP_SEC[$STEP_NO]="${secs}s"
}

# ---- rich renderer (in-place status dashboard, docker-compose style) -----
# No log scrolling: the whole frame is repainted from state each tick on the
# ALTERNATE screen (so the user's shell + scrollback are untouched and restored
# on exit). Raw command output is tee'd to $RUN_LOG and only the last few lines
# are shown live, so nothing is ever lost.
RUN_LOG="${RUN_LOG:-/var/log/dokploy-ai-install.log}"
STEP_NAMES=()      # per-step title (seeded from the plan so pending steps show)
STEP_ST=()         # per-step state: pending|running|done|warn|skip
STEP_SEC=()        # per-step duration text
ACT=()             # ring buffer of recent output lines
ACT_MAX=8
SPIN_FRAMES=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)   # array (multibyte-safe; substring on a string is locale-fragile)
SPIN_I=0
UI_ALT=0

# All of these SET a global instead of printing, so _ui_render can call them as
# statements (no $() subshell fork per frame — the real cost under I/O load).
declare -A _RULE_CACHE
_RULE_OUT=""
_set_rule() {
  local w="$1"
  if [ -z "${_RULE_CACHE[$w]:-}" ]; then
    local i out=""; for ((i=0;i<w;i++)); do out="${out}─"; done; _RULE_CACHE[$w]="$out"
  fi
  _RULE_OUT="${_RULE_CACHE[$w]}"
}
_ui_rule() { _set_rule "$1"; printf '%s' "$_RULE_OUT"; }   # printing wrapper (non-hot callers)
_os_short() { ( . /etc/os-release 2>/dev/null || true; printf '%s %s' "${NAME:-Linux}" "${VERSION_ID:-}" ); }
_SPINCH=""
_spin() { SPIN_I=$(( (SPIN_I+1) % ${#SPIN_FRAMES[@]} )); _SPINCH="${SPIN_FRAMES[$SPIN_I]}"; }
_set_elapsed() { local s=$(( ${EPOCHSECONDS:-$(date +%s)} - ${2:-$RUN_T0} )); printf -v "$1" '%02d:%02d' $((s/60)) $((s%60)); }
_BAR_KEY=""; _BAR_OUT=""
_set_bar() {
  local done="$1" total="$2" width="$3" key="$1|$2|$3"
  [ "$key" = "$_BAR_KEY" ] && return 0
  local E=$'"'"'\033'"'"' fill i ci out
  local ramp=(57 63 99 135 171 207 213 219) n=8
  out="${E}[38;5;239m▕"
  if [ "$total" -gt 0 ]; then fill=$(( done*width/total )); else fill=0; fi
  for ((i=0;i<width;i++)); do
    if [ "$i" -lt "$fill" ]; then ci=$(( i*n/width )); [ "$ci" -ge "$n" ] && ci=$((n-1)); out="${out}${E}[38;5;${ramp[$ci]}m█"
    else out="${out}${E}[38;5;238m░"; fi
  done
  _BAR_KEY="$key"; _BAR_OUT="${out}${E}[38;5;239m▏${E}[0m"
}
# no-fork fractional sleep: read with a timeout on a persistent fifo fd (fd 8),
# so the animation ticker doesn't fork /usr/bin/sleep every 0.5s under load.
_nap_setup() {
  [ "$_NAP_OK" = 1 ] && return 0
  local f; f="$(mktemp -u 2>/dev/null)" || return 0
  mkfifo "$f" 2>/dev/null || return 0
  exec 8<>"$f" 2>/dev/null && _NAP_OK=1
  rm -f "$f"; return 0
}
_nap() { if [ "$_NAP_OK" = 1 ]; then read -rt "$1" -u 8 _ 2>/dev/null || true; else sleep "$1"; fi; }
_ui_size() {
  UI_ROWS="$( tput lines 2>/dev/null || echo "${LINES:-24}" )"
  UI_COLS="$( tput cols  2>/dev/null || echo "${COLUMNS:-80}" )"
  [ "$UI_ROWS" -ge 12 ] 2>/dev/null || UI_ROWS=24
  [ "$UI_COLS" -ge 40 ] 2>/dev/null || UI_COLS=80
  # Rows: header(4) + checklist(STEP_TOTAL) + divider(1) = fixed; the rest is
  # the live activity panel, clamped so it never overflows a short terminal.
  ACT_MAX=$(( UI_ROWS - 4 - STEP_TOTAL - 2 ))
  [ "$ACT_MAX" -lt 3 ]  && ACT_MAX=3
  [ "$ACT_MAX" -gt 12 ] && ACT_MAX=12
  return 0   # a trailing `[ ] && …` that tests false would otherwise make this
             # function return non-zero and trip the ERR trap under set -e
}
# Push a raw output line into the activity ring (+ persist to the log file).
_ui_push() {
  printf '%s\n' "$1" >>"$RUN_LOG" 2>/dev/null || true
  ACT+=("$1")
  while [ "${#ACT[@]}" -gt "$ACT_MAX" ]; do ACT=("${ACT[@]:1}"); done
}
# Repaint the entire frame from state. Absolute-addressed, each row cleared.
_ui_render() {
  [ "$UI_RICH" = 1 ] || return 0
  local E=$'\033' pct barw brand badge mid warns i st name sec icon col line f pad namep hdr rw
  pct=$(( STEP_TOTAL>0 ? STEP_DONE*100/STEP_TOTAL : 0 ))
  barw=$(( UI_COLS - 12 )); [ "$barw" -lt 12 ] && barw=12; [ "$barw" -gt 64 ] && barw=64
  brand=" ◆ ubuntu-dokploy-ai · one-command provisioner "
  badge="[ ${UI_MODE_LABEL} ]"
  mid=$(( UI_COLS - ${#brand} - ${#badge} - 1 )); [ "$mid" -lt 1 ] && mid=1
  printf -v pad '%*s' "$mid" ''
  warns=""; [ "${#WARNINGS[@]}" -gt 0 ] && warns="   ${E}[38;5;214m⚠ ${#WARNINGS[@]}${E}[0m"
  _spin; _set_elapsed _EL; _set_bar "$STEP_DONE" "$STEP_TOTAL" "$barw"
  # Build the WHOLE frame in one string (raw ESC bytes) and write it with ONE
  # printf — no $() subshell forks and one terminal write, so the ticker stays
  # on cadence even while a heavy step saturates the box.
  f="${E}[H"
  f+="${E}[K${E}[48;5;53;1;97m${brand}${pad}${E}[38;5;219m${badge} ${E}[0m"$'\n'
  f+="${E}[K  ${E}[38;5;45m${DOMAIN:-?}${E}[38;5;240m · ${E}[38;5;250m${UI_HOST}${E}[38;5;240m · ${E}[38;5;244m${UI_OS}${E}[0m    ${E}[38;5;213m◷${E}[0m ${E}[1;97m${_EL}${E}[0m   ${E}[38;5;120m✓ ${STEP_DONE}/${STEP_TOTAL}${E}[0m${warns}"$'\n'
  f+="${E}[K  ${_BAR_OUT} ${E}[1;38;5;219m${pct}%${E}[0m"$'\n'
  f+="${E}[K"$'\n'
  for ((i=1;i<=STEP_TOTAL;i++)); do
    st="${STEP_ST[$i]:-pending}"; name="${STEP_NAMES[$i]:-}"; sec="${STEP_SEC[$i]:-}"
    case "$st" in
      done)    icon="${E}[38;5;120m✔${E}[0m"; col="${E}[38;5;252m"; sec="${E}[38;5;240m${sec}${E}[0m" ;;
      running) icon="${E}[1;38;5;213m${_SPINCH}${E}[0m"; col="${E}[1;97m"; _set_elapsed _ELS "$STEP_T0"; sec="${E}[38;5;213m${_ELS}${E}[0m" ;;
      warn)    icon="${E}[38;5;214m▲${E}[0m"; col="${E}[38;5;252m"; sec="${E}[38;5;214m${sec}${E}[0m" ;;
      skip)    icon="${E}[38;5;244m⤼${E}[0m"; col="${E}[38;5;244m"; sec="${E}[38;5;240mskipped${E}[0m" ;;
      *)       icon="${E}[38;5;238m○${E}[0m"; col="${E}[38;5;242m"; sec="" ;;
    esac
    printf -v namep '%-42s' "$name"
    f+="${E}[K  ${icon} ${col}${namep}${E}[0m ${sec}"$'\n'
  done
  if [ "$STEP_NO" -ge "$STEP_TOTAL" ]; then hdr=apps; else hdr=activity; fi
  rw=$(( UI_COLS>14 ? UI_COLS-14 : 4 )); _set_rule "$rw"
  f+="${E}[K${E}[38;5;53m─ ${E}[38;5;219m${hdr} ${E}[38;5;53m${_RULE_OUT}${E}[0m"$'\n'
  for ((i=0;i<ACT_MAX;i++)); do
    line="${ACT[$i]:-}"
    f+="${E}[K${E}[38;5;245m${line:0:$((UI_COLS-1))}${E}[0m"$'\n'
  done
  f+="${E}[J"
  printf '%s' "$f"
}
_ui_init() {
  [ "$UI_RICH" = 1 ] || return 0
  _ui_size
  : >"$RUN_LOG" 2>/dev/null || true
  UI_HOST="$(hostname 2>/dev/null || echo host)"; UI_OS="$(_os_short)"; _nap_setup   # cached statics + no-fork nap fd
  printf '\033[?1049h\033[?25l\033[2J'   # alt screen, hide cursor, clear
  UI_ALT=1
  _ui_render
}
_ui_reset() {
  [ "${UI_RICH:-0}" = 1 ] || return 0
  UI_RICH=0
  if [ "$UI_ALT" = 1 ]; then
    printf '\033[?25h\033[?1049l'         # show cursor, leave alt screen (scrollback restored)
    UI_ALT=0
  fi
}
_ui_winch() { [ "$UI_RICH" = 1 ] || return 0; _ui_size; printf '\033[2J'; _ui_render; }
_elapsed_since() { _set_elapsed _ELS "${1:-$RUN_T0}"; printf '%s' "$_ELS"; }

# Run a command; stream its output through the activity panel (in place, not
# scrolling) and persist the full output to $RUN_LOG. Consecutive duplicate
# lines collapse to one "(×N)" entry. Trailing ':' keeps the loop status 0 so
# a successful command never trips the ERR trap under pipefail.
_stream() {
  if [ "$UI_RICH" = 1 ]; then
    local rc n=0 last="" dup=0
    "$@" 2>&1 | while IFS= read -r _line; do
      if [ "$_line" = "$last" ]; then
        dup=$((dup+1))
        [ "${#ACT[@]}" -gt 0 ] && ACT[$(( ${#ACT[@]}-1 ))]="$_line (×$((dup+1)))"
        printf '%s (×%d)\n' "$_line" "$((dup+1))" >>"$RUN_LOG" 2>/dev/null || true
      else
        _ui_push "$_line"; last="$_line"; dup=0
      fi
      n=$((n+1)); [ $(( n % 2 )) -eq 0 ] && _ui_render
      :
    done
    rc=${PIPESTATUS[0]}
    _ui_render
    return "$rc"
  else
    "$@"
  fi
}

# Run a slow, SILENT command (e.g. `docker image prune`) while keeping the
# dashboard's step-timer + spinner ANIMATING, so it never looks frozen. A
# background ticker repaints ~1/s while the foreground is blocked in the
# command — no terminal race, because the foreground isn't drawing meanwhile.
# The command's own output is discarded; pair it with a log() line first to
# give the activity panel context. Falls back to a plain silent run.
_run() {
  if [ "$UI_RICH" != 1 ]; then "$@" >/dev/null 2>&1; return $?; fi
  ( while :; do _ui_render; _nap 0.5; done ) &
  local _tk=$!
  "$@" >/dev/null 2>&1; local _rc=$?
  kill "$_tk" 2>/dev/null || true; wait "$_tk" 2>/dev/null || true
  _ui_render
  return "$_rc"
}

# ---- unified step / log / warn ------------------------------------------
step() {
  _step_close
  STEP_NO=$((STEP_NO+1)); STEP_TITLE="$1"; STEP_T0="$(date +%s)"; STEP_STATUS="done"
  ACT=()   # fresh activity panel per step
  if [ "$UI_RICH" = 1 ]; then
    STEP_NAMES[$STEP_NO]="$1"; STEP_ST[$STEP_NO]="running"
    _ui_render
  else
    printf '\n\033[1;36m[%2d/%d] %s\033[0m \033[0;90m· t+%s\033[0m\n' \
      "$STEP_NO" "$STEP_TOTAL" "$STEP_TITLE" "$(_elapsed)"
  fi
}
skip_step() {
  step "$1"; STEP_STATUS="skipped"
  if [ "$UI_RICH" = 1 ]; then STEP_ST[$STEP_NO]="skip"; _ui_push "skipped — $2"; _ui_render
  else printf '  \033[38;5;244m⤼ skipped — %s\033[0m\n' "$2"; fi
}
log() {
  if [ "$UI_RICH" = 1 ]; then _ui_push "$*"; _ui_render
  else printf '  \033[38;5;141m·\033[0m %s\n' "$*"; fi
}
warn() {
  WARNINGS+=("[${STEP_NO}/${STEP_TOTAL} ${STEP_TITLE:-preflight}] $*")
  [ "$STEP_STATUS" = "done" ] && STEP_STATUS="warn"
  if [ "$UI_RICH" = 1 ]; then
    [ "$STEP_NO" -gt 0 ] && STEP_ST[$STEP_NO]="warn"
    _ui_push "⚠ WARN: $*"; _ui_render
  else
    printf '  \033[1;33m! WARN: %s\033[0m\n' "$*" >&2
  fi
  return 0
}
die()  { _ui_reset; printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Plain-mode banner (rich mode draws its banner in the pinned header instead).
print_banner() {
  printf '\033[1;36m'
  printf '┌──────────────────────────────────────────────────────────────┐\n'
  printf '│  ubuntu-dokploy-ai · one-command stack provisioner           │\n'
  printf '└──────────────────────────────────────────────────────────────┘\033[0m\n'
  printf '  \033[0;90mMode\033[0m     %s\n' "$1"
  printf '  \033[0;90mDomain\033[0m   %s\n' "${DOMAIN:-<from answers.env>}"
  printf '  \033[0;90mHost\033[0m     %s (%s)\n' "$(hostname)" "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
  printf '  \033[0;90mStarted\033[0m  %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
}

# Seed the step checklist so pending steps are visible from the start (their
# titles are corrected by step() as each is reached).
_ui_seed_plan() {
  local names=()
  if [ "$STEP_TOTAL" = 9 ]; then
    names=("" "Inventory & confirmation" "Tearing down Docker Swarm"
      "Stopping and removing containers" "Removing Docker volumes and networks"
      "Removing Docker images" "Stopping cloudflared"
      "Cloudflare cleanup (tunnel + DNS)" "Removing Dokploy files and clones"
      "Optional purges + final report")
  else
    names=("" "Preflight checks" "Base packages" "Base firewall" "Docker engine"
      "Dokploy platform" "Traefik hubframe middleware" "Host hardening"
      "Loopback SSH key" "Secrets & env rendering" "Cloudflare Tunnel ingress"
      "Agentic playground fetch" "DNS pre-check" "Stack deploy via Dokploy"
      "Waiting for apps to build & come up")
  fi
  local i
  for ((i=1;i<=STEP_TOTAL;i++)); do STEP_NAMES[$i]="${names[$i]:-step $i}"; STEP_ST[$i]="pending"; done
}
# Enter the chosen renderer for a run mode (rich: in-place dashboard; plain: banner).
ui_begin() {
  UI_MODE_LABEL="$1"
  if [ "$UI_RICH" = 1 ]; then _ui_seed_plan; _ui_init; else print_banner "$2"; fi
}

print_step_table() {
  _ui_reset                                   # drop out of the pinned layout first
  _step_close
  local W=64
  printf '\n\033[38;5;53m╭─\033[38;5;219m run summary \033[38;5;53m%s╮\033[0m\n' "$(_ui_rule $((W-13)))"
  local line
  if [ "${#STEP_LINES[@]}" -gt 0 ]; then
  for line in "${STEP_LINES[@]}"; do
    local no="${line%%|*}" rest="${line#*|}"
    local title="${rest%%|*}"; rest="${rest#*|}"
    local status="${rest%%|*}" secs="${rest#*|}"
    local mark='\033[1;38;5;120m✔\033[0m'
    [ "$status" = "warn" ]    && mark='\033[1;38;5;214m▲\033[0m'
    [ "$status" = "skipped" ] && mark='\033[38;5;244m⤼\033[0m'
    printf "\033[38;5;53m│\033[0m ${mark} \033[38;5;141m%2s\033[0m  \033[97m%-42s\033[0m \033[38;5;244m%-8s %6s\033[0m\n" "$no" "$title" "$status" "$secs"
  done
  fi
  printf '\033[38;5;53m╰%s╯\033[0m\n' "$(_ui_rule $((W-1)))"
  printf '  \033[38;5;244mtotal elapsed \033[38;5;213m%s\033[0m   \033[38;5;244mfull log \033[38;5;250m%s\033[0m\n' "$(_elapsed)" "$RUN_LOG"
  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    printf '\n\033[1;38;5;214m▲ %d warning(s) — review before calling this healthy:\033[0m\n' "${#WARNINGS[@]}"
    local w; for w in "${WARNINGS[@]}"; do printf '  \033[38;5;214m▲\033[0m %s\n' "$w"; done
  else
    printf '\n\033[1;38;5;120m✔ no warnings — clean run.\033[0m\n'
  fi
}

_on_err() {
  local code=$?
  _ui_reset
  printf '\n\033[48;5;52;1;97m ✖ FAILED \033[0m \033[1;38;5;203mstep %d/%d (%s)\033[0m \033[38;5;244mafter %s · exit %d\033[0m\n' \
    "$STEP_NO" "$STEP_TOTAL" "${STEP_TITLE:-preflight}" "$(_elapsed)" "$code" >&2
  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    printf '\033[1;38;5;214mwarnings up to the failure:\033[0m\n' >&2
    local w; for w in "${WARNINGS[@]}"; do printf '  \033[38;5;214m▲\033[0m %s\n' "$w" >&2; done
  fi
  exit "$code"
}
trap _ui_reset EXIT
trap _on_err ERR
trap _ui_winch WINCH

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [ "$#" -gt 0 ]; do
  case "$1" in
    --domain)          DOMAIN="$2"; shift 2 ;;
    --answers)         ANSWERS="$2"; shift 2 ;;
    --admin-email)     ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-password)  ADMIN_PASSWORD="$2"; shift 2 ;;
    --store)           STORE="$2"; shift 2 ;;
    --skip-harden)     SKIP_HARDEN=1; shift ;;
    --skip-dns-check)  SKIP_DNS_CHECK=1; shift ;;
    --dns-warn-only)   DNS_WARN_ONLY=1; shift ;;
    --ingress)         INGRESS_MODE="$2"; shift 2 ;;
    --clean)           CLEAN="--clean"; shift ;;
    --plain)           UI_RICH=0; shift ;;
    --uninstall)       UNINSTALL=1; shift ;;
    --yes)             ASSUME_YES=1; shift ;;
    --keep-images)     KEEP_IMAGES=1; shift ;;
    --purge-secrets)   PURGE_SECRETS=1; shift ;;
    --remove-docker)   REMOVE_DOCKER=1; shift ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

# Read a KEY=value from the answers file (used by install preflight AND uninstall).
answers_value() {
  local key="$1"
  [ -f "$ANSWERS" ] || return 0
  awk -F= -v k="^${key}=" '$0 ~ k {sub(/^[^=]*=/, ""); print; exit}' "$ANSWERS" | tr -d '[:space:]'
}

# ---------------------------------------------------------------------------
# Uninstall: full teardown of everything this installer put on the host.
# Removes: every container, swarm state, docker volumes/networks (+ images
# unless --keep-images), /etc/dokploy, cloudflared (service + config), the
# Cloudflare tunnel and the DNS records POINTING AT IT (never anything else),
# the Agentic clone, and our loopback authorized_keys entry.
# Keeps: host hardening (firewall/fail2ban/sshd — dropping it would expose the
# box), the Docker engine (--remove-docker to purge), and the secrets store
# (--purge-secrets to purge; keeping it means a reinstall reuses passwords).
# ---------------------------------------------------------------------------
run_uninstall() {
  STEP_TOTAL=9

  # Locate the repo the same way the install path does (cwd -> script dir ->
  # INSTALL_DIR) so generated-artifact paths match what install actually used.
  if [ -f "automation/dokploy_automate.py" ]; then
    U_REPO_DIR="$(pwd)"
  elif [ -f "$(dirname "$0")/automation/dokploy_automate.py" ]; then
    U_REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
  elif [ -d "$INSTALL_DIR" ]; then
    U_REPO_DIR="$INSTALL_DIR"
  else
    U_REPO_DIR=""
  fi
  # A relative --answers resolves against the caller's cwd first, then the repo.
  if [ ! -f "$ANSWERS" ] && [ -n "$U_REPO_DIR" ] && [ -f "$U_REPO_DIR/$ANSWERS" ]; then
    ANSWERS="$U_REPO_DIR/$ANSWERS"
  fi
  [ -n "$DOMAIN" ]                 || DOMAIN="$(answers_value DOMAIN)"
  [ -n "$CLOUDFLARE_API_TOKEN" ]   || CLOUDFLARE_API_TOKEN="$(answers_value CLOUDFLARE_API_TOKEN)"
  [ -n "$CLOUDFLARE_ACCOUNT_ID" ]  || CLOUDFLARE_ACCOUNT_ID="$(answers_value CLOUDFLARE_ACCOUNT_ID)"
  [ -n "$CLOUDFLARE_TUNNEL_NAME" ] || CLOUDFLARE_TUNNEL_NAME="$(answers_value CLOUDFLARE_TUNNEL_NAME)"

  ui_begin "UNINSTALL" "UNINSTALL — full stack removal"

  step "Inventory & confirmation"
  local n_containers=0 n_volumes=0 n_images=0
  if command -v docker >/dev/null 2>&1; then
    # `|| true` INSIDE each substitution: with the docker CLI present but the
    # daemon down (a half-torn-down box), a failing pipeline here would abort
    # the whole uninstall before the confirmation gate.
    n_containers="$( { docker ps -aq 2>/dev/null || true; } | wc -l | tr -d ' ')"
    n_volumes="$( { docker volume ls -q 2>/dev/null || true; } | wc -l | tr -d ' ')"
    n_images="$( { docker images -q 2>/dev/null || true; } | sort -u | wc -l | tr -d ' ')"
  fi
  TUNNEL_UUID=""
  [ -f /etc/cloudflared/config.yml ] && \
    TUNNEL_UUID="$(awk '/^tunnel:/{gsub(/["'"'"']/,"",$2); print $2; exit}' /etc/cloudflared/config.yml)"
  log "containers: $n_containers   volumes: $n_volumes   images: $n_images$( [ "$KEEP_IMAGES" = "1" ] && echo ' (kept)' )"
  log "dokploy dir: $( [ -d /etc/dokploy ] && echo present || echo absent )   cloudflared tunnel: ${TUNNEL_UUID:-none}"
  log "kept: host hardening$( [ "$REMOVE_DOCKER" = "1" ] || echo ', Docker engine' )$( [ "$PURGE_SECRETS" = "1" ] || echo ", secrets store ($STORE)" )"
  if [ "$ASSUME_YES" != "1" ]; then
    if [ -t 0 ]; then
      printf '  \033[1;33mType "yes" to remove ALL of the above from this host: \033[0m'
      read -r _reply || die "aborted (EOF while reading confirmation)."
      [ "$_reply" = "yes" ] || die "aborted (answer was not 'yes')."
    else
      die "refusing to uninstall non-interactively without --yes."
    fi
  fi

  step "Tearing down Docker Swarm"
  # Leave the swarm FIRST so it stops managing/respawning task containers, then
  # give the manager a moment to drain. Removing services first (the old order)
  # kicks off async task shutdown and races 'swarm leave', which is what
  # produced the spurious "could not leave the swarm" warning. 'swarm leave'
  # removes the services for us. Only warn if the node is STILL a swarm member
  # after a short retry — i.e. the end state is actually dirty.
  if command -v docker >/dev/null 2>&1 && docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active; then
    local _t
    log "leaving the Docker swarm (draining services)…"
    for _t in 1 2 3; do
      _run docker swarm leave --force || true
      docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active || break
      sleep 2
    done
    if docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active; then
      warn "node is still a swarm member after retries."
    else
      log "swarm left (services drained)."
    fi
  else
    log "no active swarm."
  fi

  step "Stopping and removing containers"
  # Retry: swarm task containers can be mid-shutdown on the first pass. Only warn
  # if containers actually REMAIN after a few attempts (a genuinely stuck one),
  # not for the transient in-flight ones the next pass mops up.
  if command -v docker >/dev/null 2>&1; then
    local _p _ids
    for _p in 1 2 3; do
      _ids="$( docker ps -aq 2>/dev/null || true )"
      [ -z "$_ids" ] && break
      log "force-removing $(printf '%s\n' "$_ids" | grep -c .) container(s)…"
      _run sh -c 'printf "%s\n" "$1" | xargs -r docker rm -f' _ "$_ids" || true
      sleep 1
    done
    _ids="$( docker ps -aq 2>/dev/null || true )"
    if [ -n "$_ids" ]; then
      warn "$(printf '%s\n' "$_ids" | grep -c .) container(s) could not be removed."
    else
      log "all containers removed."
    fi
  else
    log "docker not installed — nothing to remove."
  fi

  step "Removing Docker volumes and networks"
  if command -v docker >/dev/null 2>&1; then
    local _q _vols
    for _q in 1 2; do
      _vols="$( docker volume ls -q 2>/dev/null || true )"
      [ -z "$_vols" ] && break
      log "removing $(printf '%s\n' "$_vols" | grep -c .) volume(s)…"
      _run sh -c 'printf "%s\n" "$1" | xargs -r docker volume rm -f' _ "$_vols" || true
      sleep 1
    done
    _run docker network prune -f || true
    _vols="$( docker volume ls -q 2>/dev/null || true )"
    if [ -n "$_vols" ]; then
      warn "$(printf '%s\n' "$_vols" | grep -c .) volume(s) could not be removed."
    else
      log "volumes + custom networks removed."
    fi
  else
    log "docker not installed — nothing to remove."
  fi

  if [ "$KEEP_IMAGES" = "1" ]; then
    skip_step "Removing Docker images" "--keep-images (reinstall will reuse the local cache)"
  else
    step "Removing Docker images"
    if command -v docker >/dev/null 2>&1; then
      log "pruning all images + build cache — this can take a while on a full box…"
      _run docker image prune -af || warn "image prune reported errors."
      _run docker builder prune -af || true
      log "images + build cache removed."
    else
      log "docker not installed — nothing to remove."
    fi
  fi

  step "Stopping cloudflared"
  if [ -f /etc/systemd/system/cloudflared.service ] || [ -d /etc/cloudflared ] || command -v cloudflared >/dev/null 2>&1; then
    systemctl disable --now cloudflared >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/cloudflared.service
    systemctl daemon-reload >/dev/null 2>&1 || true
    dpkg -r cloudflared >/dev/null 2>&1 || true
    # /etc/cloudflared (the tunnel UUID + credentials) is kept until the
    # Cloudflare cleanup below SUCCEEDS — it is the only proof of which tunnel
    # is ours; deleting it first would strand the tunnel if the API call fails.
    log "service stopped + package removed; /etc/cloudflared kept until the API cleanup succeeds."
  else
    log "cloudflared not present."
  fi

  step "Cloudflare cleanup (tunnel + DNS)"
  if [ -n "$CLOUDFLARE_API_TOKEN" ] && [ -n "$CLOUDFLARE_ACCOUNT_ID" ]; then
    log "deleting the Cloudflare tunnel + its DNS records via the API…"
    if CF_TOKEN="$CLOUDFLARE_API_TOKEN" CF_ACCOUNT="$CLOUDFLARE_ACCOUNT_ID" \
       CF_DOMAIN="$DOMAIN" CF_TUNNEL_NAME="$CLOUDFLARE_TUNNEL_NAME" CF_UUID="$TUNNEL_UUID" \
       python3 - <<'PYCF'
import json, os, urllib.error, urllib.parse, urllib.request

TOKEN, ACCOUNT = os.environ["CF_TOKEN"], os.environ["CF_ACCOUNT"]
DOMAIN = os.environ.get("CF_DOMAIN", "")
NAME = os.environ.get("CF_TUNNEL_NAME", "")
UUID = os.environ.get("CF_UUID", "")
API = "https://api.cloudflare.com/client/v4"

def call(method, path):
    req = urllib.request.Request(API + path, method=method,
                                 headers={"Authorization": f"Bearer {TOKEN}"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.load(resp)
    if not body.get("success", False):
        raise RuntimeError(f"{method} {path}: {body.get('errors')}")
    return body

owned = bool(UUID)  # a local credentials/config file proves the tunnel is ours
if not UUID and NAME:
    q = urllib.parse.quote(NAME)
    for t in call("GET", f"/accounts/{ACCOUNT}/cfd_tunnel?is_deleted=false&name={q}").get("result") or []:
        if t.get("name") == NAME:
            UUID = t["id"]
if not UUID:
    print("  · no tunnel to clean up (no local config and no name match).")
    raise SystemExit(0)

if not owned:
    # Resolved by NAME only — this could be a tunnel another box is serving
    # (e.g. the production deployment on a shared account). Refuse if it has
    # active connectors; deleting it would take that deployment down.
    conns = call("GET", f"/accounts/{ACCOUNT}/cfd_tunnel/{UUID}/connections").get("result") or []
    if conns:
        print(f"  · tunnel '{NAME}' ({UUID}) has {len(conns)} ACTIVE connector(s) and no local")
        print("    credentials on this host — it is NOT this box's tunnel. Refusing to delete it.")
        raise SystemExit(0)

target = f"{UUID}.cfargotunnel.com"
# Delete only DNS records that point AT OUR tunnel — never anything else.
# Walk parent labels so a sub-domain deploy still finds its Cloudflare zone.
zid = None
if DOMAIN:
    labels = DOMAIN.split(".")
    for i in range(len(labels) - 1):
        cand = ".".join(labels[i:])
        zones = call("GET", f"/zones?name={urllib.parse.quote(cand)}").get("result") or []
        if zones:
            zid = zones[0]["id"]
            break
if zid:
    removed = 0
    page = 1
    while True:
        body = call("GET", f"/zones/{zid}/dns_records?type=CNAME&content={urllib.parse.quote(target)}&per_page=100&page={page}")
        recs = body.get("result") or []
        for r in recs:
            call("DELETE", f"/zones/{zid}/dns_records/{r['id']}")
            print(f"  · deleted DNS record {r['name']} -> {target}")
            removed += 1
        info = body.get("result_info") or {}
        if page >= int(info.get("total_pages") or 1):
            break
        page += 1
    if not removed:
        print("  · no DNS records pointed at this tunnel.")
else:
    print(f"  · no Cloudflare zone found for '{DOMAIN or '<none>'}' with this token; skipping DNS cleanup.")

try:
    call("DELETE", f"/accounts/{ACCOUNT}/cfd_tunnel/{UUID}?cascade=true")
    print(f"  · deleted tunnel {NAME or ''} ({UUID}).")
except urllib.error.HTTPError as exc:
    if exc.code == 404:
        print(f"  · tunnel {UUID} already gone.")
    else:
        raise
PYCF
    then
      rm -rf /etc/cloudflared
      log "/etc/cloudflared removed."
    else
      warn "Cloudflare cleanup failed; /etc/cloudflared KEPT so a re-run can retry (or remove the tunnel manually)."
    fi
  else
    log "no Cloudflare credentials (env/answers) — skipping tunnel/DNS cleanup; /etc/cloudflared kept."
  fi

  step "Removing Dokploy files and clones"
  rm -rf /etc/dokploy
  log "/etc/dokploy removed."
  # The Agentic clone lives next to whichever repo dir install used; check the
  # located repo's parent AND the INSTALL_DIR parent (curl|bash installs).
  local d
  for d in \
    "${U_REPO_DIR:+$(dirname "$U_REPO_DIR")/cp-agentic-mcp-playground}" \
    "$(dirname "$INSTALL_DIR")/cp-agentic-mcp-playground"; do
    if [ -n "$d" ] && [ -f "$d/docker-compose.yml" ] && [ -d "$d/.git" ]; then
      rm -rf "$d" && log "removed $d"
    fi
  done
  if [ -n "$U_REPO_DIR" ]; then
    rm -f "$U_REPO_DIR/automation/dev_hub_compose.rendered.yml"
    # Rendered (non-.example) env files hold live credentials — always remove.
    find "$U_REPO_DIR/automation/envs" -maxdepth 1 -name '.env_*' ! -name '*.example' -delete 2>/dev/null || true
    log "rendered env files + dev-hub compose removed from $U_REPO_DIR."
  fi
  if [ -f /root/.ssh/authorized_keys ]; then
    sed -i '/ dokploy-ai@/d' /root/.ssh/authorized_keys 2>/dev/null || true
    log "removed the loopback authorized_keys entry (the keypair itself is kept)."
  fi

  step "Optional purges + final report"
  if [ "$PURGE_SECRETS" = "1" ]; then
    rm -f "$STORE"
    rmdir "$(dirname "$STORE")" 2>/dev/null || true
    log "secrets store purged ($STORE)."
  else
    log "secrets store kept: $STORE (a reinstall reuses the same passwords; --purge-secrets removes it)."
  fi
  if [ "$REMOVE_DOCKER" = "1" ]; then
    apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras >/dev/null 2>&1 \
      || warn "docker purge reported errors."
    rm -rf /var/lib/docker /var/lib/containerd
    log "Docker engine purged."
  else
    log "Docker engine kept (--remove-docker purges it)."
  fi
  log "host hardening (ufw/fail2ban/sshd/unattended-upgrades) intentionally kept."
  [ -n "$U_REPO_DIR" ] && log "this repo checkout kept: $U_REPO_DIR (delete it yourself if unwanted)."

  print_step_table
  printf '\n\033[1;32mUninstall complete.\033[0m Reinstall any time with:\n'
  printf '  sudo ./install.sh --domain %s --ingress tunnel --answers <answers.env>\n\n' "${DOMAIN:-<domain>}"
}

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "run as root (use sudo)."
command -v apt-get >/dev/null 2>&1 || die "this installer targets Debian/Ubuntu (apt-get not found)."

if [ "$UNINSTALL" = "1" ]; then
  run_uninstall
  exit 0
fi

# Resolve the domain early when the answers file sits in the caller's cwd, so
# the banner shows it (the authoritative resolution below still runs post-cd).
[ -n "$DOMAIN" ] || DOMAIN="$(answers_value DOMAIN)"
ui_begin "INSTALL · $INGRESS_MODE" "INSTALL — ingress: $INGRESS_MODE"
step "Preflight checks"

# Locate the repo. When piped via curl|bash there is no local checkout, so clone.
if [ -f "automation/dokploy_automate.py" ]; then
  REPO_DIR="$(pwd)"
elif [ -f "$(dirname "$0")/automation/dokploy_automate.py" ]; then
  REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
else
  log "Cloning $REPO_URL -> $INSTALL_DIR"
  if [ -d "$INSTALL_DIR/.git" ]; then
    git -C "$INSTALL_DIR" pull --ff-only || warn "could not fast-forward existing clone; using as-is."
  else
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y git >/dev/null 2>&1 || die "failed to install git."
    git clone --depth 1 "$REPO_URL" "$INSTALL_DIR"
  fi
  REPO_DIR="$INSTALL_DIR"
fi
cd "$REPO_DIR"
log "Working directory: $REPO_DIR"

# Resolve the domain: flag > env > DOMAIN in answers.env.
if [ -z "$DOMAIN" ] && [ -f "$ANSWERS" ]; then
  DOMAIN="$(awk -F= '/^DOMAIN=/{print $2; exit}' "$ANSWERS" | tr -d '[:space:]')"
fi
[ -n "$DOMAIN" ] || die "no domain. Pass --domain <domain>, set ROOT_DOMAIN, or put DOMAIN= in $ANSWERS."
export ROOT_DOMAIN="$DOMAIN"
[ -n "$ADMIN_EMAIL" ] || ADMIN_EMAIL="admin@${DOMAIN}"

# Validate the ingress mode. Anything but the two known values is a hard error.
case "$INGRESS_MODE" in
  letsencrypt|tunnel) ;;
  *) die "invalid --ingress '$INGRESS_MODE' (expected 'letsencrypt' or 'tunnel')." ;;
esac
log "Ingress mode: $INGRESS_MODE"

# In tunnel mode, resolve the Cloudflare inputs (flag/env > answers file) and
# fail fast if the API token or account id are missing.
if [ "$INGRESS_MODE" = "tunnel" ]; then
  [ -n "$CLOUDFLARE_API_TOKEN" ]  || CLOUDFLARE_API_TOKEN="$(answers_value CLOUDFLARE_API_TOKEN)"
  [ -n "$CLOUDFLARE_ACCOUNT_ID" ] || CLOUDFLARE_ACCOUNT_ID="$(answers_value CLOUDFLARE_ACCOUNT_ID)"
  [ -n "$CLOUDFLARE_TUNNEL_NAME" ] || CLOUDFLARE_TUNNEL_NAME="$(answers_value CLOUDFLARE_TUNNEL_NAME)"
  [ -n "$CLOUDFLARE_TUNNEL_NAME" ] || CLOUDFLARE_TUNNEL_NAME="devhub"
  # Opt-in to deleting+recreating a same-name tunnel that still has active
  # connectors (setup_tunnel.py refuses otherwise, to protect a live tunnel on a
  # shared Cloudflare account). Threaded to setup_tunnel.py's --recreate-tunnel.
  [ -n "$CLOUDFLARE_RECREATE_TUNNEL" ] || CLOUDFLARE_RECREATE_TUNNEL="$(answers_value CLOUDFLARE_RECREATE_TUNNEL)"
  [ -n "$DOKPLOY_GATE_USER" ]     || DOKPLOY_GATE_USER="$(answers_value DOKPLOY_GATE_USER)"
  [ -n "$DOKPLOY_GATE_PASSWORD" ] || DOKPLOY_GATE_PASSWORD="$(answers_value DOKPLOY_GATE_PASSWORD)"
  [ -n "$CLOUDFLARE_API_TOKEN" ] || die "tunnel mode needs CLOUDFLARE_API_TOKEN (env or answers.env). Scopes: Account>Cloudflare Tunnel>Edit, Zone>DNS>Edit, Zone>Zone>Read."
  [ -n "$CLOUDFLARE_ACCOUNT_ID" ] || die "tunnel mode needs CLOUDFLARE_ACCOUNT_ID (env or answers.env)."
fi

# ---------------------------------------------------------------------------
# 2. Base packages (Ubuntu packages for python deps — avoids PyPI/pip policy)
# ---------------------------------------------------------------------------
step "Base packages"
export DEBIAN_FRONTEND=noninteractive
_stream apt-get update -y
_stream apt-get install -y \
  python3 python3-requests python3-paramiko python3-yaml \
  git curl ca-certificates ufw fail2ban unattended-upgrades

# Detect the public IP DNS should point at, and the default-route interface.
detect_public_ip() {
  local ip=""
  ip="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  [ -z "$ip" ] && ip="$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)"
  [ -z "$ip" ] && ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  printf '%s' "$ip"
}
detect_wan_iface() {
  ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}
PUBLIC_IP="$(detect_public_ip)"
WAN_IFACE="$(detect_wan_iface)"
[ -n "$PUBLIC_IP" ] || warn "could not determine public IP; DNS pre-check will be skipped."
if [ -z "$WAN_IFACE" ]; then
  if [ "$SKIP_HARDEN" = "1" ]; then
    WAN_IFACE="eth0"
  else
    die "could not detect the WAN interface (ip route show default). The DOCKER-USER firewall rule would silently protect nothing. Set WAN_IFACE=<iface> and re-run, or use --skip-harden."
  fi
fi
export DOKPLOY_HOST_IP="$PUBLIC_IP" WAN_IFACE
log "Public IP: ${PUBLIC_IP:-unknown}   WAN interface: $WAN_IFACE"

# ---------------------------------------------------------------------------
# 3. Firewall FIRST (INC-2026-03-24: a default-deny firewall alone would have
#    prevented the exposed-PostgreSQL compromise even with weak credentials).
# ---------------------------------------------------------------------------
if [ "$SKIP_HARDEN" = "1" ]; then
  skip_step "Base firewall" "--skip-harden"
else
  step "Base firewall"
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 22/tcp
  if [ "$INGRESS_MODE" = "tunnel" ]; then
    # Tunnel mode: cloudflared dials OUT to Cloudflare's edge; there is no public
    # inbound, so 80/443 stay closed. Only SSH (22) is opened.
    log "default deny; allow 22 only — the tunnel needs no public 80/443"
  else
    log "default deny; allow 22/80/443"
    ufw allow 80/tcp
    ufw allow 443/tcp
  fi
  ufw --force enable
fi

# ---------------------------------------------------------------------------
# 4. Docker + Dokploy (idempotent)
# ---------------------------------------------------------------------------
step "Docker engine"
if command -v docker >/dev/null 2>&1; then
  log "Docker already present: $(docker --version)"
else
  curl -fsSL https://get.docker.com | sh
fi

step "Dokploy platform"
if [ -f /etc/dokploy/dokploy.sh ] || docker service ls 2>/dev/null | grep -q dokploy; then
  log "Dokploy already installed."
else
  _stream sh -c 'curl -sSL https://dokploy.com/install.sh | sh'
fi

# ---------------------------------------------------------------------------
# 4b. Hub framing middleware — let apps embed in the dev-hub desktop.
#     A Traefik "hubframe" headers middleware removes X-Frame-Options and sets
#     a permissive frame-ancestors CSP, attached as a DEFAULT middleware on both
#     the web and websecure entrypoints so every routed app inherits it. Without
#     this a fresh box refuses to embed any app in the hub. Idempotent: the
#     dynamic file is rewritten each run; the entrypoint attachment is added only
#     if missing (traefik.yml is backed up once first). Leaves the forced-HTTPS
#     redirect middleware untouched.
# ---------------------------------------------------------------------------
step "Traefik hubframe middleware"
TRAEFIK_DIR="/etc/dokploy/traefik"
TRAEFIK_YML="$TRAEFIK_DIR/traefik.yml"
if [ -d "$TRAEFIK_DIR" ]; then
  mkdir -p "$TRAEFIK_DIR/dynamic"
  cat > "$TRAEFIK_DIR/dynamic/hubframe.yml" <<HUBFRAME
http:
  middlewares:
    hubframe:
      headers:
        customResponseHeaders:
          X-Frame-Options: ""
          Content-Security-Policy: "frame-ancestors 'self' https://hub.$DOMAIN"
HUBFRAME

  if [ -f "$TRAEFIK_YML" ]; then
    python3 - "$TRAEFIK_YML" <<'PY'
import sys, os, shutil, yaml

path = sys.argv[1]
with open(path) as fh:
    data = yaml.safe_load(fh) or {}

eps = data.get("entryPoints") or {}
changed = False
for name in ("web", "websecure"):
    ep = eps.get(name)
    if not isinstance(ep, dict):
        continue
    http = ep.setdefault("http", {})
    mws = http.get("middlewares")
    if not isinstance(mws, list):
        mws = [] if mws in (None, "") else [mws]
    if "hubframe@file" not in mws:
        mws.append("hubframe@file")
        http["middlewares"] = mws
        changed = True

if changed:
    bak = path + ".bak"
    if not os.path.exists(bak):
        shutil.copy2(path, bak)
    with open(path, "w") as fh:
        yaml.safe_dump(data, fh, default_flow_style=False, sort_keys=False)
    print("attached hubframe@file to the web/websecure entrypoints")
else:
    print("hubframe@file already attached; no change")
PY
    docker restart dokploy-traefik >/dev/null 2>&1 \
      || warn "could not restart dokploy-traefik; hubframe applies on its next restart."
  else
    warn "traefik.yml not found at $TRAEFIK_YML; wrote the dynamic middleware but could not attach it to the entrypoints."
  fi
else
  warn "Dokploy Traefik config dir ($TRAEFIK_DIR) not found; skipping hubframe middleware install."
fi

# ---------------------------------------------------------------------------
# 5. Full hardening (now that Docker exists): DOCKER-USER chain, fail2ban,
#    unattended-upgrades, sshd, and a baseline user/key audit.
# ---------------------------------------------------------------------------
if [ "$SKIP_HARDEN" != "1" ]; then
  step "Host hardening"
  log "Applying DOCKER-USER firewall chain (force all app ports through Traefik)"
  # INC-2026-03-31: containers published ports on 0.0.0.0, bypassing Traefik.
  # This chain drops direct external access to every Docker-published port;
  # only traffic on 80/443 via $WAN_IFACE (and internal/loopback) is allowed.
  cat > /etc/ufw/after.rules <<AFTEREOF
#
# rules.input-after
#
*filter
:ufw-after-input - [0:0]
:ufw-after-output - [0:0]
:ufw-after-forward - [0:0]

-A ufw-after-input -p udp --dport 137 -j ufw-skip-to-policy-input
-A ufw-after-input -p udp --dport 138 -j ufw-skip-to-policy-input
-A ufw-after-input -p tcp --dport 139 -j ufw-skip-to-policy-input
-A ufw-after-input -p tcp --dport 445 -j ufw-skip-to-policy-input
-A ufw-after-input -p udp --dport 67 -j ufw-skip-to-policy-input
-A ufw-after-input -p udp --dport 68 -j ufw-skip-to-policy-input
-A ufw-after-input -m addrtype --dst-type BROADCAST -j ufw-skip-to-policy-input

:DOCKER-USER - [0:0]
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -i $WAN_IFACE -p tcp --dport 80 -j RETURN
-A DOCKER-USER -i $WAN_IFACE -p tcp --dport 443 -j RETURN
-A DOCKER-USER -i $WAN_IFACE -j DROP

COMMIT
AFTEREOF
  ufw reload || warn "ufw reload failed; check /etc/ufw/after.rules."

  log "Configuring fail2ban (sshd jail)"
  cat > /etc/fail2ban/jail.local <<'JAILEOF'
[sshd]
enabled  = true
port     = ssh
filter   = sshd
backend  = systemd
maxretry = 5
bantime  = 3600
findtime = 600
JAILEOF
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban || warn "could not restart fail2ban."

  log "Enabling unattended security upgrades"
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'AUTOEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
AUTOEOF
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

  log "Hardening sshd (root: key-only; pubkey auth on)"
  sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
  grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo 'PermitRootLogin prohibit-password' >> /etc/ssh/sshd_config
  sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
  grep -q '^PubkeyAuthentication' /etc/ssh/sshd_config || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

  log "Recording baseline user/authorized_keys audit"
  mkdir -p /etc/dokploy-ai
  {
    echo "# Baseline captured by install.sh"
    echo "## /etc/passwd (login shells)"
    awk -F: '$7 ~ /(bash|sh|zsh)$/ {print $1":"$7}' /etc/passwd
    echo "## authorized_keys"
    for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
      [ -f "$f" ] && { echo "### $f"; cat "$f"; }
    done
  } > /etc/dokploy-ai/audit-baseline.txt 2>/dev/null || true
  chmod 600 /etc/dokploy-ai/audit-baseline.txt 2>/dev/null || true
else
  skip_step "Host hardening" "--skip-harden"
fi

# ---------------------------------------------------------------------------
# 6. Self SSH key — Dokploy manages the box over loopback (127.0.0.1), so no
#    hairpin-NAT dependency and nothing is exposed to author the deployment.
# ---------------------------------------------------------------------------
step "Loopback SSH key"
mkdir -p /root/.ssh && chmod 700 /root/.ssh
if [ ! -f /root/.ssh/id_rsa ]; then
  ssh-keygen -t rsa -b 4096 -N '' -f /root/.ssh/id_rsa -C "dokploy-ai@$DOMAIN"
fi
PUBKEY="$(cat /root/.ssh/id_rsa.pub)"
touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
grep -qF "$PUBKEY" /root/.ssh/authorized_keys || echo "$PUBKEY" >> /root/.ssh/authorized_keys

# ---------------------------------------------------------------------------
# 7. Secrets: generate/persist and render every .env + the dev-hub compose.
# ---------------------------------------------------------------------------
step "Secrets & env rendering"
python3 automation/bootstrap_secrets.py \
  --domain "$DOMAIN" \
  --answers "$ANSWERS" \
  --store "$STORE" \
  --envs-dir automation/envs \
  --dev-hub-compose automation/dev_hub_compose.yml

DEV_HUB_RENDERED="$REPO_DIR/automation/dev_hub_compose.rendered.yml"
[ -f "$DEV_HUB_RENDERED" ] && export DEV_HUB_COMPOSE_PATH="$DEV_HUB_RENDERED"

# Dokploy admin password: flag/env > persisted store > freshly generated.
# Whichever it resolves to, upsert it into the store so re-runs are idempotent.
mkdir -p "$(dirname "$STORE")"; touch "$STORE"; chmod 600 "$STORE"
if [ -z "$ADMIN_PASSWORD" ]; then
  ADMIN_PASSWORD="$(awk -F= '/^DOKPLOY_ADMIN_PASSWORD=/{print $2; exit}' "$STORE" 2>/dev/null || true)"
fi
if [ -z "$ADMIN_PASSWORD" ]; then
  ADMIN_PASSWORD="$(python3 -c 'import secrets,string; print("".join(secrets.choice(string.ascii_letters+string.digits) for _ in range(24)))')"
fi
grep -v -E '^DOKPLOY_ADMIN_(EMAIL|PASSWORD)=' "$STORE" > "$STORE.tmp" 2>/dev/null || true
mv "$STORE.tmp" "$STORE"
printf 'DOKPLOY_ADMIN_EMAIL=%s\nDOKPLOY_ADMIN_PASSWORD=%s\n' "$ADMIN_EMAIL" "$ADMIN_PASSWORD" >> "$STORE"
chmod 600 "$STORE"

# ---------------------------------------------------------------------------
# 7b. Cloudflare Tunnel ingress (tunnel mode only). Provisions cloudflared, the
#     named tunnel, the proxied wildcard CNAME, and the systemd service. Then
#     neutralizes Traefik's forced-HTTPS redirect and puts the Dokploy dashboard
#     behind a Traefik basic-auth gate at dokploy.$DOMAIN. Runs after secrets so
#     the gate can default to the resolved Dokploy admin password.
# ---------------------------------------------------------------------------
if [ "$INGRESS_MODE" != "tunnel" ]; then
  skip_step "Cloudflare Tunnel ingress" "letsencrypt mode (public inbound + HTTP-01)"
else
  step "Cloudflare Tunnel ingress"
  RECREATE_FLAG=""
  case "$(printf '%s' "$CLOUDFLARE_RECREATE_TUNNEL" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) RECREATE_FLAG="--recreate-tunnel" ;;
  esac
  python3 automation/setup_tunnel.py \
    --domain "$DOMAIN" \
    --account-id "$CLOUDFLARE_ACCOUNT_ID" \
    --api-token "$CLOUDFLARE_API_TOKEN" \
    --tunnel-name "$CLOUDFLARE_TUNNEL_NAME" \
    $RECREATE_FLAG \
    || die "Cloudflare Tunnel setup failed (see the error above)."

  if [ -d "$TRAEFIK_DIR" ]; then
    mkdir -p "$TRAEFIK_DIR/dynamic"

    # The tunnel forwards PLAIN HTTP to Traefik on loopback :80 (edge+tunnel are
    # already encrypted). Traefik's default forced-HTTPS redirect would bounce
    # every :80 request to :443 and loop the apps. A shadow file canNOT override
    # it (the file provider SKIPS duplicate middleware names; the first file wins
    # lexically), so we rewrite Dokploy's own middlewares.yml in place: the
    # redirect-to-https middleware becomes a benign no-op headers middleware.
    # One-time backup to middlewares.yml.orig; an already-neutralized file is
    # detected and left alone, so re-runs are idempotent. Dokploy writes
    # middlewares.yml on first boot, so wait briefly if it is not there yet.
    log "Neutralizing Traefik's forced-HTTPS redirect (the tunnel serves plain :80)"
    rm -f "$TRAEFIK_DIR/dynamic/tunnel-ingress.yml"
    MIDDLEWARES_YML="$TRAEFIK_DIR/dynamic/middlewares.yml"
    for _ in $(seq 1 12); do
      [ -f "$MIDDLEWARES_YML" ] && break
      sleep 5
    done
    if [ -f "$MIDDLEWARES_YML" ]; then
      python3 - "$MIDDLEWARES_YML" <<'PY'
import sys, os, shutil, yaml

path = sys.argv[1]
with open(path) as fh:
    data = yaml.safe_load(fh) or {}

http = data.get("http")
if not isinstance(http, dict):
    http = {}
    data["http"] = http
mws = http.get("middlewares")
if not isinstance(mws, dict):
    mws = {}
    http["middlewares"] = mws

noop = {"headers": {"customRequestHeaders": {"X-Tunnel-Ingress": "cloudflared"}}}
if mws.get("redirect-to-https") == noop:
    print("redirect-to-https already neutralized; no change")
else:
    orig = path + ".orig"
    if not os.path.exists(orig):
        shutil.copy2(path, orig)
    mws["redirect-to-https"] = noop
    with open(path, "w") as fh:
        yaml.safe_dump(data, fh, default_flow_style=False, sort_keys=False)
    print("neutralized redirect-to-https (original kept at %s)" % orig)
PY
    else
      warn "middlewares.yml not found under $TRAEFIK_DIR/dynamic after waiting 60s; the forced-HTTPS redirect will loop the apps. Re-run this installer once Dokploy is up."
    fi

    # Dokploy dashboard behind a Traefik basic-auth gate at dokploy.$DOMAIN.
    # NOTE: no tls: key on the router — it must match the tunnel's plain :80 hop
    # (adding tls made it websecure-only and returned 404).
    GATE_USER="${DOKPLOY_GATE_USER:-admin}"
    GATE_PASS="${DOKPLOY_GATE_PASSWORD:-$ADMIN_PASSWORD}"
    [ -n "$GATE_PASS" ] || die "no password available for the Dokploy basic-auth gate."
    GATE_HASH="$(openssl passwd -apr1 "$GATE_PASS")"
    log "Writing Dokploy basic-auth gate (dokploy.$DOMAIN, user '$GATE_USER')"
    cat > "$TRAEFIK_DIR/dynamic/dokploy-auth.yml" <<AUTHGATE
http:
  routers:
    dokploy-secure:
      rule: "Host(\`dokploy.$DOMAIN\`)"
      entryPoints: [web, websecure]
      service: dokploy-dashboard
      middlewares: [dokploy-gate]
  services:
    dokploy-dashboard:
      loadBalancer:
        servers:
          - url: "http://dokploy:3000"
  middlewares:
    dokploy-gate:
      basicAuth:
        users:
          - "$GATE_USER:$GATE_HASH"
AUTHGATE

    docker restart dokploy-traefik >/dev/null 2>&1 \
      || warn "could not restart dokploy-traefik; redirect neutralization + auth gate apply on its next restart."
  else
    warn "Traefik config dir ($TRAEFIK_DIR) not found; could not neutralize the HTTPS redirect / write the auth gate."
  fi
fi   # ingress mode

# ---------------------------------------------------------------------------
# 8. Fetch the Agentic playground compose so that app can deploy.
# ---------------------------------------------------------------------------
step "Agentic playground fetch"
AGENTIC_DIR="$(dirname "$REPO_DIR")/cp-agentic-mcp-playground"
if [ ! -f "$AGENTIC_DIR/docker-compose.yml" ]; then
  log "Cloning Agentic playground -> $AGENTIC_DIR"
  git clone --depth 1 "$AGENTIC_REPO_URL" "$AGENTIC_DIR" || warn "could not clone Agentic playground; that app will be skipped."
fi
[ -f "$AGENTIC_DIR/docker-compose.yml" ] && export AGENTIC_COMPOSE_PATH="$AGENTIC_DIR/docker-compose.yml"

# ---------------------------------------------------------------------------
# 9. DNS pre-check (fail fast so Let's Encrypt doesn't silently fail)
# ---------------------------------------------------------------------------
if [ "$INGRESS_MODE" = "tunnel" ]; then
  skip_step "DNS pre-check" "tunnel ingress needs no public A record (proxied wildcard CNAME)"
elif [ "$SKIP_DNS_CHECK" = "1" ]; then
  skip_step "DNS pre-check" "--skip-dns-check"
elif [ -z "$PUBLIC_IP" ]; then
  step "DNS pre-check"
  warn "public IP could not be determined (not a DNS problem). Verify the wildcard A record ('*' -> this host) manually."
else
  step "DNS pre-check"
  log "Checking DNS resolves to $PUBLIC_IP"
  DNS_ARGS=(--domain "$DOMAIN" --ip "$PUBLIC_IP" --config automation/dokploy_config.json)
  [ "$DNS_WARN_ONLY" = "1" ] && DNS_ARGS+=(--warn-only)
  python3 automation/dns_precheck.py "${DNS_ARGS[@]}" || \
    die "DNS not ready. Add the wildcard A record shown above, or re-run with --skip-dns-check."
fi

# ---------------------------------------------------------------------------
# 10. Deploy — Dokploy registers the admin, authenticates, and builds every app
# ---------------------------------------------------------------------------
step "Stack deploy via Dokploy"
_stream python3 automation/dokploy_automate.py \
  --url http://localhost:3000 \
  --ip 127.0.0.1 \
  --domain "$DOMAIN" \
  --email "$ADMIN_EMAIL" \
  --password "$ADMIN_PASSWORD" \
  --ssh-user root \
  --ssh-private /root/.ssh/id_rsa \
  --ssh-public /root/.ssh/id_rsa.pub \
  --config automation/dokploy_config.json \
  --local-server \
  --skip-harden \
  $CLEAN

# ---------------------------------------------------------------------------
# 11. Verify + summary
# ---------------------------------------------------------------------------
step "Waiting for apps to build & come up"
log "Dokploy builds the apps asynchronously — polling each until its containers"
log "are up (or it errors). This is the long part; the box does the work."
_stream python3 automation/utils/verify_deployment.py \
  --url http://localhost:3000 --email "$ADMIN_EMAIL" --password "$ADMIN_PASSWORD" \
  --timeout "${VERIFY_TIMEOUT:-2700}" --interval "${VERIFY_INTERVAL:-5}" || \
  warn "one or more apps failed to come up or timed out — see the app table above and the Dokploy dashboard."

if [ "$INGRESS_MODE" = "tunnel" ]; then
  DOKPLOY_ACCESS="Dokploy dashboard : https://dokploy.$DOMAIN  (behind a Traefik basic-auth gate;
                      user '${DOKPLOY_GATE_USER:-admin}', password = the Dokploy admin password below)

  Ingress           : Cloudflare Tunnel (tunnel '$CLOUDFLARE_TUNNEL_NAME'). Apps are reachable at
                      https://<app>.$DOMAIN via the tunnel; no public inbound needed."
else
  DOKPLOY_ACCESS="Dokploy dashboard : port 3000 is firewalled off (by design). Reach it via an
                      SSH tunnel from your laptop, then open http://localhost:3000 :
                        ssh -L 3000:localhost:3000 root@$PUBLIC_IP"
fi

print_step_table

cat <<SUMMARY

============================================================
 Provisioning complete.
============================================================
  Domain            : $DOMAIN
  Dev hub           : https://hub.$DOMAIN
  Admin email       : $ADMIN_EMAIL
  Secrets store     : $STORE  (mode 0600 — Dokploy admin password inside)

  $DOKPLOY_ACCESS

  Show the admin password:  sudo awk -F= '/DOKPLOY_ADMIN_PASSWORD/{print \$2}' $STORE

  Any bring-your-own API keys you did not supply were reported above; add
  them to answers.env and re-run this script to enable those integrations.
============================================================
SUMMARY
