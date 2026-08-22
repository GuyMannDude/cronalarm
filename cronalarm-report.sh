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

# `grep -c` already prints 0 when there are no matches — it just exits 1
# while doing so. The old `|| echo 0` therefore appended a SECOND zero on
# every empty count, producing "0\n0" and breaking the later numeric tests
# with `[: 0\n0: integer expression expected`. That error went to stderr and
# the script exited 0 anyway, so it was invisible for as long as the rest.
# Found 2026-07-25 only because the delivery failure above was made loud.
#
# v1.2 (2026-08-09, Opie #2289 "617+0+0 != 623"): two counting defects fixed.
#   1. Counts are ANCHORED to the log line format. Bare "FAIL:" also matched
#      job OUTPUT text ("BACKUP FAIL: ..."), so 08-07 reported 27 failures
#      when 25 jobs failed.
#   2. CLOSED ACCOUNTING. This report runs in the 23:00:01 top-of-hour pack
#      and greps the log while its five siblings — and its own START line —
#      are mid-run, so total exceeded completions by ~6 every night and the
#      gap was silently unexplained. Now: passed+failed+timeouts+in_flight
#      must equal total, in-flight is named, and a mismatch that cannot be
#      in-flight jobs forces ISSUES. A counter that does not reconcile is a
#      watch that can only say fine.
STAMP='^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] '
TOTAL=$(grep -cE "${STAMP}START:" "$LOG_FILE" 2>/dev/null); TOTAL=${TOTAL:-0}
PASSED=$(grep -cE "${STAMP}OK:" "$LOG_FILE" 2>/dev/null); PASSED=${PASSED:-0}
FAILED=$(grep -cE "${STAMP}FAIL:" "$LOG_FILE" 2>/dev/null); FAILED=${FAILED:-0}
TIMEOUTS=$(grep -cE "${STAMP}TIMEOUT:" "$LOG_FILE" 2>/dev/null); TIMEOUTS=${TIMEOUTS:-0}
IN_FLIGHT=$(( TOTAL - PASSED - FAILED - TIMEOUTS ))

# v1.5 (2026-08-17, snag-cronalarm-timeout-double-counted, Opie #2338): the
# derived remainder balances BY CONSTRUCTION, so on its own it can never
# expose a double-logged completion — the 08-10 timeout wrote FAIL: and
# TIMEOUT: both, the report said 5 in flight when the truth was 6, and the
# "=" held. Measured in-flight is an INDEPENDENT second count (per job name,
# starts minus completions); the two must agree. A job with more completions
# than starts is a counter defect and forces COUNTER MISMATCH, never green.
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

# v1.6 (2026-08-19, snag-day-scoped-status-reports-stale, Opie from #2736):
# two defects fixed together.
#   1. STATE, NOT JUST HISTORY. A calendar-day sum answers "did anything
#      break today?" but the reader asks "is anything broken NOW?" — on
#      08-18 both causes were repaired by mid-afternoon, the machine was
#      clean for ~8h, and the report still said ISSUES. Now each failing
#      job is tagged with its LAST completion of the day: every one
#      recovered → 🟡 RECOVERED (never green — the day still had reds,
#      and a fail→pass→fail job stays STILL FAILING because only the
#      final state counts).
#   2. TRUNCATION BY DISTINCT JOB, NOT OCCURRENCE. "head -10" kept the
#      first ten failures; on 08-18 all ten were the same sentinel and
#      the one singleton — a different owner's dead security job — fell
#      below the cut. Frequency is not importance. One line per failing
#      job with a ×count fits any day and can never hide a singleton.
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
# "recovered" must not be inferred from absence of evidence — treat every
# failure as still red. (Reviewer catch, 2026-08-19.)
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
    # green: the reds happened and stay listed — this clears the banner,
    # it does not erase the day.
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
    # "the run did not succeed"), never truncated. See v1.6 note above.
    NBAD=$(printf '%s\n' "$JOB_LINES" | grep -c .)
    REPORT_DISCORD="${REPORT_DISCORD}
🔴 **${FAILED} failures + ${TIMEOUTS} timeouts across ${NBAD} job(s)** — one line per job, nothing truncated:
${JOB_LINES}"
    REPORT_PLAIN="${REPORT_PLAIN}. ${FAILED} failures + ${TIMEOUTS} timeouts across ${NBAD} jobs, ${STILL_FAILING} still red."
fi

# ── GitHub Actions standing state (Opie #2429) ──────────────────────
# Read from github-actions-watch's retention jsonl, NOT from tonight's
# job output: cronalarm keeps output only on failure, so on a night
# where every red is acknowledged the job exits OK and the silenced
# reds would vanish from the one report with a reader. An ack must be
# visible while it lasts. A stale observation is named stale, never
# quoted as current (a stale literal and a live read look identical).
GHA_LINE=$(GHA_STATE_FILE="$CRONALARM_DIR/github-actions-watch.jsonl" python3 - 2>&1 <<'PY'
import json, os
from datetime import datetime, timedelta, timezone
try:
    with open(os.environ["GHA_STATE_FILE"]) as f:
        last = None
        for line in f:
            if line.strip():
                last = line
    if last is None:
        raise ValueError("retention file is empty")
    d = json.loads(last)
    at = datetime.fromisoformat(d["at"])
    # Freshness is "the most recent SCHEDULED run wrote this", not "some
    # write in the last 26h" — on 2026-08-12 the 22:47 run died at its
    # auth guard and this line quoted a 5h-old manual TEST entry as
    # current. Anchoring to the last scheduled slot that has passed
    # covers the whole day with one rule (a dead nightly reads STALE at
    # 23:00 AND on any read the next day). Schedule time has one home:
    # GHA_WATCH_HHMM in ~/.cronalarm/env, which must match the crontab.
    hhmm = os.environ.get("GHA_WATCH_HHMM", "22:47")
    h, m = (int(x) for x in hhmm.split(":"))
    now_local = datetime.now().astimezone()
    anchor = now_local.replace(hour=h, minute=m, second=0, microsecond=0)
    if now_local < anchor:
        anchor -= timedelta(days=1)
    if at < anchor:
        print(f"STALE — no entry from the {anchor:%m-%d} {hhmm} run — "
              f"newest is {d['at'][:16]}Z")
    else:
        print(f"{d.get('workflows', '?')} workflows: {len(d.get('red', []))} red, "
              f"{len(d.get('acknowledged', []))} acknowledged")
        for r in d.get("acknowledged", []):
            print(f"  ACK {r}")
except Exception as e:
    print(f"unreadable ({e})")
PY
)
REPORT_DISCORD="${REPORT_DISCORD}
**GitHub Actions** [github-actions-watch.jsonl]: ${GHA_LINE}"
REPORT_PLAIN="${REPORT_PLAIN} GHA: $(printf '%s' "$GHA_LINE" | head -1)."

echo "$REPORT_DISCORD"

# ── Delivery ─────────────────────────────────────────────────────────
# Routed to the BUS, not Discord (Opie #1493, 2026-07-25). A daily
# all-clear is by definition safe to skim, and #alerts is defined by
# "nothing safe to skim may ever post here" — admitting a nightly green
# tick there would train the exact reflex the channel exists to avoid.
#
# TWO DEFECTS WERE FIXED HERE, and both had to be, even though the
# destination changed — otherwise the same bug is rebuilt in a new pipe:
#
#   1. The old Discord POST sent NO User-Agent. Discord/Cloudflare 403s
#      urllib's default agent. The sibling `cronalarm` script has carried
#      the correct header (and a comment explaining why) the whole time,
#      so the fix sat twenty lines away in the next file.
#   2. The failure was caught, printed to stderr, and the script carried
#      on to exit 0 — so CronAlarm logged "OK: Daily Report (0s)" every
#      night while ZERO reports landed between 2026-02-13 and 2026-07-25.
#
# Net effect: this job's entire purpose was to say "everything is fine",
# and it was itself broken for five months and said nothing. Its silence
# was indistinguishable from the all-clear it was meant to send.
# No default: a bus URL is site-specific infrastructure, and a baked-in
# default would both publish one deployment's topology and silently point
# every other install at an address that is not theirs. Unset = skip the
# bus entirely; the report still lands in $INBOX_DIR either way.
BUS_URL="${CRONALARM_BUS_URL:-}"
SEND_FAILED=0

# v1.7 (2026-08-22, Opie #2835): a green night does not address an inbox.
# Daily ALL CLEARs to Opie buried his real mail (488 unread, near-all green).
# ALL CLEAR -> one line appended to ~/.sparks/green-digest.jsonl (queryable on
# demand; the full report is already in $INBOX_DIR/CRON-REPORT-<date>.md).
# RECOVERED / ISSUES / COUNTER MISMATCH still bus Opie — those need a reader.
# A failed digest append exits 1 exactly like a failed bus POST: this job's
# five-month silent death is why delivery failures are never quiet here.
if [ "$STATUS_WORD" = "ALL CLEAR" ]; then
CRONREPORT_TEXT="$REPORT_DISCORD" \
python3 - "$STATUS_WORD" "$DATE_TAG" "$HOSTNAME" "$ACCOUNTING" <<'PY' || SEND_FAILED=1
import json, os, sys
from datetime import datetime

status, date_tag, host, accounting = sys.argv[1:5]
line = json.dumps({
    "ts": datetime.now().isoformat(timespec="seconds"),
    "watcher": "cron-report",
    "subject": f"cronalarm-daily-report-{date_tag}-{status.lower().replace(' ', '-')}",
    "body": {"host": host, "date": date_tag, "status": status,
             "accounting": accounting,
             "report": os.environ.get("CRONREPORT_TEXT", "")},
})
path = os.path.expanduser("~/.sparks/green-digest.jsonl")
try:
    with open(path, "a") as f:
        f.write(line + "\n")
except OSError as e:
    print(f"green digest append FAILED: {e}", file=sys.stderr)
    sys.exit(1)
print(f"green -> digest (not Opie): {path}")
PY
elif [ -z "$BUS_URL" ]; then
echo "no bus configured (CRONALARM_BUS_URL unset) — report written to inbox only"
else
# The report travels in the environment, not on stdin: stdin is already
# carrying the Python script itself via the heredoc.
CRONREPORT_TEXT="$REPORT_DISCORD" \
python3 - "$BUS_URL" "$STATUS_WORD" "$DATE_TAG" "$HOSTNAME" "$TOTAL" "$PASSED" "$FAILED" "$TIMEOUTS" "$IN_FLIGHT" "$STILL_FAILING" <<'PY' || SEND_FAILED=1
import json, os, sys, urllib.request, urllib.error

bus, status, date_tag, host, total, passed, failed, timeouts, in_flight, still_failing = sys.argv[1:11]
report = os.environ.get("CRONREPORT_TEXT", "")

payload = json.dumps({
    # from: cron-report, NOT CC (Guy's ruling 2026-08-17, snag
    # automated-traffic-under-agent-identity): machine output must not wear
    # an agent's name; sec-watch set the non-agent-sender precedent.
    "mesh_version": "0.5", "from": "cron-report", "to": "Opie",
    "subject": f"cronalarm-daily-report-{date_tag}-{status.lower().replace(' ', '-')}",
    "body": {
        "host": host, "date": date_tag, "status": status,
        "total": int(total), "passed": int(passed),
        "failed": int(failed), "timeouts": int(timeouts),
        "in_flight_at_report_time": int(in_flight),
        "still_failing_at_report_time": int(still_failing),
        "accounting": f"{passed}+{failed}+{timeouts}+{in_flight}={total}",
        "report": report,
        "note": "Bus-only by design. This report is deliberately NOT sent to "
                "Discord: it is safe to skim, and #alerts must never carry "
                "anything safe to skim.",
    },
}).encode()

req = urllib.request.Request(bus, data=payload, method="POST", headers={
    "Content-Type": "application/json",
    # Never omit this again. See the comment block above.
    "User-Agent": "CronAlarmReport/1.2",
})
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        if r.status >= 300:
            print(f"bus report rejected: HTTP {r.status}", file=sys.stderr)
            sys.exit(1)
except (urllib.error.URLError, OSError) as e:
    # Loud, and it propagates. A report nobody receives is the failure
    # mode this entire investigation was about.
    print(f"bus report FAILED: {e}", file=sys.stderr)
    sys.exit(1)
PY
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

# Defect #2, fixed: this script used to end here, so its exit status was
# whatever the last command returned — success, always, even when nothing
# was delivered. CronAlarm believed it for five months.
if [ "$SEND_FAILED" -ne 0 ]; then
    echo "DAILY REPORT NOT DELIVERED — bus POST or green-digest append failed (inbox copy written to $REPORT_FILE)" >&2
    exit 1
fi
exit 0
