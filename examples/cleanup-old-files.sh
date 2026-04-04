#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  cleanup-old-files.sh — Age-based file cleanup with archive option
# ═══════════════════════════════════════════════════════════════════
#  Example cleanup script for CronAlarm.
#  Customize the directories, ages, and patterns for your setup.
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

DELETED=0

# ─── Customize these cleanup rules ───

# Delete temp files older than 24 hours
TEMP_DIR="/tmp"
if [ -d "$TEMP_DIR" ]; then
    COUNT=$(find "$TEMP_DIR" -maxdepth 1 -user "$USER" -type f -mmin +1440 2>/dev/null | wc -l)
    if [ "$COUNT" -gt 0 ]; then
        find "$TEMP_DIR" -maxdepth 1 -user "$USER" -type f -mmin +1440 -delete 2>/dev/null
        DELETED=$((DELETED + COUNT))
        echo "Cleaned $COUNT temp files (24hr+ old)"
    fi
fi

# Archive (not delete) log files older than 7 days
# LOG_DIR="$HOME/logs"
# ARCHIVE_DIR="$HOME/logs/archive"
# if [ -d "$LOG_DIR" ]; then
#     COUNT=$(find "$LOG_DIR" -maxdepth 1 -name "*.log" -mtime +7 | wc -l)
#     if [ "$COUNT" -gt 0 ]; then
#         mkdir -p "$ARCHIVE_DIR"
#         find "$LOG_DIR" -maxdepth 1 -name "*.log" -mtime +7 -exec mv {} "$ARCHIVE_DIR/" \;
#         echo "Archived $COUNT log files (7d+ old)"
#         DELETED=$((DELETED + COUNT))
#     fi
# fi

# Delete downloads older than 30 days
# DOWNLOADS_DIR="$HOME/Downloads"
# if [ -d "$DOWNLOADS_DIR" ]; then
#     COUNT=$(find "$DOWNLOADS_DIR" -type f -mtime +30 | wc -l)
#     if [ "$COUNT" -gt 0 ]; then
#         find "$DOWNLOADS_DIR" -type f -mtime +30 -delete
#         echo "Cleaned $COUNT old downloads (30d+ old)"
#         DELETED=$((DELETED + COUNT))
#     fi
# fi

if [ "$DELETED" -eq 0 ]; then
    echo "Nothing to clean today."
else
    echo "Total cleaned/archived: $DELETED files"
fi
