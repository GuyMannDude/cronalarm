#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  cronalarm-report.sh — Daily summary of all cron job results
# ═══════════════════════════════════════════════════════════════════
#
#  Runs at 11 PM daily. Reads today's log and sends a summary
#  to Discord showing which jobs passed/failed.
#
# ═══════════════════════════════════════════════════════════════════

CRONALARM_DIR="${CRONALARM_DIR:-$HOME/.cronalarm}"
LOG_DIR="$CRONALARM_DIR/logs"
DATE_TAG=$(date '+%Y-%m-%d')
LOG_FILE="$LOG_DIR/${DATE_TAG}.log"
DISCORD_WEBHOOK="${CRONALARM_DISCORD_WEBHOOK:-}"
INBOX_DIR="${CRONALARM_INBOX_DIR:-$CRONALARM_DIR/inbox}"
HOSTNAME=$(hostname)

if [ ! -f "$LOG_FILE" ]; then
    echo "No cron log for today."
    exit 0
fi

# Counts are ANCHORED to the log line format — a bare "FAIL:" would also
# match job OUTPUT text and inflate the numbers.
STAMP='^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] '
TOTAL=$(grep -cE "${STAMP}START:" "$LOG_FILE" 2>/dev/null); TOTAL=${TOTAL:-0}
PASSED=$(grep -cE "${STAMP}OK:" "$LOG_FILE" 2>/dev/null); PASSED=${PASSED:-0}
FAILED=$(grep -cE "${STAMP}FAIL:" "$LOG_FILE" 2>/dev/null); FAILED=${FAILED:-0}
TIMEOUTS=$(grep -cE "${STAMP}TIMEOUT:" "$LOG_FILE" 2>/dev/null); TIMEOUTS=${TIMEOUTS:-0}

# CLOSED ACCOUNTING with an INDEPENDENT cross-check. The derived remainder
# (total - completions) balances by construction, so on its own it can never
# expose a double-logged completion — it silently absorbs the error into
# in-flight. Measured in-flight counts per job name: starts minus completions.
# The two must agree; a job with more completions than starts is a counter
# defect and forces COUNTER MISMATCH, never green.
IN_FLIGHT=$(( TOTAL - PASSED - FAILED - TIMEOUTS ))
read -r IN_FLIGHT_MEASURED OVER_COMPLETED <<< "$(awk '
    match($0, /^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] START: /) {
        n = substr($0, RSTART + RLENGTH); sub(/ — .*/, "", n); starts[n]++; next }
    match($0, /^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] OK:    /) {
        n = substr($0, RSTART + RLENGTH); sub(/ \([0-9]+s\)$/, "", n); done[n]++; next }
    match($0, /^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] FAIL:  /) {
        n = substr($0, RSTART + RLENGTH); sub(/ — exit=.*/, "", n); done[n]++; next }
    match($0, /^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] TIMEOUT: /) {
        n = substr($0, RSTART + RLENGTH); sub(/ — killed .*/, "", n); done[n]++; next }
    END {
        inflight = 0; over = 0
        for (n in starts) { d = starts[n] - done[n]; if (d > 0) inflight += d }
        for (n in done)   { d = done[n] - starts[n]; if (d > 0) over += d }
        print inflight, over
    }' "$LOG_FILE")"
IN_FLIGHT_MEASURED=${IN_FLIGHT_MEASURED:-0}
OVER_COMPLETED=${OVER_COMPLETED:-0}

if [ "$IN_FLIGHT" -lt 0 ] || [ "$OVER_COMPLETED" -gt 0 ] \
   || [ "$IN_FLIGHT" -ne "$IN_FLIGHT_MEASURED" ]; then
    # The counter itself is wrong. Never green.
    EMOJI="🔴"
    STATUS_WORD="COUNTER MISMATCH"
    ACCOUNTING="derived ${IN_FLIGHT} vs measured ${IN_FLIGHT_MEASURED} in flight, ${OVER_COMPLETED} over-completed — ${PASSED} passed + ${FAILED} failed + ${TIMEOUTS} timeout of ${TOTAL} started"
elif [ "$FAILED" -eq 0 ] && [ "$TIMEOUTS" -eq 0 ]; then
    EMOJI="🟢"
    STATUS_WORD="ALL CLEAR"
    ACCOUNTING="${PASSED} passed + ${FAILED} failed + ${TIMEOUTS} timeout + ${IN_FLIGHT} in flight at report time = ${TOTAL} started"
else
    EMOJI="🔴"
    STATUS_WORD="ISSUES"
    ACCOUNTING="${PASSED} passed + ${FAILED} failed + ${TIMEOUTS} timeout + ${IN_FLIGHT} in flight at report time = ${TOTAL} started"
fi

# Build reports for each channel
REPORT_DISCORD="${EMOJI} **CronAlarm Daily Report — ${HOSTNAME}**
**Date:** ${DATE_TAG}
**Status:** ${STATUS_WORD} — ${ACCOUNTING}"

REPORT_PLAIN="CronAlarm ${STATUS_WORD}: ${ACCOUNTING} on ${HOSTNAME} (${DATE_TAG})"

if [ "$FAILED" -gt 0 ]; then
    REPORT_DISCORD="${REPORT_DISCORD}
🔴 **${FAILED} failures:**"
    FAILURES=$(grep "FAIL:" "$LOG_FILE" | sed 's/.*FAIL:  /  - /' | head -10)
    REPORT_DISCORD="${REPORT_DISCORD}
${FAILURES}"
    REPORT_PLAIN="${REPORT_PLAIN}. ${FAILED} failures."
fi

if [ "$TIMEOUTS" -gt 0 ]; then
    # Timeouts log a single TIMEOUT: line (no FAIL: line since 1.5), so
    # they need their own name listing to stay visible in the report.
    TIMEOUT_LIST=$(grep -E "${STAMP}TIMEOUT:" "$LOG_FILE" | sed 's/.*TIMEOUT: /  - /' | head -10)
    REPORT_DISCORD="${REPORT_DISCORD}
⏰ **${TIMEOUTS} timeouts:**
${TIMEOUT_LIST}"
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
    echo "- **In flight at report time:** $IN_FLIGHT"
    echo "- **Accounting:** $ACCOUNTING"
    echo ""
    echo "## Full Log"
    echo '```'
    cat "$LOG_FILE"
    echo '```'
} > "$REPORT_FILE"
