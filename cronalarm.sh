#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  CronAlarm — The Job Runner That Screams When Things Break
# ═══════════════════════════════════════════════════════════════════
#
#  Every cron job runs through this wrapper. If it fails, you hear
#  about it immediately via Discord, and it always lands in the local
#  inbox. No silent failures. Ever.
#
#  Usage:
#    cronalarm <job-name> <command...>
#
#  Examples:
#    cronalarm "Hourly Backup" /home/user/scripts/backup.sh
#    cronalarm "Vital Monitor" /home/user/scripts/vitals.sh
#
#  What it does:
#    1. Logs the start time
#    2. Runs the command with a configurable timeout
#    3. Captures stdout, stderr, and exit code
#    4. If exit code != 0 → screams via every configured channel
#    5. Logs everything to ~/.cronalarm/logs/
#    6. If the command hangs beyond TIMEOUT → kills it and alerts
#
#  Notification channels (configure in ~/.cronalarm/env):
#    - Discord webhook
#    - Local file drop (always on)
#
#  Removed channels: Textbelt SMS (1.2), Telegram (1.3) — both dropped
#  once dead rather than left in place looking like coverage.
#
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

# ─── Self-contained environment ───
# A manual run without `source ~/.cronalarm/env` must behave like a cron run:
# same inbox, same webhooks. A sourcing failure falls back to the defaults
# below instead of killing the wrapper — a config problem must never be the
# reason a failure went unreported.
if [ -z "${CRONALARM_INBOX_DIR:-}" ] && [ -f "$HOME/.cronalarm/env" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.cronalarm/env" || echo "cronalarm: WARNING: sourcing ~/.cronalarm/env failed; using defaults" >&2
fi

# ─── Configuration ───
CRONALARM_DIR="${CRONALARM_DIR:-$HOME/.cronalarm}"
DISCORD_WEBHOOK="${CRONALARM_DISCORD_WEBHOOK:-}"
MENTION="${CRONALARM_MENTION:-}"  # optional, e.g. "@here" — prepended to Discord failure alerts
LOG_DIR="$CRONALARM_DIR/logs"
TIMEOUT="${CRONALARM_TIMEOUT:-300}"
HOSTNAME=$(hostname)
INBOX_DIR="${CRONALARM_INBOX_DIR:-$CRONALARM_DIR/inbox}"

# ─── Arguments ───
if [ $# -lt 2 ]; then
    echo "Usage: cronalarm <job-name> <command...>"
    echo "Example: cronalarm 'Hourly Backup' /home/user/scripts/backup.sh"
    exit 1
fi

JOB_NAME="$1"
shift
COMMAND="$*"

# ─── Setup ───
mkdir -p "$LOG_DIR" "$INBOX_DIR"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
DATE_TAG=$(date '+%Y-%m-%d')
LOG_FILE="$LOG_DIR/${DATE_TAG}.log"
TEMP_OUTPUT=$(mktemp)

# ─── Log start ───
echo "[$TIMESTAMP] START: $JOB_NAME — $COMMAND" >> "$LOG_FILE"

# ─── Run with timeout ───
START_SECONDS=$SECONDS
EXIT_CODE=0
timeout "$TIMEOUT" bash -c "$COMMAND" > "$TEMP_OUTPUT" 2>&1 || EXIT_CODE=$?

DURATION=$(( SECONDS - START_SECONDS ))
OUTPUT=$(tail -50 "$TEMP_OUTPUT")  # Last 50 lines max
rm -f "$TEMP_OUTPUT"

# ─── Log result ───
END_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

if [ $EXIT_CODE -eq 0 ]; then
    echo "[$END_TIMESTAMP] OK:    $JOB_NAME (${DURATION}s)" >> "$LOG_FILE"
    exit 0
fi

# ═══════════════════════════════════════════════════
#  FAILURE PATH — SCREAM ON EVERY CHANNEL
# ═══════════════════════════════════════════════════

# ONE completion line per job (1.5). A timeout used to write FAIL: and then
# TIMEOUT: as a second line, so every timed-out job counted as two
# completions in the daily report and silently absorbed one in-flight job.
TIMEOUT_FLAG=""
if [ $EXIT_CODE -eq 124 ]; then
    TIMEOUT_FLAG=" [TIMEOUT after ${TIMEOUT}s]"
    echo "[$END_TIMESTAMP] TIMEOUT: $JOB_NAME — killed after ${TIMEOUT}s (exit=124)" >> "$LOG_FILE"
else
    echo "[$END_TIMESTAMP] FAIL:  $JOB_NAME — exit=$EXIT_CODE (${DURATION}s)" >> "$LOG_FILE"
fi
echo "  Output: ${OUTPUT:0:500}" >> "$LOG_FILE"

# ─── Discord (markdown) ───
if [ -n "$DISCORD_WEBHOOK" ]; then
    # Use python3 for safe JSON encoding — no shell string injection
    # `|| DISCORD_SEND_FAILED=1` (not a bare $? check): the script runs under
    # set -e, so an unguarded non-zero python exit would abort HERE and skip
    # the WARN log line and the inbox drop below. Fired-test-verified 2026-08-01.
    DISCORD_SEND_FAILED=0
    python3 -c "
import json, sys, urllib.request

msg = json.dumps({'content': sys.stdin.read()[:2000]})
req = urllib.request.Request(
    '$DISCORD_WEBHOOK',
    data=msg.encode('utf-8'),
    # Discord/Cloudflare 403s urllib's default user-agent — must send a real one
    headers={'Content-Type': 'application/json', 'User-Agent': 'CronAlarm/1.1'},
    method='POST'
)
try:
    urllib.request.urlopen(req, timeout=10)
except Exception as e:
    print(f'Discord alert failed: {e}', file=sys.stderr)
    # Exit non-zero so the wrapper's WARN branch is reachable. Before
    # 2026-08-01 this swallowed the exception and exited 0, so the
    # 'WARN: Discord alert failed' log line below could NEVER fire —
    # a silent alert loss would have left a clean log.
    sys.exit(1)
" <<DISCORD_EOF || DISCORD_SEND_FAILED=1
${MENTION:+${MENTION} }🚨 **CRON FAILURE on ${HOSTNAME}**${TIMEOUT_FLAG}

**Job:** ${JOB_NAME}
**Command:** \`${COMMAND}\`
**Exit Code:** ${EXIT_CODE}
**Duration:** ${DURATION}s
**Time:** ${END_TIMESTAMP}

**Output (last 50 lines):**
\`\`\`
${OUTPUT:0:1500}
\`\`\`
DISCORD_EOF

    if [ "$DISCORD_SEND_FAILED" -ne 0 ]; then
        echo "[$END_TIMESTAMP] WARN: Discord alert failed" >> "$LOG_FILE"
    fi
fi

# ─── Telegram: REMOVED in 1.3 (2026-07-25) ───
# The bot token and chat id were both empty strings, so the `-n` guard
# skipped this block on every run since install — the channel was never
# actually live. It cost nothing at runtime but it read as coverage in
# the config, the header comment and the docs, which is worse than absent:
# it invites you to believe a second route exists. Ripped out for the
# same reason 1.2 dropped Textbelt SMS.

# ─── Local file drop (always on) ───
SCREAM_FILE="$INBOX_DIR/CRON-FAILURE-${DATE_TAG}.md"
{
    echo "# 🚨 Cron Failure: $JOB_NAME${TIMEOUT_FLAG}"
    echo ""
    echo "- **Time:** $END_TIMESTAMP"
    echo "- **Command:** \`$COMMAND\`"
    echo "- **Exit Code:** $EXIT_CODE"
    echo "- **Duration:** ${DURATION}s"
    echo "- **Output:**"
    echo '```'
    echo "${OUTPUT:0:500}"
    echo '```'
    echo ""
} >> "$SCREAM_FILE"

exit $EXIT_CODE
