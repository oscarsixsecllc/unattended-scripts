#!/usr/bin/env bash
# Version:   1.1.0 (2026-10-14). See README.md, "Versions".
# ---------------------------------------------------------------------------
# heartbeat-check.sh
#
# Purpose:   The "Are you still there?" check. Verifies that the alert
#            channel itself is still receiving alerts. It tests the watcher,
#            not the work. If the newest message in the alert channel is
#            older than expected, or the channel cannot be read at all, the
#            script sends a notice through a DIFFERENT channel.
#
#            The failure this guards against: an alert channel silently
#            broken (permissions, a revoked bot, a deleted webhook) while
#            everything else keeps running, so nobody learns the alerts
#            stopped alerting.
#
# Book ref:  "Unattended", Chapter 6 ("Build the 'are you still there?'
#            check first") and Appendix B, "Scripts and Cron Jobs",
#            "'Are you still there?' heartbeat check".
#
# Cadence:   Every 6 hours. See crontab.example.
#
# How it decides:
#   1. Read the newest message in ALERT_CHANNEL_ID using a Discord bot token.
#      The bot needs "View Channel" and "Read Message History" on that
#      channel. Nothing else.
#   2. If the read fails (HTTP error, no permission, network), that is a
#      finding. The alert path is broken.
#   3. If the read works but the newest message is older than
#      MAX_AGE_HOURS, that is a finding. Something that should have posted
#      did not.
#   4. On any finding, POST a short notice to FALLBACK_WEBHOOK_URL, which
#      must point at a different channel (ideally a different server, or a
#      channel owned by a different bot) so one broken permission cannot
#      take out both paths.
#
#
# Transport:  This is the only script here that needs a bot token, and only
#            to READ the alert channel (a webhook cannot read). The notice it
#            sends still goes out through a plain webhook, like the other
#            scripts. Posting = webhook everywhere; reading = bot token here.
# Usage:     heartbeat-check.sh [--dry-run]
#            --dry-run performs the read (a harmless GET) but prints the
#            fallback notice instead of sending it.
#            To exercise the stale path on purpose, run once with
#            MAX_AGE_HOURS=0. To exercise the "cannot read" path, run once
#            with a wrong bot token.
#
# Env vars (optional, override the defaults set below):
#   DISCORD_BOT_TOKEN     Bot token with read access to the alert channel
#   ALERT_CHANNEL_ID      Numeric ID of the channel that should be receiving alerts
#   FALLBACK_WEBHOOK_URL  Webhook for the OTHER channel that gets the notice
#   MAX_AGE_HOURS         Oldest acceptable newest-message age (default 24)
#
# Adapt this:
#   Set MAX_AGE_HOURS to just above the longest normal gap between
#   messages in your alert channel. If a daily report lands there, 24 to
#   30 hours is right. Placeholders look like <THIS>. The script refuses
#   to run while any placeholder remains.
# ---------------------------------------------------------------------------
set -euo pipefail

# TODO: reader -- configure <DISCORD_BOT_TOKEN> (a bot with read access to the alert channel)
DISCORD_BOT_TOKEN="${DISCORD_BOT_TOKEN:-<DISCORD_BOT_TOKEN>}"

# TODO: reader -- configure <ALERT_CHANNEL_ID> (numeric ID of your alert channel)
ALERT_CHANNEL_ID="${ALERT_CHANNEL_ID:-<ALERT_CHANNEL_ID>}"

# TODO: reader -- configure <FALLBACK_WEBHOOK_URL> (webhook for a DIFFERENT channel)
FALLBACK_WEBHOOK_URL="${FALLBACK_WEBHOOK_URL:-<FALLBACK_WEBHOOK_URL>}"

MAX_AGE_HOURS="${MAX_AGE_HOURS:-24}"

DISCORD_API="https://discord.com/api/v10"

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

send_fallback() {
  local reason="$1"
  local host
  host=$(hostname -s 2>/dev/null || hostname)
  local text="Heartbeat check on ${host}: alert channel problem. ${reason}"
  local payload
  payload=$(printf '{"content": "%s"}' "$(printf '%s' "$text" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')")

  if $DRY_RUN; then
    log "DRY RUN: would POST to fallback webhook:"
    printf '%s\n' "$payload"
    return 0
  fi

  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' \
    -d "$payload" \
    "$FALLBACK_WEBHOOK_URL" || echo "000")
  if [[ "$code" == "204" || "$code" == "200" ]]; then
    log "Fallback notice sent."
  else
    log "ERROR: fallback webhook returned HTTP $code. Both paths may be down."
  fi
}

require_configured DISCORD_BOT_TOKEN "$DISCORD_BOT_TOKEN"
require_configured ALERT_CHANNEL_ID "$ALERT_CHANNEL_ID"
require_configured FALLBACK_WEBHOOK_URL "$FALLBACK_WEBHOOK_URL"

if ! [[ "$MAX_AGE_HOURS" =~ ^[0-9]+$ ]]; then
  log "ERROR: MAX_AGE_HOURS must be a whole number, got: $MAX_AGE_HOURS"
  exit 2
fi

# ---------------------------------------------------------------------------
# 1. Read the newest message in the alert channel
# ---------------------------------------------------------------------------
RESPONSE_FILE=$(mktemp)
trap 'rm -f "$RESPONSE_FILE"' EXIT

HTTP_CODE=$(curl -s -o "$RESPONSE_FILE" -w '%{http_code}' \
  -H "Authorization: Bot ${DISCORD_BOT_TOKEN}" \
  "${DISCORD_API}/channels/${ALERT_CHANNEL_ID}/messages?limit=1" || echo "000")

if [[ "$HTTP_CODE" != "200" ]]; then
  log "Cannot read alert channel: HTTP $HTTP_CODE"
  send_fallback "Could not read the alert channel (HTTP ${HTTP_CODE}). Check the bot's permissions and token."
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Work out how old that message is
# ---------------------------------------------------------------------------
# The API returns a JSON array; the first "timestamp" is the newest message.
LAST_TIMESTAMP=$(grep -o '"timestamp":"[^"]*"' "$RESPONSE_FILE" | head -1 | sed 's/"timestamp":"//; s/"$//')

if [[ -z "$LAST_TIMESTAMP" ]]; then
  log "Alert channel readable but empty (no messages)."
  send_fallback "The alert channel has no messages at all. Nothing has ever posted there, or history was cleared."
  exit 1
fi

LAST_EPOCH=$(date -d "$LAST_TIMESTAMP" +%s 2>/dev/null || echo "")
if [[ -z "$LAST_EPOCH" ]]; then
  log "Could not parse timestamp: $LAST_TIMESTAMP"
  send_fallback "Read the alert channel but could not parse the newest message timestamp (${LAST_TIMESTAMP})."
  exit 1
fi

NOW_EPOCH=$(date +%s)
AGE_SECONDS=$((NOW_EPOCH - LAST_EPOCH))
AGE_HOURS=$((AGE_SECONDS / 3600))
MAX_AGE_SECONDS=$((MAX_AGE_HOURS * 3600))

# ---------------------------------------------------------------------------
# 3. Decide
# ---------------------------------------------------------------------------
if [[ "$AGE_SECONDS" -gt "$MAX_AGE_SECONDS" ]]; then
  log "STALE: newest alert-channel message is ${AGE_HOURS}h old (limit ${MAX_AGE_HOURS}h)."
  send_fallback "Newest message in the alert channel is ${AGE_HOURS} hours old; expected something within ${MAX_AGE_HOURS} hours. The alert path may be broken."
  exit 1
fi

log "FRESH: newest alert-channel message is ${AGE_HOURS}h old (limit ${MAX_AGE_HOURS}h). Alert path looks healthy."
exit 0
