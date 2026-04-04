#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  backup-to-remote.sh — Tar + send critical files to a remote host
# ═══════════════════════════════════════════════════════════════════
#  Example backup script for CronAlarm.
#  Customize the paths and destination for your setup.
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

DATE=$(date '+%Y%m%d')
HOSTNAME=$(hostname)

# ─── Customize these ───
REMOTE_HOST="myserver"
REMOTE_DIR="/backups/${HOSTNAME}"
BACKUP_PATHS=(
    "$HOME/.config"
    "$HOME/projects"
    # Add your critical paths here
)

# Create remote directory
ssh "$REMOTE_HOST" "mkdir -p $REMOTE_DIR" 2>/dev/null || {
    echo "ERROR: Cannot reach $REMOTE_HOST"
    exit 1
}

# Send archive
tar czf - "${BACKUP_PATHS[@]}" 2>/dev/null | \
    ssh "$REMOTE_HOST" "cat > ${REMOTE_DIR}/${HOSTNAME}-${DATE}.tar.gz"

echo "Backup sent: ${REMOTE_HOST}:${REMOTE_DIR}/${HOSTNAME}-${DATE}.tar.gz"

# Prune old backups (keep 14 days)
ssh "$REMOTE_HOST" "find ${REMOTE_DIR} -name '*.tar.gz' -mtime +14 -delete" 2>/dev/null || true

echo "Done."
