#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  cronalarm-report.sh — Daily summary of all cron job results
# ═══════════════════════════════════════════════════════════════════
#
#  Runs at 11 PM daily. Reads today's log and sends a summary
#  to Discord (and optionally SMS) showing which jobs passed/failed.
#
# ═══════════════════════════════════════════════════════════════════

CRONALARM_DIR="${CRONALARM_DIR:-$HOME/.cronalarm}"
LOG_DIR="$CRONALARM_DIR/logs"
DATE_TAG=$(date '+%Y-%m-%d')
LOG_FILE="$LOG_DIR/${DATE_TAG}.log"
DISCORD_WEBHOOK="${CRONALARM_DISCORD_WEBHOOK:-}"
SMS_PHONE="${CRONALARM_SMS_PHONE:-}"
SMS_KEY="${CRONALARM_SMS_KEY:-textbelt}"
INBOX_DIR="${CRONALARM_INBOX_DIR:-$CRONALARM_DIR/inbox}"
HOSTNAME=$(hostname)

if [ ! -f "$LOG_FILE" ]; then
    echo "No cron log for today."
    exit 0
fi

TOTAL=$(grep -c "^.*START:" "$LOG_FILE" 2>/dev/null || echo 0)
PASSED=$(grep -c "^.*OK:" "$LOG_FILE" 2>/dev/null || echo 0)
FAILED=$(grep -c "^.*FAIL:" "$LOG_FILE" 2>/dev/null || echo 0)
TIMEOUTS=$(grep -c "^.*TIMEOUT:" "$LOG_FILE" 2>/dev/null || echo 0)

if [ "$FAILED" -eq 0 ] && [ "$TIMEOUTS" -eq 0 ]; then
    EMOJI="🟢"
    STATUS_WORD="ALL CLEAR"
else
    EMOJI="🔴"
    STATUS_WORD="ISSUES"
fi

# Build reports for each channel
REPORT_DISCORD="${EMOJI} **CronAlarm Daily Report — ${HOSTNAME}**
**Date:** ${DATE_TAG}
**Status:** ${STATUS_WORD} — ${PASSED}/${TOTAL} jobs passed"

REPORT_PLAIN="CronAlarm ${STATUS_WORD}: ${PASSED}/${TOTAL} jobs passed on ${HOSTNAME} (${DATE_TAG})"

if [ "$FAILED" -gt 0 ]; then
    REPORT_DISCORD="${REPORT_DISCORD}
🔴 **${FAILED} failures:**"
    FAILURES=$(grep "FAIL:" "$LOG_FILE" | sed 's/.*FAIL:  /  - /' | head -10)
    REPORT_DISCORD="${REPORT_DISCORD}
${FAILURES}"
    REPORT_PLAIN="${REPORT_PLAIN}. ${FAILED} failures."
fi

if [ "$TIMEOUTS" -gt 0 ]; then
    REPORT_DISCORD="${REPORT_DISCORD}
⏰ **${TIMEOUTS} timeouts**"
    REPORT_PLAIN="${REPORT_PLAIN} ${TIMEOUTS} timeouts."
fi

echo "$REPORT_DISCORD"

# Send to Discord
if [ -n "$DISCORD_WEBHOOK" ]; then
    python3 -c "
import json, sys, urllib.request
msg = json.dumps({'content': sys.stdin.read()[:2000]})
req = urllib.request.Request(
    '$DISCORD_WEBHOOK',
    data=msg.encode('utf-8'),
    headers={'Content-Type': 'application/json'},
    method='POST'
)
try:
    urllib.request.urlopen(req, timeout=10)
except Exception as e:
    print(f'Discord report failed: {e}', file=sys.stderr)
" <<< "$REPORT_DISCORD"
fi

# Send SMS summary only if there were failures
if [ -n "$SMS_PHONE" ] && { [ "$FAILED" -gt 0 ] || [ "$TIMEOUTS" -gt 0 ]; }; then
    curl -sf -X POST https://textbelt.com/text \
        --data-urlencode "phone=${SMS_PHONE}" \
        --data-urlencode "message=${REPORT_PLAIN:0:160}" \
        -d "key=${SMS_KEY}" > /dev/null 2>&1 || true
fi

# Write to inbox
mkdir -p "$INBOX_DIR"
REPORT_FILE="$INBOX_DIR/CRON-REPORT-${DATE_TAG}.md"
{
    echo "# CronAlarm Daily Report — ${DATE_TAG}"
    echo ""
    echo "- **Host:** $HOSTNAME"
    echo "- **Total jobs:** $TOTAL"
    echo "- **Passed:** $PASSED"
    echo "- **Failed:** $FAILED"
    echo "- **Timeouts:** $TIMEOUTS"
    echo ""
    echo "## Full Log"
    echo '```'
    cat "$LOG_FILE"
    echo '```'
} > "$REPORT_FILE"
