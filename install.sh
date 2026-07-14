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
#                     [--keep-images] [--keep-models] [--purge-secrets] [--remove-docker]
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
SKIP_DOCKER="${SKIP_DOCKER:-0}"   # --skip-docker: don't install/reconfigure Docker (assume it's managed)
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
KEEP_MODELS=0
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
STEP_CLOSED=0
STEP_TITLE=""
STEP_T0="$RUN_T0"
STEP_STATUS="done"
STEP_LINES=()
WARNINGS=()
# Live app-deployment board — populated from `verify_deployment.py --board`
# snapshot lines by _stream_apps during the long build phase. Associative, so a
# `declare -A` is required.
declare -A APP_STATE=()
declare -A APP_DETAIL=()
APP_ORDER=()
APPS_PHASE=0
APPS_UP=0; APPS_BUILDING=0; APPS_QUEUED=0; APPS_DEGRADED=0; APPS_FAILED=0; APPS_TOTAL=0
# When this app reaches "up" the board flips to a "hub is live" banner (the hub
# is deployed in the fast first wave, so this fires early).
HUB_APP_NAME="Dev Hub"
HUB_URL=""
HUB_LIVE=0
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
UI_CW=76           # content width (set responsively by _ui_size)
UI_MARGIN="  "     # left centering margin (set responsively by _ui_size)
_STTY_SAVE=""      # terminal state captured at _ui_init, restored verbatim at _ui_reset
UI_BIG=0           # --big / BIG=1: DEC double-width (2x) text; set responsively by _ui_size
UI_TTY="${UI_TTY:-/dev/tty}"  # where frames are painted (overridable for render tests)
_FD_SAVED=0        # 1 while the real stdout/stderr are stashed in UI_OUT_FD/UI_ERR_FD
# The live-output box collapses/expands with the `d` key. State lives in a flag
# FILE (not a variable) because the render loops run in different processes
# per phase (_stream's reader is a pipeline subshell; _stream_apps reads in the
# main shell) — a file is the only state they all see. Removed on init/reset.
UI_BOXMIN="${UI_BOXMIN:-/tmp/.dokploy-ai-boxmin}"

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
  [ "${STEP_CLOSED:-0}" = "$STEP_NO" ] && return 0   # idempotent — never double-close a step
  STEP_CLOSED=$STEP_NO
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
# Build the contained live-output panel into _BOX_OUT: a bordered, fixed-height
# box that tail-follows the activity ring INSIDE its frame. Heavy step output
# (docker pulls, apt, dokploy) churns within the box; the layout around it
# never moves and the terminal never scrolls. Title = the running step; the
# bottom border points at the full log for the complete, uncollapsed output.
_BOX_OUT=""
# Toggle-key poll: a zero-ish-timeout single-key read on the tty. Callable from
# any process in the FOREGROUND group (the _stream reader subshell and the
# _stream_apps main-shell loop both are — a *background* ticker is not, so
# _run's ticker doesn't poll). `d` flips the collapse flag file.
_box_poll() {
  [ -r /dev/tty ] || return 0
  local _k=""
  # SIGTTIN guard: a tty READ from outside the foreground group is stopped by
  # default (sudo's own pty makes that our normal case) — ignored, the read
  # just returns empty/EIO instead of freezing the reader loop.
  trap '' TTIN TTOU
  IFS= read -rsn1 -t 0.02 _k </dev/tty 2>/dev/null || { trap - TTIN TTOU; return 0; }
  trap - TTIN TTOU
  [ "$_k" = "d" ] || return 0
  if [ -f "$UI_BOXMIN" ]; then rm -f "$UI_BOXMIN" 2>/dev/null || true
  else : >"$UI_BOXMIN" 2>/dev/null || true; fi
  return 0
}
_set_box() {
  local E=$'\033' title="$1" inner i line pad t
  inner=$(( UI_CW - 4 ))                       # room inside "│ … │"
  if [ -f "$UI_BOXMIN" ]; then
    # Collapsed: one quiet line; the freed rows stay blank (frame is
    # absolute-addressed, so no relayout is needed).
    t="▸ ${title} · output hidden — press d to expand "
    [ "${#t}" -gt "$((UI_CW-2))" ] && t="${t:0:$((UI_CW-3))}… "
    _set_rule $(( UI_CW - 1 - ${#t} ))
    _BOX_OUT="${E}[K${UI_MARGIN}${E}[38;5;244m${t}${E}[38;5;24m${_RULE_OUT}${E}[0m"$'\n'
    return 0
  fi
  t=" ${title} · live output "
  [ "${#t}" -gt "$((inner-4))" ] && t="${t:0:$((inner-4))}… "
  _set_rule $(( UI_CW - 3 - ${#t} ))
  _BOX_OUT="${E}[K${UI_MARGIN}${E}[38;5;24m╭─${E}[38;5;75m${t}${E}[38;5;24m${_RULE_OUT}╮${E}[0m"$'\n'
  for ((i=0;i<ACT_MAX;i++)); do
    line="${ACT[$i]:-}"; line="${line:0:$inner}"
    printf -v pad '%-*s' "$inner" "$line"
    _BOX_OUT+="${E}[K${UI_MARGIN}${E}[38;5;24m│${E}[0m ${E}[38;5;250m${pad}${E}[0m ${E}[38;5;24m│${E}[0m"$'\n'
  done
  t=" full log → ${RUN_LOG} · d hides "
  [ "${#t}" -gt "$((inner-2))" ] && t=" log ▸ · d hides "
  _set_rule $(( UI_CW - 3 - ${#t} ))
  _BOX_OUT+="${E}[K${UI_MARGIN}${E}[38;5;24m╰─${E}[38;5;244m${t}${E}[38;5;24m${_RULE_OUT}╯${E}[0m"$'\n'
}
_os_short() { ( . /etc/os-release 2>/dev/null || true; printf '%s %s' "${NAME:-Linux}" "${VERSION_ID:-}" ); }
_SPINCH=""
_spin() { SPIN_I=$(( (SPIN_I+1) % ${#SPIN_FRAMES[@]} )); _SPINCH="${SPIN_FRAMES[$SPIN_I]}"; }
_set_elapsed() { local s=$(( ${EPOCHSECONDS:-$(date +%s)} - ${2:-$RUN_T0} )); printf -v "$1" '%02d:%02d' $((s/60)) $((s%60)); }
_BAR_KEY=""; _BAR_OUT=""
_set_bar() {
  # $4 (optional): a single xterm-256 color for a FLAT fill. Used by the dual
  # overall/apps bars — two rainbow gradients side by side read as noise, while
  # two distinct solid colors stay calm and instantly tell the bars apart. The
  # gradient remains the (single) setup-phase bar's look.
  local done="$1" total="$2" width="$3" solid="${4:-}" key="$1|$2|$3|${4:-}"
  [ "$key" = "$_BAR_KEY" ] && return 0
  local E=$'\033' fill i ci out
  # Gradient in the BLUE family (deep azure → cyan) — the dashboard's accent
  # theme; the old purple→pink ramp read as loud.
  local ramp=(25 26 27 32 33 38 39 45) n=8
  out="${E}[38;5;239m▕"
  if [ "$total" -gt 0 ]; then fill=$(( done*width/total )); else fill=0; fi
  for ((i=0;i<width;i++)); do
    if [ "$i" -lt "$fill" ]; then
      if [ -n "$solid" ]; then ci="$solid"; else ci=$(( i*n/width )); [ "$ci" -ge "$n" ] && ci=$((n-1)); ci="${ramp[$ci]}"; fi
      out="${out}${E}[38;5;${ci}m█"
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
  # The live-output box gets every row the frame doesn't need — PHASE-AWARE:
  # in the app-deploy phase the 14-step checklist is collapsed to one line, so
  # budgeting for it would waste ~STEP_TOTAL rows exactly when the operator
  # watches the box longest. Setup: header(4) + checklist + borders(2) +
  # safety(2). Apps: header(5, dual bars) + hub(1) + divider(1) + borders(2) +
  # safety(1). Clamped so a 24-row console still fits (3 content rows).
  if [ "${APPS_PHASE:-0}" = 1 ]; then
    ACT_MAX=$(( UI_ROWS - 11 ))
  else
    ACT_MAX=$(( UI_ROWS - 4 - STEP_TOTAL - 4 ))
  fi
  [ "$ACT_MAX" -lt 3 ]  && ACT_MAX=3
  [ "$ACT_MAX" -gt 28 ] && ACT_MAX=28
  # Big mode (--big / BIG=1): render every row with DEC double-width (ESC # 6),
  # so the text is 2x wider = bigger + more legible on a large terminal. A
  # double-width glyph occupies TWO cells, so we lay everything out against half
  # the real column count. Needs >= 80 real cols (>= 40 effective) to be usable;
  # on a terminal that doesn't support ESC # 6 the escape is ignored and the
  # content simply renders single-width in the left half (readable, not broken).
  UI_BIG=0; [ "${BIG:-0}" = 1 ] && [ "$UI_COLS" -ge 80 ] && UI_BIG=1
  local eff=$UI_COLS; [ "$UI_BIG" = 1 ] && eff=$(( UI_COLS / 2 ))
  # Content width + left margin so the dashboard CENTERS and fills the terminal
  # instead of clustering in the top-left corner. Cap the content width so the bar
  # and dividers stay a sane length on ultra-wide terminals; the leftover space
  # becomes a centering margin. On an 80-col console this is a no-op (margin = 2).
  UI_CW=$(( eff - 4 )); [ "$UI_CW" -gt 132 ] && UI_CW=132; [ "$UI_CW" -lt 36 ] && UI_CW=36
  _mg=$(( (eff - UI_CW) / 2 )); [ "$_mg" -lt 2 ] && _mg=2
  printf -v UI_MARGIN '%*s' "$_mg" ''
  return 0   # a trailing `[ ] && …` that tests false would otherwise make this
             # function return non-zero and trip the ERR trap under set -e
}
# Push a raw output line into the activity ring (+ persist to the log file).
_ui_push() {
  # $2="collapse" enables the keyed in-place update (used for STEP OUTPUT only;
  # log() lines always append verbatim).
  local line="$1"
  # Progress bars redraw with \r; without a tty many tools still emit them.
  # Keep only the final overwrite segment so one logical line stays one line.
  case "$line" in *$'\r'*) line="${line##*$'\r'}" ;; esac
  printf '%s\n' "$line" >>"$RUN_LOG" 2>/dev/null || true
  if [ "${2:-}" = "collapse" ]; then
    # Keyed in-place update: docker/apt style output emits hundreds of
    # "<key>: <changing detail>" lines (layer pulls, "overall progress: …",
    # apt "Get:N …"). If a visible row already carries this <key>, OVERWRITE it
    # so each key becomes one live-updating row instead of a scrolling flood.
    # The run log above keeps every raw line — only the display collapses.
    local k="${line%%:*}" i
    if [ "$k" != "$line" ] && [ -n "$k" ]; then
      for (( i=${#ACT[@]}-1; i>=0; i-- )); do
        if [ "${ACT[$i]%%:*}" = "$k" ]; then ACT[$i]="$line"; return 0; fi
      done
    fi
  fi
  ACT+=("$line")
  while [ "${#ACT[@]}" -gt "$ACT_MAX" ]; do ACT=("${ACT[@]:1}"); done
}
# Repaint the entire frame from state. Absolute-addressed, each row cleared.
# Parse one "@APP<TAB>name<TAB>state<TAB>detail" board snapshot line (emitted by
# verify_deployment.py --board) into the live app board. Unknown/short lines are
# ignored. state ∈ up|building|degraded|failed|queued.
_apps_update() {
  local rest name state detail
  rest="${1#@APP$'\t'}"
  case "$rest" in *$'\t'*) : ;; *) return 0 ;; esac
  name="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  state="${rest%%$'\t'*}"; detail="${rest#*$'\t'}"
  [ -n "$name" ] || return 0
  [ -n "${APP_STATE[$name]+x}" ] || APP_ORDER+=("$name")
  APP_STATE["$name"]="$state"; APP_DETAIL["$name"]="$detail"
  if [ "$HUB_LIVE" != 1 ] && [ "$name" = "$HUB_APP_NAME" ] && [ "$state" = "up" ]; then
    HUB_LIVE=1; _ui_push "🌐 hub is live → ${HUB_URL:-https://hub.${DOMAIN:-}}"
  fi
  return 0
}
# Tally the board into APPS_* (fork-free; called once per render).
_apps_counts() {
  APPS_UP=0; APPS_BUILDING=0; APPS_QUEUED=0; APPS_DEGRADED=0; APPS_FAILED=0
  local n
  for n in "${APP_ORDER[@]}"; do
    case "${APP_STATE[$n]:-queued}" in
      up)       APPS_UP=$((APPS_UP+1)) ;;
      building) APPS_BUILDING=$((APPS_BUILDING+1)) ;;
      failed)   APPS_FAILED=$((APPS_FAILED+1)) ;;
      degraded) APPS_DEGRADED=$((APPS_DEGRADED+1)) ;;
      *)        APPS_QUEUED=$((APPS_QUEUED+1)) ;;
    esac
  done
  APPS_TOTAL=${#APP_ORDER[@]}
  return 0
}
_ui_render() {
  [ "$UI_RICH" = 1 ] || return 0
  local E=$'\033' pct barw brand badge mid warns i st name sec icon col line f pad namep hdr rw
  local countseg failstr avail cap shown more n stt det ic cc
  barw=$(( UI_CW - 8 )); [ "$barw" -lt 12 ] && barw=12
  brand=" ◆ ubuntu-dokploy-ai · one-command provisioner "
  badge="[ ${UI_MODE_LABEL} ]"
  mid=$(( UI_CW - ${#brand} - ${#badge} - 1 )); [ "$mid" -lt 1 ] && mid=1
  printf -v pad '%*s' "$mid" ''
  warns=""; [ "${#WARNINGS[@]}" -gt 0 ] && warns="   ${E}[38;5;214m⚠ ${#WARNINGS[@]}${E}[0m"
  _spin; _set_elapsed _EL
  # Build the WHOLE frame in one string (raw ESC bytes) and write it with ONE
  # printf — no $() subshell forks and one terminal write, so the ticker stays
  # on cadence even while a heavy step saturates the box.
  f="${E}[H"
  f+="${E}[K${UI_MARGIN}${E}[48;5;24;1;97m${brand}${pad}${E}[38;5;75m${badge} ${E}[0m"$'\n'
  if [ "$APPS_PHASE" = 1 ] && [ "${#APP_ORDER[@]}" -gt 0 ]; then
    # ---- app-deploy phase: TWO bars — overall (setup steps) stays visible on
    # top so total progress never disappears, and the phase bar underneath
    # tracks the apps actually coming up. Labels keep them unambiguous.
    _apps_counts
    countseg="${E}[38;5;120m▣ ${APPS_UP}/${APPS_TOTAL} apps${E}[0m"
    f+="${E}[K${UI_MARGIN}${E}[38;5;45m${DOMAIN:-?}${E}[38;5;240m · ${E}[38;5;250m${UI_HOST}${E}[38;5;240m · ${E}[38;5;244m${UI_OS}${E}[0m    ${E}[38;5;81m◷${E}[0m ${E}[1;97m${_EL}${E}[0m   ${countseg}${warns}"$'\n'
    # NB: two different (done,total,width) tuples per frame defeat _set_bar's
    # single-slot memo, so both bars rebuild each tick — pure string work,
    # fork-free, negligible at 1-2 fps.
    # Reserve room for the row's full chrome: label(9) + pct(≤5) + counter(≤9)
    # + separators — 18 beyond the plain bar row — so the line never exceeds
    # the content width (BIG mode doubles every cell, so overflow would wrap).
    local barw2=$(( barw - 18 )); [ "$barw2" -lt 10 ] && barw2=10
    # Flat, distinct fills (deep blue vs steel blue — dark/light of one hue) —
    # calmer than two gradients and unambiguous at a glance. Orange was
    # rejected deliberately: it's the board's degraded/warn color, so an
    # orange bar would read as a problem. Percentages/counters stay dim.
    pct=$(( STEP_TOTAL>0 ? STEP_DONE*100/STEP_TOTAL : 0 ))
    _set_bar "$STEP_DONE" "$STEP_TOTAL" "$barw2" 25
    f+="${E}[K${UI_MARGIN}${E}[38;5;244moverall ${E}[0m ${_BAR_OUT} ${E}[38;5;250m${pct}%${E}[0m ${E}[38;5;240m✓ ${STEP_DONE}/${STEP_TOTAL}${E}[0m"$'\n'
    pct=$(( APPS_TOTAL>0 ? APPS_UP*100/APPS_TOTAL : 0 ))
    _set_bar "$APPS_UP" "$APPS_TOTAL" "$barw2" 75
    f+="${E}[K${UI_MARGIN}${E}[38;5;244mapps    ${E}[0m ${_BAR_OUT} ${E}[38;5;250m${pct}%${E}[0m ${E}[38;5;240m▣ ${APPS_UP}/${APPS_TOTAL}${E}[0m"$'\n'
  else
    pct=$(( STEP_TOTAL>0 ? STEP_DONE*100/STEP_TOTAL : 0 ))
    _set_bar "$STEP_DONE" "$STEP_TOTAL" "$barw"
    countseg="${E}[38;5;120m✓ ${STEP_DONE}/${STEP_TOTAL}${E}[0m"
    f+="${E}[K${UI_MARGIN}${E}[38;5;45m${DOMAIN:-?}${E}[38;5;240m · ${E}[38;5;250m${UI_HOST}${E}[38;5;240m · ${E}[38;5;244m${UI_OS}${E}[0m    ${E}[38;5;81m◷${E}[0m ${E}[1;97m${_EL}${E}[0m   ${countseg}${warns}"$'\n'
    f+="${E}[K${UI_MARGIN}${_BAR_OUT} ${E}[1;38;5;75m${pct}%${E}[0m"$'\n'
  fi
  f+="${E}[K"$'\n'
  if [ "$APPS_PHASE" = 1 ]; then
    # ---- setup checklist collapses to one line; the live app board takes over ----
    if [ "$HUB_LIVE" = 1 ]; then
      f+="${E}[K${UI_MARGIN}${E}[1;38;5;120m✔ hub is live → ${E}[1;4;38;5;159mhttps://hub.${DOMAIN}${E}[0m"$'\n'
    else
      f+="${E}[K${UI_MARGIN}${E}[38;5;120m✔${E}[0m ${E}[38;5;250mhost + platform ready${E}[38;5;240m · ${STEP_DONE}/${STEP_TOTAL} steps${E}[0m"$'\n'
    fi
    rw=$(( UI_CW>18 ? UI_CW-18 : 4 )); _set_rule "$rw"
    f+="${E}[K${UI_MARGIN}${E}[38;5;24m─ ${E}[38;5;75mdeploying apps ${E}[38;5;24m${_RULE_OUT}${E}[0m"$'\n'
    if [ "${#APP_ORDER[@]}" -eq 0 ]; then
      # No snapshot yet — show the intro / recent activity lines, contained.
      [ "$ACT_MAX" -gt 3 ] && f+="${E}[K"$'\n'
      _set_box "${STEP_TITLE:-deploying}"
      f+="$_BOX_OUT"
    else
      # Row budget so the frame never exceeds the terminal (no scroll): rows are
      # header(5: banner+info+2 bars+blank) + summary(1) + divider(1) +
      # footer(1) + safety(1) = 9.
      avail=$(( UI_ROWS - 9 )); [ "$avail" -lt 3 ] && avail=3
      # When truncating, one row is spent on the "… and N more" line, so cap the
      # app rows one lower — otherwise the footer's trailing newline lands on the
      # very bottom row and scrolls the alt-screen (corrupting the frame).
      cap=$avail; [ "${#APP_ORDER[@]}" -gt "$avail" ] && cap=$(( avail - 1 )); [ "$cap" -lt 1 ] && cap=1
      shown=0; more=0
      for n in "${APP_ORDER[@]}"; do
        if [ "$shown" -ge "$cap" ]; then more=$((more+1)); continue; fi
        stt="${APP_STATE[$n]:-queued}"; det="${APP_DETAIL[$n]:-}"
        case "$stt" in
          up)       ic="${E}[38;5;120m✔${E}[0m";            cc="${E}[38;5;252m" ;;
          building) ic="${E}[1;38;5;81m${_SPINCH}${E}[0m"; cc="${E}[1;97m" ;;
          failed)   ic="${E}[1;38;5;203m✖${E}[0m";          cc="${E}[38;5;203m" ;;
          degraded) ic="${E}[38;5;214m▲${E}[0m";            cc="${E}[38;5;214m" ;;
          *)        ic="${E}[38;5;240m○${E}[0m";            cc="${E}[38;5;242m" ;;
        esac
        printf -v namep '%-34s' "${n:0:34}"
        f+="${E}[K${UI_MARGIN}${ic} ${cc}${namep}${E}[0m ${E}[38;5;240m${det}${E}[0m"$'\n'
        shown=$((shown+1))
      done
      [ "$more" -gt 0 ] && f+="${E}[K${UI_MARGIN}${E}[38;5;240m… and ${more} more${E}[0m"$'\n'
      failstr=""; [ "$APPS_FAILED" -gt 0 ] && failstr=" ${E}[38;5;240m· ${E}[38;5;203m${APPS_FAILED} failed${E}[0m"
      _set_elapsed _ELS "$STEP_T0"
      f+="${E}[K${UI_MARGIN}${E}[38;5;120m✔ ${APPS_UP} up${E}[0m ${E}[38;5;240m· ${E}[1;38;5;81m${APPS_BUILDING} building${E}[0m ${E}[38;5;240m· ${E}[38;5;242m${APPS_QUEUED} queued${E}[0m${failstr}   ${E}[38;5;81m◷${E}[0m ${E}[1;97m${_ELS}${E}[0m"$'\n'
    fi
  else
    # ---- normal setup phase: the step checklist + scrolling activity panel ----
    for ((i=1;i<=STEP_TOTAL;i++)); do
      st="${STEP_ST[$i]:-pending}"; name="${STEP_NAMES[$i]:-}"; sec="${STEP_SEC[$i]:-}"
      case "$st" in
        done)    icon="${E}[38;5;120m✔${E}[0m"; col="${E}[38;5;252m"; sec="${E}[38;5;240m${sec}${E}[0m" ;;
        running) icon="${E}[1;38;5;81m${_SPINCH}${E}[0m"; col="${E}[1;97m"; _set_elapsed _ELS "$STEP_T0"; sec="${E}[38;5;81m${_ELS}${E}[0m" ;;
        warn)    icon="${E}[38;5;214m▲${E}[0m"; col="${E}[38;5;252m"; sec="${E}[38;5;214m${sec}${E}[0m" ;;
        fail)    icon="${E}[1;38;5;203m✖${E}[0m"; col="${E}[1;38;5;203m"; sec="${E}[38;5;203mfailed${E}[0m" ;;
        skip)    icon="${E}[38;5;244m⤼${E}[0m"; col="${E}[38;5;244m"; sec="${E}[38;5;240mskipped${E}[0m" ;;
        *)       icon="${E}[38;5;238m○${E}[0m"; col="${E}[38;5;242m"; sec="" ;;
      esac
      printf -v namep '%-42s' "$name"
      f+="${E}[K${UI_MARGIN}${icon} ${col}${namep}${E}[0m ${sec}"$'\n'
    done
    # Breathing row above the box — skipped on cramped terminals where the box
    # is already at its 3-row floor (the spacer would overflow a 24-row console).
    [ "$ACT_MAX" -gt 3 ] && f+="${E}[K"$'\n'
    _set_box "${STEP_TITLE:-activity}"
    f+="$_BOX_OUT"
  fi
  # Vertical centering: width is already centered (UI_MARGIN); pad the frame
  # down so the block sits mid-screen on tall terminals too. Counting the
  # BUILT frame's newlines keeps this exact across every phase and collapse
  # state without duplicating the row budget. Pad rows carry [K so stale
  # content above the block always clears; [J below does the rest.
  local _stripped _vpad _vp="" _j
  _stripped="${f//$'\n'/}"
  _vpad=$(( (UI_ROWS - (${#f} - ${#_stripped})) / 2 ))
  if [ "$_vpad" -gt 0 ]; then
    for ((_j=0;_j<_vpad;_j++)); do _vp+="${E}[K"$'\n'; done
    f="${E}[H${_vp}${f#${E}\[H}"
  fi
  f+="${E}[J"
  # NOTE the trailing `|| true` on the write: after a hangup the pty is gone and
  # printf gets EIO — under set -e that would kill whichever shell rendered
  # (e.g. _stream's reader) even though the run itself must keep going headless.
  if [ "${UI_BIG:-0}" = 1 ]; then
    # DEC double-width is a per-LINE attribute (reset each line), so emit ESC # 6
    # at the start of every row: right after each newline, and after the initial
    # cursor-home for the first row.
    local DWL=$'\033#6'
    f="${f//$'\n'/$'\n'${DWL}}"
    f="${E}[H${DWL}${f#${E}\[H}"
  fi
  printf '%s' "$f" >"$UI_TTY" 2>/dev/null || true
}
_ui_init() {
  [ "$UI_RICH" = 1 ] || return 0
  _ui_size
  # EVERY /dev/tty access needs the job-control guard: a tty WRITE (stty -echo
  # = TCSETS) from outside the tty's foreground group is stopped by SIGTTOU and
  # the shell then waits on the stopped child forever — sudo runs commands on
  # its own pty, so `curl | sudo bash` sits exactly in that trap. This wedged
  # both install and uninstall pre-banner when the echo-off landed unguarded.
  trap '' TTOU TTIN
  _STTY_SAVE="$( { stty -g </dev/tty; } 2>/dev/null || true)"   # snapshot termios so _ui_reset can restore it EXACTLY
  # No key echo while the dashboard owns the screen — a pressed key (the `d`
  # box toggle) would otherwise print itself into the frame until the next
  # repaint. _ui_reset restores the snapshot, so echo comes back on exit.
  { stty -echo </dev/tty; } 2>/dev/null || true
  trap - TTOU TTIN
  : >"$RUN_LOG" 2>/dev/null || true
  rm -f "$UI_BOXMIN" 2>/dev/null || true   # every run starts with the box expanded
  UI_HOST="$(hostname 2>/dev/null || echo host)"; UI_OS="$(_os_short)"; _nap_setup   # cached statics + no-fork nap fd
  # Split the streams: frames paint on the TERMINAL ($UI_TTY); the script's
  # global stdout/stderr divert into the run log. Any bare command or stray
  # print (ufw, python heredocs, …) that is not routed through _stream/_run
  # then lands in the LOG — it physically cannot print below the dashboard,
  # which previously caused scroll/flash as repaints cleared it. The real fds
  # are stashed and restored by _ui_reset so post-run output (final summary,
  # step table, error banners — die/_on_err reset first) reaches the terminal.
  if exec {UI_OUT_FD}>&1 {UI_ERR_FD}>&2 2>/dev/null; then
    _FD_SAVED=1
    exec >>"$RUN_LOG" 2>&1 || true
  fi
  printf '\033[?1049h\033[?25l\033[2J' >"$UI_TTY" 2>/dev/null || true   # alt screen, hide cursor, clear
  UI_ALT=1
  _ui_render
}
_ui_reset() {
  [ "${UI_RICH:-0}" = 1 ] || return 0
  UI_RICH=0
  # Reconnect stdout/stderr to the real terminal FIRST, so everything printed
  # after the dashboard (final summary, error banners, die() messages) is
  # visible instead of quietly appending to the run log.
  if [ "${_FD_SAVED:-0}" = 1 ]; then
    # NOTE: no trailing redirect here — appending `2>/dev/null` to this exec
    # would re-point stderr at /dev/null AFTER restoring it.
    exec 1>&"$UI_OUT_FD" 2>&"$UI_ERR_FD" || true
    exec {UI_OUT_FD}>&- {UI_ERR_FD}>&- || true
    _FD_SAVED=0
  fi
  if [ "$UI_ALT" = 1 ]; then
    printf '\033[?25h\033[?1049l' >"$UI_TTY" 2>/dev/null || printf '\033[?25h\033[?1049l' 2>/dev/null || true
    UI_ALT=0
  fi
  rm -f "$UI_BOXMIN" 2>/dev/null || true
  # Fully restore the terminal. _ui_hold's `read -rsn1` puts the tty in -icanon
  # -echo; when a signal (Ctrl-C) cuts the read short, bash never restores it,
  # leaving a dead prompt with ^C echoing literally. `stty echo` alone did NOT
  # bring back canonical mode / signals — restore the exact saved termios (or
  # fall back to `sane`) so the shell is usable the instant the TUI exits.
  #
  # CRITICAL: ignore SIGTTOU/SIGTTIN around the stty. If _ui_reset runs while
  # this process is NOT the tty's foreground group (e.g. after Ctrl-C on a
  # `curl | sudo bash` pipeline), an stty on /dev/tty is stopped by SIGTTOU and
  # the shell then `wait`s on the stopped child FOREVER — that is what wedged
  # uninstall for 20+ minutes with a `stty echo` child stuck in state T. With
  # the job-control signals ignored, the tty write simply proceeds.
  trap '' TTOU TTIN
  if [ -n "${_STTY_SAVE:-}" ]; then
    stty "$_STTY_SAVE" </dev/tty 2>/dev/null || stty sane </dev/tty 2>/dev/null || true
  else
    stty sane </dev/tty 2>/dev/null || true
  fi
  trap - TTOU TTIN
}
# Keep the final dashboard on screen until the operator presses a key, so the end
# state (which apps came up, which step failed) never just vanishes when the alt
# screen is torn down. A footer prompt is written to the bottom row. Interactive
# only: with no controlling TTY (nohup / piped output) it's a no-op, so unattended
# runs never hang. A long timeout is a safety net for a walk-away run.
_ui_hold() {
  [ "${UI_ALT:-0}" = 1 ] || return 0
  # A pty alone (docker run -t, script/unbuffer, some CI) is NOT a human — never
  # block those. Honor CI markers + an explicit HOLD=0 opt-out, and bound the
  # walk-away wait (UI_HOLD_TIMEOUT, default 10m) so nothing stalls for an hour.
  [ -n "${CI:-}${GITHUB_ACTIONS:-}${NONINTERACTIVE:-}" ] && return 0
  [ "${HOLD:-1}" = 0 ] && return 0
  # Interactivity test: while the dashboard is up, fd 1 is redirected into the
  # run log (output-leak fix), so `-t 1` would be FALSE for every rich run and
  # the hold would silently skip — the dashboard then closes on its own, which
  # is exactly what this hold exists to prevent. Test the SAVED real stdout.
  if [ "${_FD_SAVED:-0}" = 1 ]; then
    [ -t "${UI_OUT_FD}" ] || return 0
  else
    [ -t 1 ] || return 0
  fi
  [ -r /dev/tty ] && [ -w /dev/tty ] || return 0
  local msg="${1:-  \033[1;38;5;75m▸ press any key (or Ctrl-C) to exit…\033[0m}"
  # Ignore job-control stop signals: both the footer write and the read touch
  # /dev/tty, and if this isn't the tty's foreground group they'd be stopped
  # (SIGTTOU/SIGTTIN) and never time out. Ignored, the read just returns.
  trap '' TTOU TTIN
  printf '\033[%d;1H\033[K%b' "${UI_ROWS:-24}" "$msg" >/dev/tty 2>/dev/null || true
  read -rsn1 -t "${UI_HOLD_TIMEOUT:-600}" _ </dev/tty 2>/dev/null || true
  trap - TTOU TTIN
  return 0
}
_ui_winch() { [ "$UI_RICH" = 1 ] || return 0; _ui_size; printf '\033[2J' >"$UI_TTY" 2>/dev/null || true; _ui_render; }
_elapsed_since() { _set_elapsed _ELS "${1:-$RUN_T0}"; printf '%s' "$_ELS"; }

# Run a command; stream its output through the activity panel (in place, not
# scrolling) and persist the full output to $RUN_LOG. Consecutive duplicate
# lines collapse to one "(×N)" entry. Trailing ':' keeps the loop status 0 so
# a successful command never trips the ERR trap under pipefail.
_stream() {
  # NOTE the `</dev/null`: when this script is run as `curl … | sudo bash`, bash
  # reads the SCRIPT ITSELF from stdin (the pipe). A child that inherits stdin
  # (e.g. dokploy_automate.py shelling out to ssh/scp) would then consume the
  # rest of the piped script, so bash hits EOF mid-run and exits silently right
  # after the deploy — no error, no step 14. Detaching the child's stdin keeps
  # the pipe intact so bash reads the whole script.
  # `trap '' HUP` + exec: the child runs with SIGHUP IGNORED (inherited across
  # exec), so an SSH drop that hangs up our process group cannot kill the step
  # command mid-flight — it keeps running and writing; _on_hup keeps this shell
  # alive to read it. Ctrl-C (SIGINT) still reaches the child normally.
  if [ "$UI_RICH" = 1 ]; then
    local rc n=0 last="" dup=0
    # The READER runs as a pipeline subshell, where traps reset to default — a
    # hangup would kill it, and the (HUP-immune) child would then die of
    # SIGPIPE on its next write. Trap HUP in the reader to just stop rendering
    # (UI_RICH=0): it keeps reading and logging, the child keeps running.
    ( trap '' HUP; exec "$@" ) </dev/null 2>&1 | { trap 'UI_RICH=0' HUP; while IFS= read -r _line; do
      if [ "$_line" = "$last" ]; then
        dup=$((dup+1))
        [ "${#ACT[@]}" -gt 0 ] && ACT[$(( ${#ACT[@]}-1 ))]="$_line (×$((dup+1)))"
        printf '%s (×%d)\n' "$_line" "$((dup+1))" >>"$RUN_LOG" 2>/dev/null || true
      else
        _ui_push "$_line" collapse; last="$_line"; dup=0
      fi
      _box_poll
      n=$((n+1)); [ $(( n % 2 )) -eq 0 ] && _ui_render
      :
    done; }
    rc=${PIPESTATUS[0]}
    _ui_render
    return "$rc"
  else
    ( trap '' HUP; exec "$@" ) </dev/null
  fi
}

# Run a slow, SILENT command (e.g. `docker image prune`) while keeping the
# dashboard's step-timer + spinner ANIMATING, so it never looks frozen. A
# background ticker repaints ~1/s while the foreground is blocked in the
# command — no terminal race, because the foreground isn't drawing meanwhile.
# The command's own output is discarded; pair it with a log() line first to
# give the activity panel context. Falls back to a plain silent run.
_run() {
  if [ "$UI_RICH" != 1 ]; then ( trap '' HUP; exec "$@" ) </dev/null >/dev/null 2>&1; return $?; fi
  ( while :; do _ui_render; _nap 0.5; done ) &
  local _tk=$!
  ( trap '' HUP; exec "$@" ) </dev/null >/dev/null 2>&1; local _rc=$?
  kill "$_tk" 2>/dev/null || true; wait "$_tk" 2>/dev/null || true
  _ui_render
  return "$_rc"
}

# Stream a command for the long app-DEPLOY phase. Unlike _stream (which repaints
# only when a new output line arrives — so the clock freezes whenever the child
# is quiet, and docker builds are quiet for minutes), this repaints once/second
# regardless of output, using a single read-with-timeout loop (no ticker → no
# terminal race). "@APP…" board snapshots feed the live app grid; anything else
# scrolls the activity ring. Sets APPS_PHASE so _ui_render shows the board.
# Runs the child via a FIFO so we still get its real exit code from `wait`.
_stream_apps() {
  APPS_PHASE=1
  _ui_size   # phase-aware row budget: the collapsed checklist frees rows for the box
  if [ "$UI_RICH" != 1 ]; then ( trap '' HUP; exec "$@" ) </dev/null; return $?; fi
  local fifo rc pid _line rs
  fifo="$(mktemp -u 2>/dev/null)" || fifo=""
  if [ -z "$fifo" ] || ! mkfifo "$fifo" 2>/dev/null; then
    # No FIFO available — fall back to the normal streamer (still ticks on output).
    _stream "$@"; return $?
  fi
  # HUP-immune like _stream: an SSH drop must not kill the deploy child.
  ( trap '' HUP; exec "$@" ) </dev/null >"$fifo" 2>&1 &
  pid=$!
  exec {AFD}<"$fifo"
  # Both ends are open now (the writer's open rendezvoused with this read-open),
  # so unlink the name immediately — the open fds keep the pipe alive, and no
  # exit path (Ctrl-C / SIGTERM / error mid-deploy) can leak it. Mirrors _nap_setup.
  rm -f "$fifo" 2>/dev/null || true
  while :; do
    if IFS= read -r -t 1 _line <&"$AFD"; then
      case "$_line" in
        @APP*) _apps_update "$_line" ;;
        "")    : ;;
        *)     _ui_push "$_line" collapse ;;
      esac
    else
      rs=$?
      [ "$rs" -le 128 ] && break   # <=128 = EOF/closed (child done); >128 = 1s timeout
    fi
    _box_poll
    _ui_render
  done
  exec {AFD}<&-
  wait "$pid"; rc=$?
  _ui_render
  return "$rc"
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
  else printf '  \033[38;5;74m·\033[0m %s\n' "$*"; fi
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
      "Agentic playground fetch" "DNS pre-check" "Core apps — hub + essentials"
      "AI stack — models + agentic bundle")
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
  printf '\n\033[38;5;24m╭─\033[38;5;75m run summary \033[38;5;24m%s╮\033[0m\n' "$(_ui_rule $((W-13)))"
  local line
  if [ "${#STEP_LINES[@]}" -gt 0 ]; then
  for line in "${STEP_LINES[@]}"; do
    local no="${line%%|*}" rest="${line#*|}"
    local title="${rest%%|*}"; rest="${rest#*|}"
    local status="${rest%%|*}" secs="${rest#*|}"
    local mark='\033[1;38;5;120m✔\033[0m'
    [ "$status" = "warn" ]    && mark='\033[1;38;5;214m▲\033[0m'
    [ "$status" = "skipped" ] && mark='\033[38;5;244m⤼\033[0m'
    printf "\033[38;5;24m│\033[0m ${mark} \033[38;5;74m%2s\033[0m  \033[97m%-42s\033[0m \033[38;5;244m%-8s %6s\033[0m\n" "$no" "$title" "$status" "$secs"
  done
  fi
  printf '\033[38;5;24m╰%s╯\033[0m\n' "$(_ui_rule $((W-1)))"
  printf '  \033[38;5;244mtotal elapsed \033[38;5;81m%s\033[0m   \033[38;5;244mfull log \033[38;5;250m%s\033[0m\n' "$(_elapsed)" "$RUN_LOG"
  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    printf '\n\033[1;38;5;214m▲ %d warning(s) — review before calling this healthy:\033[0m\n' "${#WARNINGS[@]}"
    local w; for w in "${WARNINGS[@]}"; do printf '  \033[38;5;214m▲\033[0m %s\n' "$w"; done
  else
    printf '\n\033[1;38;5;120m✔ no warnings — clean run.\033[0m\n'
  fi
}

_on_err() {
  local code=$?
  # Mark the running step failed, repaint, and HOLD the final frame so the
  # failure point stays on screen — the operator closes it with a keypress —
  # then leave the alt screen and print a persistent banner to the scrollback.
  if [ "${UI_RICH:-0}" = 1 ] && [ "${UI_ALT:-0}" = 1 ]; then
    if [ "${STEP_NO:-0}" -gt 0 ]; then STEP_ST[$STEP_NO]="fail"; fi
    _ui_render
    _ui_hold "  \033[48;5;52;1;97m ✖ FAILED \033[0m \033[1;38;5;203mstep ${STEP_NO}/${STEP_TOTAL} (${STEP_TITLE:-preflight})\033[0m \033[38;5;244mexit ${code}\033[0m  \033[38;5;75m▸ press any key to close…\033[0m"
  fi
  _ui_reset
  printf '\n\033[48;5;52;1;97m ✖ FAILED \033[0m \033[1;38;5;203mstep %d/%d (%s)\033[0m \033[38;5;244mafter %s · exit %d\033[0m\n' \
    "$STEP_NO" "$STEP_TOTAL" "${STEP_TITLE:-preflight}" "$(_elapsed)" "$code" >&2
  printf '\033[38;5;244mfull log: %s\033[0m\n' "${RUN_LOG:-/var/log/dokploy-ai-install.log}" >&2
  if [ "${#WARNINGS[@]}" -gt 0 ]; then
    printf '\033[1;38;5;214mwarnings up to the failure:\033[0m\n' >&2
    local w; for w in "${WARNINGS[@]}"; do printf '  \033[38;5;214m▲\033[0m %s\n' "$w" >&2; done
  fi
  exit "$code"
}
# Ctrl-C / SIGTERM: the operator is choosing to stop — leave the alt screen
# cleanly and say where we were, instead of vanishing with no trace.
_on_signal() {
  trap - INT TERM
  _ui_reset
  printf '\n\033[38;5;214m▲ interrupted at step %d/%d (%s)\033[0m — nothing was rolled back; re-run to continue or use --uninstall.\n' \
    "${STEP_NO:-0}" "$STEP_TOTAL" "${STEP_TITLE:-}" >&2
  exit 130
}
# SIGHUP = the terminal went away (SSH drop, closed window) — NOT a request to
# stop. Losing the VIEW must not kill a 40-minute deploy: demote to headless
# (all further output appends to the run log) and keep provisioning. The
# operator re-attaches with `tail -f $RUN_LOG`. Pairs with (a) the piped-run
# re-exec in preflight — without it a dropped `curl | bash` loses the script
# text itself — and (b) the retry-after-hangup in _stream/_run/_stream_apps,
# because the SAME hangup also SIGHUPs the step command running in our
# process group.
_HUP_SEEN=0
_on_hup() {
  _HUP_SEEN=1
  UI_RICH=0; UI_ALT=0; HOLD=0
  exec >>"$RUN_LOG" 2>&1 </dev/null
  printf '\n▲ terminal hung up at step %s/%s (%s) — continuing HEADLESS; follow with: tail -f %s\n' \
    "${STEP_NO:-0}" "${STEP_TOTAL:-14}" "${STEP_TITLE:-preflight}" "$RUN_LOG"
}
trap _on_hup HUP
trap _ui_reset EXIT
trap _on_err ERR
trap _on_signal INT TERM
trap _ui_winch WINCH

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
# But FIRST: if the script is being read from a PIPE (curl … | sudo bash), its
# source is the ssh session itself — bash reads it incrementally, so if the
# connection drops, curl dies and the REST OF THE SCRIPT never arrives: bash
# stops silently mid-run and no trap can help. Materialize the repo on disk and
# re-exec from the file before doing anything else; from that point on a dead
# terminal only costs the view (see _on_hup), never the run. Detect the piped
# form by $0: a file path means we're already running from disk.
case "${0##*/}" in
  bash|sh|dash|-bash) _PIPED=1 ;;
  *) [ -f "$0" ] && _PIPED=0 || _PIPED=1 ;;
esac
if [ "$_PIPED" = 1 ]; then
  if [ -d "$INSTALL_DIR/.git" ]; then
    git -C "$INSTALL_DIR" fetch -q --depth 1 origin main 2>/dev/null \
      && git -C "$INSTALL_DIR" reset --hard -q FETCH_HEAD 2>/dev/null || true
  else
    command -v git >/dev/null 2>&1 \
      || { apt-get update -y >/dev/null 2>&1 || true; apt-get install -y git >/dev/null 2>&1 || true; }
    git clone -q --depth 1 "$REPO_URL" "$INSTALL_DIR" 2>/dev/null || true
  fi
  if [ -f "$INSTALL_DIR/install.sh" ]; then
    exec bash "$INSTALL_DIR/install.sh" "$@"
  fi
  # Clone failed (no network/git): continue from the pipe — the install still
  # works, it just loses drop-immunity until the preflight clone succeeds.
fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    --domain)          DOMAIN="$2"; shift 2 ;;
    --answers)         ANSWERS="$2"; shift 2 ;;
    --admin-email)     ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-password)  ADMIN_PASSWORD="$2"; shift 2 ;;
    --store)           STORE="$2"; shift 2 ;;
    --skip-harden)     SKIP_HARDEN=1; shift ;;
    --skip-docker)     SKIP_DOCKER=1; shift ;;
    --skip-dns-check)  SKIP_DNS_CHECK=1; shift ;;
    --dns-warn-only)   DNS_WARN_ONLY=1; shift ;;
    --ingress)         INGRESS_MODE="$2"; shift 2 ;;
    --clean)           CLEAN="--clean"; shift ;;
    --plain)           UI_RICH=0; shift ;;
    --big)             BIG=1; shift ;;
    --uninstall)       UNINSTALL=1; shift ;;
    --yes)             ASSUME_YES=1; shift ;;
    --keep-images)     KEEP_IMAGES=1; shift ;;
    --keep-models)     KEEP_MODELS=1; shift ;;
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
  # Leave the swarm FIRST so it stops managing/respawning task containers. The
  # 'leave --force' call itself returns immediately, but the daemon then DRAINS
  # every running task before LocalNodeState flips active -> inactive, and on a
  # full stack that drain takes longer than a couple of seconds. The old fixed
  # 3x2s retry warned while the leave was still (correctly) in progress. Instead:
  # issue the leave once, then POLL until the state actually flips, up to ~40s,
  # keeping the clock ticking — only warn if it genuinely never leaves.
  if command -v docker >/dev/null 2>&1 && docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null | grep -q active; then
    local _i _st=active
    log "leaving the Docker swarm (draining tasks — this can take a bit)…"
    docker swarm leave --force >/dev/null 2>&1 || true
    for _i in $(seq 1 40); do
      _st="$( docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || echo unknown )"
      [ "$_st" = active ] || break
      _nap 1; [ "$UI_RICH" = 1 ] && _ui_render
    done
    if [ "$_st" = active ]; then
      warn "swarm still draining after 40s — the leave was issued and finishes in the background (harmless to the teardown)."
    else
      log "swarm left."
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
      # --keep-models: preserve LLM weight volumes (ollama model store) so the
      # next install skips the multi-GB model downloads — the single longest
      # part of a redeploy. Weights are upstream artifacts, not stack state, so
      # keeping them does not undermine "remove everything" semantics.
      if [ "${KEEP_MODELS:-0}" = "1" ] && [ -n "$_vols" ]; then
        _vols="$( printf '%s\n' "$_vols" | grep -viE 'ollama' || true )"
      fi
      [ -z "$_vols" ] && break
      log "removing $(printf '%s\n' "$_vols" | grep -c .) volume(s)…"
      _run sh -c 'printf "%s\n" "$1" | xargs -r docker volume rm -f' _ "$_vols" || true
      sleep 1
    done
    _run docker network prune -f || true
    _vols="$( docker volume ls -q 2>/dev/null || true )"
    if [ "${KEEP_MODELS:-0}" = "1" ]; then
      _vols="$( printf '%s\n' "$_vols" | grep -viE 'ollama' || true )"
      log "model volumes kept ($(docker volume ls -q 2>/dev/null | grep -ciE 'ollama' || true) ollama volume(s)) — the next install reuses the weights."
    fi
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
if [ "$SKIP_DOCKER" = "1" ]; then
  # --skip-docker: the operator manages Docker themselves. Require it to exist,
  # and leave daemon.json alone (rewriting + restarting their Docker would be
  # rude / disruptive).
  command -v docker >/dev/null 2>&1 \
    || die "--skip-docker set but Docker is not installed. Install Docker first, or drop --skip-docker to let this script install it."
  log "Docker install + daemon.json skipped (--skip-docker); using existing $(docker --version)."
  warn "with --skip-docker, ensure Docker's default-address-pools avoid your admin LAN (e.g. 192.168.x) — see docs/operations.md, or a stray bridge can black-hole SSH."
else
  if command -v docker >/dev/null 2>&1; then
    log "Docker already present: $(docker --version)"
  else
    curl -fsSL https://get.docker.com | sh
  fi
  # Pin Docker's user-network address pools BEFORE Dokploy creates the swarm and
  # the app networks. Docker's built-in pools run 172.17–172.31/16 and then SPILL
  # into 192.168.0.0/16 — which collides with common management/home LANs
  # (192.168.x) once ~16 compose networks exist, and can black-hole the host's OWN
  # SSH (a Docker bridge steals the route to the admin's subnet). Pin to
  # 10.201/10.202.0.0/16 in /24s (512 networks), clear of 172/192.168/most LANs.
  if python3 - /etc/docker/daemon.json <<'PYEOF'
import json, os, sys
p = sys.argv[1]
pools = [{"base": "10.201.0.0/16", "size": 24}, {"base": "10.202.0.0/16", "size": 24}]
try:
    d = json.load(open(p)) if (os.path.exists(p) and os.path.getsize(p)) else {}
except Exception:
    d = {}
if d.get("default-address-pools") == pools:
    sys.exit(1)                       # already correct -> no restart needed
d["default-address-pools"] = pools
os.makedirs(os.path.dirname(p), exist_ok=True)
json.dump(d, open(p, "w"), indent=2)
sys.exit(0)                           # changed -> caller restarts docker
PYEOF
  then
    log "pinned Docker address pools -> 10.201/10.202.0.0/16 (prevents 192.168.x LAN collisions)"
    _run systemctl restart docker || warn "could not restart docker after writing daemon.json"
  else
    log "Docker address pools already pinned to 10.x."
  fi
fi

step "Dokploy platform"
if [ -f /etc/dokploy/dokploy.sh ] || docker service ls 2>/dev/null | grep -q dokploy; then
  log "Dokploy already installed."
else
  _stream sh -c 'curl -sSL https://dokploy.com/install.sh | sh'
fi
# The dokploy SERVICE existing does not guarantee the whole platform does: an
# interrupted install can die after the service is created but before the
# Traefik container is — and the "already installed" shortcut above would then
# skip Traefik forever, leaving every app deployed but nothing listening on
# 80/443 (the whole board verifies 0-up/unreachable). Ensure the ingress
# container exists, mirroring the official installer's shape exactly.
if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx dokploy-traefik; then
  warn "dokploy-traefik container missing (interrupted install?) — creating it."
  docker run -d \
    --name dokploy-traefik \
    --restart always \
    -v /etc/dokploy/traefik/traefik.yml:/etc/traefik/traefik.yml \
    -v /etc/dokploy/traefik/dynamic:/etc/dokploy/traefik/dynamic \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -p 80:80/tcp -p 443:443/tcp -p 443:443/udp \
    traefik:v3.6.7 >/dev/null 2>&1 || warn "could not create dokploy-traefik — check 'docker logs dokploy-traefik'."
  docker network connect dokploy-network dokploy-traefik 2>/dev/null || true
elif ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx dokploy-traefik; then
  log "dokploy-traefik exists but is stopped — starting it."
  docker start dokploy-traefik >/dev/null 2>&1 || warn "could not start dokploy-traefik."
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
  # ESXi/vmxnet3 stream-corruption workaround: with checksum + segmentation
  # offloads ON, corrupt packets pass the vNIC unverified and long-lived
  # connections die under heavy load — observed as SSH sessions dropping with
  # "message authentication code incorrect" exactly while the box pulls
  # gigabytes of images. Software checksums cost a little CPU and remove the
  # failure mode entirely. Applied only when the WAN NIC is vmxnet3; persisted
  # with a oneshot unit so it survives reboots.
  if [ "$(ethtool -i "$WAN_IFACE" 2>/dev/null | awk '/^driver:/{print $2}')" = "vmxnet3" ]; then
    log "vmxnet3 detected — disabling NIC offloads (SSH-drop / stream-corruption fix)"
    ethtool -K "$WAN_IFACE" tso off gso off gro off tx off rx off 2>/dev/null || \
      warn "could not disable NIC offloads on $WAN_IFACE."
    cat > /etc/systemd/system/nic-offload-off.service <<UNIT
[Unit]
Description=Disable NIC offloads (vmxnet3 stream-corruption workaround)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c "IF=\$(ip route | awk '/default/{print \$5; exit}'); ethtool -K \$IF tso off gso off gro off tx off rx off"

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable nic-offload-off.service >/dev/null 2>&1 || true
  fi
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
# Stable, install-form-independent location so a re-run reuses the same checkout
# instead of cloning from scratch. $REPO_DIR differs between forms (curl|bash
# lands under /opt; a local clone under its own parent), so keying the path off it
# made a curl run miss a local run's checkout and re-clone. Pin it, then UPDATE in
# place when it already exists rather than skip-or-reclone.
AGENTIC_DIR="${AGENTIC_DIR:-/opt/cp-agentic-mcp-playground}"
if [ -d "$AGENTIC_DIR/.git" ]; then
  log "Agentic playground already present — updating $AGENTIC_DIR"
  _abranch="$(git -C "$AGENTIC_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)"
  git -C "$AGENTIC_DIR" fetch --depth 1 origin "$_abranch" >/dev/null 2>&1 \
    && git -C "$AGENTIC_DIR" reset --hard FETCH_HEAD >/dev/null 2>&1 \
    || warn "could not update Agentic playground; using the existing checkout."
else
  # Absent, or a partial/empty dir left by an interrupted clone — clear and clone.
  [ -e "$AGENTIC_DIR" ] && rm -rf "$AGENTIC_DIR"
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
# 10-11. Deploy in TWO WAVES, then verify each. Wave 1 = the hub + lightweight
# apps ("core"); wave 2 = the heavy LLM/agentic tier. Wave 2 is triggered only
# AFTER core is up, so the multi-GB model pulls don't starve the quick apps —
# that's what makes https://hub.$DOMAIN reachable in a couple of minutes while
# the slow stack finishes last. Tier comes from each app's "tier" in the
# catalog (default "core"). `-u` keeps the board's snapshots unbuffered.
# ---------------------------------------------------------------------------
APPS_PHASE=1                       # from here on the dashboard is the live app board
HUB_URL="https://hub.$DOMAIN"

_da_common=( --url http://localhost:3000 --ip 127.0.0.1 --domain "$DOMAIN"
  --email "$ADMIN_EMAIL" --password "$ADMIN_PASSWORD"
  --ssh-user root --ssh-private /root/.ssh/id_rsa --ssh-public /root/.ssh/id_rsa.pub
  --config automation/dokploy_config.json --local-server --skip-harden )
_vf_common=( --url http://localhost:3000 --email "$ADMIN_EMAIL" --password "$ADMIN_PASSWORD"
  --config automation/dokploy_config.json --interval "${VERIFY_INTERVAL:-3}" --board )

step "Core apps — hub + essentials"
log "Deploying the hub + lightweight apps first, so $HUB_URL is reachable"
log "in a couple of minutes; the heavy AI stack queues right behind them."
_stream python3 automation/dokploy_automate.py "${_da_common[@]}" --tier core $CLEAN

step "AI stack — models + agentic bundle"
log "Queueing the LLM/agentic stack behind the core apps (Dokploy deploys in"
log "order, so the hub still comes up first), then verifying the whole board."
# --no-purge (and NO $CLEAN) is critical: this is the SECOND wave. A tier deploy
# otherwise clean-slates the whole Dokploy environment before deploying — and
# $CLEAN/--clean deletes every project — either of which would DESTROY the core
# tier we just triggered. The heavy wave must only ADD to the existing core
# deployment, so the clean-slate belongs to the core (first) wave alone.
#
# The heavy TRIGGER runs immediately after the core trigger (no verify barrier
# between them): Dokploy processes deployments in submission order, so the core
# apps still build/pull first and the hub is up just as fast — but the heavy
# wave no longer idles for the length of the core verification (~3-6 min saved).
_stream python3 automation/dokploy_automate.py "${_da_common[@]}" --tier heavy --no-purge || \
  warn "heavy-tier deploy trigger reported an error — check the Dokploy dashboard."
# ONE verify pass over the WHOLE board (every app, both tiers): the live board
# shows the hub flip green early, and a core app that went missing (e.g. a
# cross-tier wipe) fails loudly instead of hiding behind a per-tier check. The
# heavy images are the long pole, so the timeout covers them.
_stream_apps python3 -u automation/utils/verify_deployment.py "${_vf_common[@]}" \
  --tier all --timeout "${VERIFY_TIMEOUT:-2700}" || \
  warn "one or more apps did not come up in time — they may still be building; check the board and the Dokploy dashboard."

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

# Hold the finished dashboard (all steps done, every app on the board) until the
# operator presses a key, so the success state doesn't vanish on exit; then drop
# out of the alt screen and print the summary into the scrollback.
_step_close
_ui_render
_ui_hold "  \033[1;38;5;120m✔ provisioning complete\033[0m  \033[38;5;75m▸ press any key (or Ctrl-C) to exit…\033[0m"
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

  LLM models: the install does NOT wait for model weights — the download was
  triggered and continues in the background (container ollama-pull-models-cpu).
  Chat/agent apps are up now but answer prompts only once their model lands.
    watch progress : sudo docker logs -f ollama-pull-models-cpu
    list ready     : sudo docker exec ollama-cpu ollama list
  (Uninstall with --keep-models and the next install skips this entirely.)

  Any bring-your-own API keys you did not supply were reported above; add
  them to answers.env and re-run this script to enable those integrations.
============================================================
SUMMARY
