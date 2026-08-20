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

# STATE, NOT JUST HISTORY (1.6). A calendar-day sum answers "did anything
# break today?" but the reader asks "is anything broken NOW?" Tag every
# failing job with its LAST completion of the day: all recovered → amber
# RECOVERED (never green — the reds happened and stay listed); anything
# still red → ISSUES. A fail→pass→fail job stays red: only final state
# counts. First line of output is the still-failing count, then one line
# per failing job — truncation by distinct job, never by occurrence, so
# a singleton failure can never fall below a "first N" cut.
JOB_STATE=$(awk '
    match($0, /^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] OK:    /) {
        n = substr($0, RSTART + RLENGTH); sub(/ \([0-9]+s\)$/, "", n)
        last[n] = "OK"; oksince[n]++; next }
    match($0, /^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] FAIL:  /) {
        t = substr($0, 13, 5)
        n = substr($0, RSTART + RLENGTH); sub(/ — exit=.*/, "", n)
        bad[n]++; last[n] = "FAIL"; lastbad[n] = t; oksince[n] = 0; next }
    match($0, /^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] TIMEOUT: /) {
        t = substr($0, 13, 5)
        n = substr($0, RSTART + RLENGTH); sub(/ — killed .*/, "", n)
        bad[n]++; last[n] = "TIMEOUT"; lastbad[n] = t; oksince[n] = 0; next }
    END {
        still = 0
        for (n in bad) if (last[n] != "OK") still++
        print still
        for (n in bad) {
            state = (last[n] == "OK") \
                ? "recovered (" oksince[n] " OK since)" \
                : "STILL " last[n] " at report time"
            printf "  - %s ×%d — last bad %s · %s\n", n, bad[n], lastbad[n], state
        }
    }' "$LOG_FILE")
STILL_FAILING=$(printf '%s\n' "$JOB_STATE" | head -1)
STILL_FAILING=${STILL_FAILING:-0}
# Fail RED, not amber: if awk died and produced nothing (or garbage),
# "recovered" must not be inferred from absence of evidence.
case "$STILL_FAILING" in ''|*[!0-9]*) STILL_FAILING=$(( FAILED + TIMEOUTS ));; esac
JOB_LINES=$(printf '%s\n' "$JOB_STATE" | tail -n +2 | sort)

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
elif [ "$STILL_FAILING" -eq 0 ]; then
    # Every job that failed today passed its most recent run. Amber, not
    # green: this clears the banner, it does not erase the day.
    EMOJI="🟡"
    STATUS_WORD="RECOVERED"
    ACCOUNTING="${PASSED} passed + ${FAILED} failed + ${TIMEOUTS} timeout + ${IN_FLIGHT} in flight at report time = ${TOTAL} started; every failing job passed its latest run"
else
    EMOJI="🔴"
    STATUS_WORD="ISSUES"
    ACCOUNTING="${PASSED} passed + ${FAILED} failed + ${TIMEOUTS} timeout + ${IN_FLIGHT} in flight at report time = ${TOTAL} started; ${STILL_FAILING} job(s) still red at report time"
fi

# Build reports for each channel
REPORT_DISCORD="${EMOJI} **CronAlarm Daily Report — ${HOSTNAME}**
**Date:** ${DATE_TAG}
**Status:** ${STATUS_WORD} — ${ACCOUNTING}"

REPORT_PLAIN="CronAlarm ${STATUS_WORD}: ${ACCOUNTING} on ${HOSTNAME} (${DATE_TAG})"

if [ "$FAILED" -gt 0 ] || [ "$TIMEOUTS" -gt 0 ]; then
    # One line per distinct job (FAIL and TIMEOUT together — both are
    # "the run did not succeed"), never truncated. See 1.6 note above.
    NBAD=$(printf '%s\n' "$JOB_LINES" | grep -c .)
    REPORT_DISCORD="${REPORT_DISCORD}
🔴 **${FAILED} failures + ${TIMEOUTS} timeouts across ${NBAD} job(s)** — one line per job, nothing truncated:
${JOB_LINES}"
    REPORT_PLAIN="${REPORT_PLAIN}. ${FAILED} failures + ${TIMEOUTS} timeouts across ${NBAD} jobs, ${STILL_FAILING} still red."
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
    echo "- **Still failing at report time:** $STILL_FAILING"
    echo "- **Accounting:** $ACCOUNTING"
    echo ""
    echo "## Full Log"
    echo '```'
    cat "$LOG_FILE"
    echo '```'
} > "$REPORT_FILE"
