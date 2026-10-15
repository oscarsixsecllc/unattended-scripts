#!/usr/bin/env bash
# Version:   1.1.0 (2026-10-14). See README.md, "Versions".
# ---------------------------------------------------------------------------
# disk-cleanup.sh
#
# Purpose:   Weekly disk hygiene for an always-on agent host. Vacuums the
#            system journal, purges the npm and pip caches, and deletes
#            backup archives older than a retention window.
#
# Book ref:  "Unattended", Chapter 6 (the May 14 disk-fill incident) and
#            Appendix B, "Scripts and Cron Jobs", "Weekly disk-cleanup cron".
#            Also listed in the Chapter 11 architecture inventory.
#
# Cadence:   Weekly, Sunday 02:00 host-local time. See crontab.example.
#
# Runs as:   The user that owns the agent processes. Journal vacuum needs
#            root; the script uses sudo for that one step if it is not
#            already root and skips it (with a note) if sudo is unavailable.
#
# Usage:     disk-cleanup.sh [--dry-run]
#            --dry-run prints what would be removed and changes nothing.
#            Always run it once with --dry-run before installing the cron.
#
# Env vars (optional, override the defaults set below):
#   BACKUP_DIR        Absolute path to your backup archives
#   RETENTION_DAYS    Delete backups older than this many days (default 30)
#   JOURNAL_MAX_SIZE  Cap passed to journalctl --vacuum-size (default 500M)
#
# Adapt this:
#   Every value written as <PLACEHOLDER> must be replaced before the script
#   will run. The script refuses to run while any placeholder remains.
# ---------------------------------------------------------------------------
set -euo pipefail

# TODO: reader -- configure <BACKUP_DIR> (absolute path to your backup archives)
BACKUP_DIR="${BACKUP_DIR:-<BACKUP_DIR>}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
JOURNAL_MAX_SIZE="${JOURNAL_MAX_SIZE:-500M}"

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
  # True when a value still looks like <SOMETHING>
  [[ "$1" == \<*\> ]]
}

require_configured() {
  local name="$1" value="$2"
  if [[ -z "$value" ]] || is_placeholder "$value"; then
    log "ERROR: $name is not configured. Edit this script or export $name."
    exit 2
  fi
}

# ---------------------------------------------------------------------------
# Safety checks
# ---------------------------------------------------------------------------
require_configured BACKUP_DIR "$BACKUP_DIR"

case "$BACKUP_DIR" in
  /|/home|/root|/etc|/usr|/var)
    log "ERROR: refusing to prune $BACKUP_DIR. Point BACKUP_DIR at a dedicated backup directory."
    exit 2
    ;;
esac

if [[ ! -d "$BACKUP_DIR" ]]; then
  log "ERROR: BACKUP_DIR does not exist: $BACKUP_DIR"
  exit 2
fi

if ! [[ "$RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
  log "ERROR: RETENTION_DAYS must be a whole number, got: $RETENTION_DAYS"
  exit 2
fi

if $DRY_RUN; then
  log "DRY RUN: nothing will be deleted or vacuumed."
fi

log "Disk before: $(df -h / | awk 'NR==2 {print $5 " used of " $2}')"

# ---------------------------------------------------------------------------
# 1. Vacuum the system journal (needs root)
# ---------------------------------------------------------------------------
if command -v journalctl >/dev/null 2>&1; then
  if [[ "$(id -u)" -eq 0 ]]; then
    JOURNAL_CMD=(journalctl)
  elif sudo -n true 2>/dev/null; then
    JOURNAL_CMD=(sudo -n journalctl)
  else
    JOURNAL_CMD=()
    log "Journal: skipped (not root and no passwordless sudo). Current size: $(journalctl --disk-usage 2>/dev/null | tr -d '\n')"
  fi

  if [[ ${#JOURNAL_CMD[@]} -gt 0 ]]; then
    if $DRY_RUN; then
      log "Journal: would run '${JOURNAL_CMD[*]} --vacuum-size=$JOURNAL_MAX_SIZE'. Current: $("${JOURNAL_CMD[@]}" --disk-usage 2>/dev/null | tr -d '\n')"
    else
      "${JOURNAL_CMD[@]}" --vacuum-size="$JOURNAL_MAX_SIZE" >/dev/null 2>&1 || log "Journal: vacuum returned an error (continuing)"
      log "Journal: vacuumed to $JOURNAL_MAX_SIZE. Now: $("${JOURNAL_CMD[@]}" --disk-usage 2>/dev/null | tr -d '\n')"
    fi
  fi
else
  log "Journal: journalctl not found, skipped."
fi

# ---------------------------------------------------------------------------
# 2. Purge the npm cache
# ---------------------------------------------------------------------------
if command -v npm >/dev/null 2>&1; then
  if $DRY_RUN; then
    log "npm: would run 'npm cache clean --force'. Cache dir: $(npm config get cache 2>/dev/null)"
  else
    npm cache clean --force >/dev/null 2>&1 || log "npm: cache clean returned an error (continuing)"
    log "npm: cache cleaned."
  fi
else
  log "npm: not installed, skipped."
fi

# ---------------------------------------------------------------------------
# 3. Purge the pip cache
# ---------------------------------------------------------------------------
if command -v pip3 >/dev/null 2>&1; then
  PIP_CMD=(pip3)
elif command -v pip >/dev/null 2>&1; then
  PIP_CMD=(pip)
elif command -v python3 >/dev/null 2>&1; then
  PIP_CMD=(python3 -m pip)
else
  PIP_CMD=()
fi

if [[ ${#PIP_CMD[@]} -gt 0 ]]; then
  if $DRY_RUN; then
    log "pip: would run '${PIP_CMD[*]} cache purge'. Cache: $("${PIP_CMD[@]}" cache dir 2>/dev/null || echo unknown)"
  else
    "${PIP_CMD[@]}" cache purge >/dev/null 2>&1 || log "pip: cache purge returned an error (continuing)"
    log "pip: cache purged."
  fi
else
  log "pip: not installed, skipped."
fi

# ---------------------------------------------------------------------------
# 4. Rotate old backups
# ---------------------------------------------------------------------------
OLD_BACKUPS=$(find "$BACKUP_DIR" -type f -mtime +"$RETENTION_DAYS" 2>/dev/null || true)
OLD_COUNT=0
if [[ -n "$OLD_BACKUPS" ]]; then
  OLD_COUNT=$(printf '%s\n' "$OLD_BACKUPS" | wc -l)
fi

if [[ "$OLD_COUNT" -eq 0 ]]; then
  log "Backups: nothing older than $RETENTION_DAYS days in $BACKUP_DIR"
elif $DRY_RUN; then
  log "Backups: would delete $OLD_COUNT file(s) older than $RETENTION_DAYS days:"
  printf '%s\n' "$OLD_BACKUPS"
else
  find "$BACKUP_DIR" -type f -mtime +"$RETENTION_DAYS" -delete
  log "Backups: deleted $OLD_COUNT file(s) older than $RETENTION_DAYS days from $BACKUP_DIR"
fi

log "Disk after:  $(df -h / | awk 'NR==2 {print $5 " used of " $2}')"
