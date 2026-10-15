#!/usr/bin/env bash
# Version:   1.1.1 (2026-10-15). See README.md, "Versions".
# ---------------------------------------------------------------------------
# disk-usage-post.sh
#
# Purpose:   Post a one-line disk-usage report to a Discord channel once a
#            day. The point is the trend line: seeing the number every day
#            makes growth obvious long before it becomes a crisis.
#
# Book ref:  "Unattended", Chapter 6 and Appendix B, "Scripts and Cron Jobs",
#            "Daily disk-usage report". Appendix B prints a short version
#            of this script; this is the working copy with placeholders
#            instead of real IDs and tokens.
#
# Cadence:   Daily at 16:00 host-local time. See crontab.example.
#            Keep the crontab entry on one line and escape any % as \%
#            (cron treats a bare % as a newline).
#
# Usage:     disk-usage-post.sh [--dry-run]
#            --dry-run prints the message it would send and sends nothing.
#
# Env vars (optional, override the defaults set below):
#   WEBHOOK_URL   Discord webhook URL for the channel that gets the report
#   MOUNT         Filesystem to report on (default: /)
#   WARN_AT       Percent used that flips the message to a warning (default: 80)
#   WATCH_DIRS    Space-separated extra directories to size with du (optional)
#
# Adapt this:
#   cron does not read your shell profile, so set the webhook here or in
#   the crontab line, not in ~/.bashrc. Placeholders look like <THIS>.
#   The script refuses to run while any placeholder remains.
# ---------------------------------------------------------------------------
set -euo pipefail

# TODO: reader -- configure <WEBHOOK_URL> (Discord webhook for your reporting channel)
WEBHOOK_URL="${WEBHOOK_URL:-<WEBHOOK_URL>}"

MOUNT="${MOUNT:-/}"
WARN_AT="${WARN_AT:-80}"

# TODO: reader -- optionally list directories that tend to grow, for example
#                 your agent's session log directory. Leave empty to skip.
WATCH_DIRS="${WATCH_DIRS:-}"

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

is_placeholder() {
  [[ "$1" == \<*\> ]]
}

require_configured() {
  local name="$1" value="$2"
  if [[ -z "$value" ]] || is_placeholder "$value"; then
    log "ERROR: $name is not configured. Edit this script or export $name."
    exit 2
  fi
}

json_escape() {
  # Minimal escaping for a plain-text Discord message body.
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk '{printf "%s\\n", $0}' | sed 's/\\n$//'
}

require_configured WEBHOOK_URL "$WEBHOOK_URL"

# ---------------------------------------------------------------------------
# Gather the number
# ---------------------------------------------------------------------------
# df -h output, data line: Filesystem Size Used Avail Use% Mounted
read -r _ SIZE USED AVAIL PCT _ < <(df -h "$MOUNT" | tail -1)
PCT_NUM="${PCT%\%}"
HOST_LABEL=$(hostname -s 2>/dev/null || hostname)

if [[ "$PCT_NUM" =~ ^[0-9]+$ ]] && (( PCT_NUM >= WARN_AT )); then
  MESSAGE="WARNING Disk on ${HOST_LABEL}: ${PCT} used (${USED} of ${SIZE}, ${AVAIL} free). Over ${WARN_AT}%, run cleanup."
else
  MESSAGE="Disk on ${HOST_LABEL}: ${PCT} used (${USED} of ${SIZE}, ${AVAIL} free)."
fi

if [[ -n "$WATCH_DIRS" ]]; then
  for dir in $WATCH_DIRS; do
    if [[ -d "$dir" ]]; then
      DIR_SIZE=$(du -sh "$dir" 2>/dev/null | awk '{print $1}')
      MESSAGE="${MESSAGE}
${dir}: ${DIR_SIZE}"
    else
      MESSAGE="${MESSAGE}
${dir}: (missing)"
    fi
  done
fi

# ---------------------------------------------------------------------------
# Post it
# ---------------------------------------------------------------------------
PAYLOAD="{\"content\": \"$(json_escape "$MESSAGE")\"}"

if $DRY_RUN; then
  log "DRY RUN: would POST to webhook:"
  printf '%s\n' "$PAYLOAD"
  exit 0
fi

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" \
  "$WEBHOOK_URL" || echo "000")

if [[ "$HTTP_CODE" == "204" || "$HTTP_CODE" == "200" ]]; then
  log "Posted: $MESSAGE"
  exit 0
else
  # Non-zero exit so a wrapper or the heartbeat check can notice that
  # the alert path itself failed.
  log "ERROR: webhook returned HTTP $HTTP_CODE"
  exit 1
fi
