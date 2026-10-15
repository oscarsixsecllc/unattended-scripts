#!/usr/bin/env bash
# Version:   1.1.1 (2026-10-15). See README.md, "Versions".
# ---------------------------------------------------------------------------
# security-audit.sh
#
# Purpose:   Pure-bash host audit for an always-on agent machine. No LLM
#            involved. Runs a fixed list of checks and stays quiet when
#            everything is clean. When something is off, it prints the
#            findings and posts them to a Discord webhook.
#
# Checks:    1. Failed SSH logins in the last 24 hours
#            2. Listening ports that were not in the accepted baseline
#            3. Crontab drift against a version-controlled canonical copy
#            4. Long-running process names (5 minutes or older) that were
#               not in the accepted baseline
#            5. sudo use in the last 24 hours
#            6. Root filesystem usage above a threshold
#            7. Pending package updates (security updates flagged)
#            8. unattended-upgrades installed and its timer enabled
#            9. Secrets files readable by group or others
#
# Book ref:  "Unattended", Chapter 11 ("A security audit cron runs every
#            four hours checking for open ports, crontab drift, and
#            suspicious processes"). Appendix B section F,
#            "Infrastructure discipline".
#
# Cadence:   Every 4 hours. See crontab.example.
#
# Baselines: Ports and process names are compared to a baseline you accept.
#            On the first run the script writes the current state as the
#            baseline and reports that. When you have reviewed a set of
#            findings and decided they are normal, run:
#               security-audit.sh --accept-baseline
#            and the current ports and processes become the new normal.
#
# Dedup:     Identical findings are only posted once per 24 hours. A clean
#            run clears the memory so the next new finding posts at once.
#
# Exit code: 0 clean (or findings suppressed by dedup), 1 findings posted,
#            2 configuration error. cron will mail on nonzero exit if MAILTO
#            is set; most people redirect output to a log instead.
#
# Usage:     security-audit.sh [--dry-run | --accept-baseline]
#            --dry-run runs every check and prints findings but does not
#            post to the webhook and does not update baselines or dedup state.
#
# Env vars (optional, override the defaults set below):
#   WEBHOOK_URL         Discord webhook for the channel that receives findings
#   CRONTAB_CANONICAL   Path to the version-controlled copy of your crontab
#   STATE_DIR           Where baselines and dedup state live
#   SECRET_PATHS        Space-separated files or dirs that must stay private
#   DISK_WARN_PCT       Root filesystem usage that triggers a finding (default 85)
#
# Platform:  Written for Debian or Ubuntu. The update and unattended-upgrades
#            checks use apt and dpkg; on another distribution those two
#            checks report "skipped" rather than failing.
#
# Adapt this:
#   Placeholders look like <THIS>. The script refuses to run while any
#   placeholder remains. Add every directory holding tokens, keys, or
#   .env files to SECRET_PATHS.
# ---------------------------------------------------------------------------
set -euo pipefail

# TODO: reader -- configure <WEBHOOK_URL> (Discord webhook for your alert channel)
WEBHOOK_URL="${WEBHOOK_URL:-<WEBHOOK_URL>}"

# TODO: reader -- configure <CRONTAB_CANONICAL> (path to your committed crontab copy, see crontab.example)
CRONTAB_CANONICAL="${CRONTAB_CANONICAL:-<CRONTAB_CANONICAL>}"

# TODO: reader -- add every path that holds secrets. Defaults cover SSH keys and a
#                 conventional secrets directory under the home directory.
SECRET_PATHS="${SECRET_PATHS:-$HOME/.ssh $HOME/.secrets $HOME/.env}"

STATE_DIR="${STATE_DIR:-$HOME/.local/state/security-audit}"
DISK_WARN_PCT="${DISK_WARN_PCT:-85}"

MODE="run"
case "${1:-}" in
  --dry-run) MODE="dry-run" ;;
  --accept-baseline) MODE="accept-baseline" ;;
  "") ;;
  *) echo "Usage: $0 [--dry-run | --accept-baseline]"; exit 2 ;;
esac

# journalctl --user and systemctl --user need these when started from cron
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"

PORTS_BASELINE="$STATE_DIR/ports.baseline"
PROCS_BASELINE="$STATE_DIR/processes.baseline"
FINGERPRINT_FILE="$STATE_DIR/last-findings.fingerprint"

FINDINGS=""

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

add_finding() {
  if [[ -z "$FINDINGS" ]]; then
    FINDINGS="$1"
  else
    FINDINGS="$FINDINGS

$1"
  fi
}

current_ports() {
  # Listening TCP ports, numeric, one per line, sorted.
  ss -tlnH 2>/dev/null | awk '{print $4}' | grep -oE '[0-9]+$' | sort -un
}

current_processes() {
  # Distinct command names of processes that have been running at least
  # five minutes, sorted. Kernel threads (children of kthreadd, PID 2) are
  # skipped because their names churn. Short-lived commands are skipped so
  # the audit's own helpers and passing cron jobs do not show up as new.
  ps -eo pid=,ppid=,etimes=,comm= 2>/dev/null \
    | awk '$1 != 2 && $2 != 2 && $3 >= 300 {print $4}' \
    | sort -u
}

require_configured WEBHOOK_URL "$WEBHOOK_URL"
require_configured CRONTAB_CANONICAL "$CRONTAB_CANONICAL"
mkdir -p "$STATE_DIR"

# ---------------------------------------------------------------------------
# --accept-baseline: record current ports and processes as normal, then exit
# ---------------------------------------------------------------------------
if [[ "$MODE" == "accept-baseline" ]]; then
  current_ports > "$PORTS_BASELINE"
  current_processes > "$PROCS_BASELINE"
  log "Baseline accepted: $(wc -l < "$PORTS_BASELINE") port(s), $(wc -l < "$PROCS_BASELINE") process name(s) recorded in $STATE_DIR"
  exit 0
fi

# ---------------------------------------------------------------------------
# 1. Failed SSH logins in the last 24 hours
# ---------------------------------------------------------------------------
SSH_LINES=""
if [[ -r /var/log/auth.log ]]; then
  SSH_LINES=$(grep "Failed password" /var/log/auth.log 2>/dev/null || true)
elif command -v journalctl >/dev/null 2>&1; then
  SSH_LINES=$(journalctl -u ssh -u sshd --since "24 hours ago" --no-pager 2>/dev/null | grep "Failed password" || true)
fi
if [[ -n "$SSH_LINES" ]]; then
  SSH_COUNT=$(printf '%s\n' "$SSH_LINES" | wc -l)
  SSH_SOURCES=$(printf '%s\n' "$SSH_LINES" | awk '{print $(NF-3)}' | sort | uniq -c | sort -rn | head -5)
  add_finding "[SSH] $SSH_COUNT failed login attempt(s) in the last 24h. Top sources:
$SSH_SOURCES"
fi

# ---------------------------------------------------------------------------
# 2. Listening ports vs baseline
# ---------------------------------------------------------------------------
PORTS_NOW=$(current_ports)
if [[ ! -f "$PORTS_BASELINE" ]]; then
  if [[ "$MODE" == "run" ]]; then
    printf '%s\n' "$PORTS_NOW" > "$PORTS_BASELINE"
  fi
  add_finding "[PORTS] No port baseline existed. Recorded the current listening ports as the baseline. Review them:
$(printf '%s\n' "$PORTS_NOW" | tr '\n' ' ')"
else
  NEW_PORTS=$(comm -13 <(sort -u "$PORTS_BASELINE") <(printf '%s\n' "$PORTS_NOW" | sort -u) || true)
  if [[ -n "$NEW_PORTS" ]]; then
    PORT_DETAIL=""
    for port in $NEW_PORTS; do
      OWNER=$(ss -tlnpH 2>/dev/null | grep -E "[:.]${port} " | awk '{print $NF}' | head -1)
      PORT_DETAIL="${PORT_DETAIL}
  $port  ${OWNER:-(owner unknown, run as root to see it)}"
    done
    add_finding "[PORTS] Listening port(s) not in the accepted baseline:${PORT_DETAIL}"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Crontab drift vs canonical copy
# ---------------------------------------------------------------------------
if [[ -r "$CRONTAB_CANONICAL" ]]; then
  CRON_LIVE=$(crontab -l 2>/dev/null | grep -v '^#' | grep -v '^[[:space:]]*$' | sort || true)
  CRON_CANON=$(grep -v '^#' "$CRONTAB_CANONICAL" | grep -v '^[[:space:]]*$' | sort || true)
  if [[ "$CRON_LIVE" != "$CRON_CANON" ]]; then
    CRON_DIFF=$(diff <(printf '%s\n' "$CRON_CANON") <(printf '%s\n' "$CRON_LIVE") 2>/dev/null || true)
    add_finding "[CRONTAB] Live crontab differs from canonical copy ($CRONTAB_CANONICAL). Lines with < are canonical, > are live:
$CRON_DIFF"
  fi
else
  add_finding "[CRONTAB] Canonical crontab file is missing or unreadable: $CRONTAB_CANONICAL"
fi

# ---------------------------------------------------------------------------
# 4. Running process names vs baseline
# ---------------------------------------------------------------------------
PROCS_NOW=$(current_processes)
if [[ ! -f "$PROCS_BASELINE" ]]; then
  if [[ "$MODE" == "run" ]]; then
    printf '%s\n' "$PROCS_NOW" > "$PROCS_BASELINE"
  fi
  add_finding "[PROCESSES] No process baseline existed. Recorded $(printf '%s\n' "$PROCS_NOW" | wc -l) current process name(s) as the baseline."
else
  NEW_PROCS=$(comm -13 <(sort -u "$PROCS_BASELINE") <(printf '%s\n' "$PROCS_NOW" | sort -u) || true)
  if [[ -n "$NEW_PROCS" ]]; then
    add_finding "[PROCESSES] Process name(s) running now that were not in the accepted baseline:
$(printf '%s\n' "$NEW_PROCS" | head -20)"
  fi
fi

# ---------------------------------------------------------------------------
# 5. sudo use in the last 24 hours
# ---------------------------------------------------------------------------
SUDO_LINES=""
if [[ -r /var/log/auth.log ]]; then
  CUTOFF=$(date -d "24 hours ago" -Iseconds 2>/dev/null || echo "")
  if [[ -n "$CUTOFF" ]]; then
    SUDO_LINES=$(grep "sudo:" /var/log/auth.log 2>/dev/null | grep -v "pam_unix" | awk -v c="$CUTOFF" '$1 >= c' || true)
  fi
elif command -v journalctl >/dev/null 2>&1; then
  SUDO_LINES=$(journalctl --since "24 hours ago" --no-pager _COMM=sudo 2>/dev/null | grep "COMMAND=" || true)
fi
if [[ -n "$SUDO_LINES" ]]; then
  SUDO_COUNT=$(printf '%s\n' "$SUDO_LINES" | wc -l)
  add_finding "[SUDO] $SUDO_COUNT sudo event(s) in the last 24h. Most recent:
$(printf '%s\n' "$SUDO_LINES" | tail -5)"
fi

# ---------------------------------------------------------------------------
# 6. Root filesystem usage
# ---------------------------------------------------------------------------
DISK_PCT=$(df -P / | awk 'NR==2 {sub("%","",$5); print $5}')
if [[ "$DISK_PCT" -ge "$DISK_WARN_PCT" ]]; then
  add_finding "[DISK] Root filesystem is ${DISK_PCT}% full (threshold ${DISK_WARN_PCT}%). $(df -h / | awk 'NR==2 {print $4 " left of " $2}')"
fi

# ---------------------------------------------------------------------------
# 7. Pending package updates
# ---------------------------------------------------------------------------
if command -v apt >/dev/null 2>&1; then
  UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -v '^Listing' || true)
  if [[ -n "$UPGRADABLE" ]]; then
    TOTAL_UPDATES=$(printf '%s\n' "$UPGRADABLE" | wc -l)
    SECURITY_UPDATES=$(printf '%s\n' "$UPGRADABLE" | grep -c -- '-security' || true)
    if [[ "$SECURITY_UPDATES" -gt 0 ]]; then
      add_finding "[UPDATES] $SECURITY_UPDATES security update(s) pending ($TOTAL_UPDATES total):
$(printf '%s\n' "$UPGRADABLE" | grep -- '-security' | awk -F/ '{print "  " $1}' | head -10)"
    elif [[ "$TOTAL_UPDATES" -gt 25 ]]; then
      add_finding "[UPDATES] $TOTAL_UPDATES package update(s) pending, none marked security. Patch window overdue."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 8. unattended-upgrades installed and enabled
# ---------------------------------------------------------------------------
if command -v dpkg >/dev/null 2>&1; then
  if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
    add_finding "[UNATTENDED-UPGRADES] Package is not installed. Automatic security patching is off."
  else
    TIMER_STATE=$(systemctl is-enabled apt-daily-upgrade.timer 2>/dev/null || echo "unknown")
    if [[ "$TIMER_STATE" != "enabled" ]]; then
      add_finding "[UNATTENDED-UPGRADES] Installed, but apt-daily-upgrade.timer is '$TIMER_STATE'. Automatic patching may not be running."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 9. Secrets files readable by group or others
# ---------------------------------------------------------------------------
LOOSE_FILES=""
for path in $SECRET_PATHS; do
  [[ -e "$path" ]] || continue
  if [[ -d "$path" ]]; then
    # Public keys and known_hosts are meant to be world-readable; skip them.
    FOUND=$(find "$path" -type f -perm /077 ! -name '*.pub' ! -name 'known_hosts*' 2>/dev/null || true)
  else
    FOUND=$(find "$path" -maxdepth 0 -type f -perm /077 2>/dev/null || true)
  fi
  if [[ -n "$FOUND" ]]; then
    LOOSE_FILES="${LOOSE_FILES}
$FOUND"
  fi
done
if [[ -n "$LOOSE_FILES" ]]; then
  add_finding "[SECRETS] File(s) under SECRET_PATHS readable by group or others (expect 600):$LOOSE_FILES
Fix with: chmod 600 <file>"
fi

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
STAMP=$(date '+%Y-%m-%d %H:%M')
HOST_LABEL=$(hostname -s 2>/dev/null || hostname)

if [[ -z "$FINDINGS" ]]; then
  log "Security audit CLEAN on $HOST_LABEL"
  if [[ "$MODE" == "run" ]]; then
    rm -f "$FINGERPRINT_FILE"
  fi
  exit 0
fi

printf '=== Security audit %s on %s ===\n\n%s\n\n=== end of findings ===\n' "$STAMP" "$HOST_LABEL" "$FINDINGS"

if [[ "$MODE" == "dry-run" ]]; then
  log "DRY RUN: findings above were not posted and no state was written."
  exit 1
fi

# Dedup: identical findings within 24h are not re-posted.
FINGERPRINT=$(printf '%s' "$FINDINGS" | sha256sum | awk '{print $1}')
LAST_FINGERPRINT=""
LAST_POSTED=0
if [[ -r "$FINGERPRINT_FILE" ]]; then
  LAST_FINGERPRINT=$(sed -n '1p' "$FINGERPRINT_FILE")
  LAST_POSTED=$(sed -n '2p' "$FINGERPRINT_FILE")
fi
LAST_POSTED="${LAST_POSTED:-0}"
if ! [[ "$LAST_POSTED" =~ ^[0-9]+$ ]]; then
  LAST_POSTED=0
fi
NOW=$(date +%s)
if [[ "$FINGERPRINT" == "$LAST_FINGERPRINT" ]] && (( NOW - LAST_POSTED < 86400 )); then
  log "Same findings as last post within 24h. Not re-posting."
  exit 0
fi

# Discord caps a message at 2000 characters. Keep headroom for the title.
BODY=$(printf '**Security audit %s on %s**\n\n%s' "$STAMP" "$HOST_LABEL" "$FINDINGS" | head -c 1800)
PAYLOAD=$(printf '{"content": "%s"}' "$(printf '%s' "$BODY" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk '{printf "%s\\n", $0}' | sed 's/\\n$//')")

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD" \
  "$WEBHOOK_URL" || echo "000")

if [[ "$HTTP_CODE" == "204" || "$HTTP_CODE" == "200" ]]; then
  log "Findings posted to webhook."
  printf '%s\n%s\n' "$FINGERPRINT" "$NOW" > "$FINGERPRINT_FILE"
else
  log "ERROR: webhook returned HTTP $HTTP_CODE. Findings are in this log only."
fi
exit 1
