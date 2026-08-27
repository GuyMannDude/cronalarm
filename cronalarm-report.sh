#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  cronalarm-report.sh — Daily summary of all cron job results
# ═══════════════════════════════════════════════════════════════════
#
#  Runs at 11 PM daily. Reads today's log and reports which jobs
#  passed, failed, recovered — and which scheduled runs never
#  happened at all. Also surfaces non-critical warnings: any job may
#  append lines to $CRONALARM_WARN_DIR/YYYY-MM-DD.log (default
#  ~/.cronalarm/warnings/) and they appear in this report — warnings
#  never page, but they no longer evaporate either (v2.3).
#
#  Delivery (all optional, all config-driven — see ~/.cronalarm/env):
#    - Local inbox file          — always written, the durability anchor
#    - Green digest (jsonl)      — ALL CLEAR days append one line here
#    - Discord webhook           — CRONALARM_REPORT_WEBHOOK, non-green days
#    - JSON POST endpoint        — CRONALARM_BUS_URL, non-green days
#
#  Nothing site-specific is baked in: with no channels configured the
#  report degrades to inbox-only, never to a POST at an empty string.
#
# ═══════════════════════════════════════════════════════════════════

# ─── Self-contained environment ───
# A manual run without `source ~/.cronalarm/env` must behave like a cron
# run: same channels, same paths. A sourcing failure falls back to the
# defaults below instead of killing the report.
if [ -z "${CRONALARM_INBOX_DIR:-}" ] && [ -f "$HOME/.cronalarm/env" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.cronalarm/env" || echo "cronalarm-report: WARNING: sourcing ~/.cronalarm/env failed; using defaults" >&2
fi

CRONALARM_DIR="${CRONALARM_DIR:-$HOME/.cronalarm}"
LOG_DIR="$CRONALARM_DIR/logs"
DATE_TAG=$(date '+%Y-%m-%d')
LOG_FILE="$LOG_DIR/${DATE_TAG}.log"
INBOX_DIR="${CRONALARM_INBOX_DIR:-$CRONALARM_DIR/inbox}"
HOSTNAME=$(hostname)

# Site-specific delivery + feature config. Every default is either local
# or empty: a fresh install must never POST anywhere it wasn't pointed.
BUS_URL="${CRONALARM_BUS_URL:-}"                  # JSON endpoint; empty = skip
BUS_TO="${CRONALARM_BUS_TO:-ops}"                 # recipient field in the JSON payload
REPORT_WEBHOOK="${CRONALARM_REPORT_WEBHOOK:-}"    # Discord webhook for the daily report
                                                  # (separate from the per-failure alert webhook
                                                  # so alert channels stay skim-free)
GREEN_DIGEST="${CRONALARM_GREEN_DIGEST:-$CRONALARM_DIR/green-digest.jsonl}"
GHA_STATE_FILE="${CRONALARM_GHA_STATE_FILE:-}"    # empty = GitHub Actions section skipped
WARN_DIR="${CRONALARM_WARN_DIR:-$CRONALARM_DIR/warnings}"  # jobs append non-critical warnings to $WARN_DIR/YYYY-MM-DD.log; surfaced daily (v2.3)
REVERIFY_MAP="${CRONALARM_REVERIFY_MAP:-$CRONALARM_DIR/reverify.map}"
# cd+pwd, not `readlink -f`: BSD readlink has no -f, and the helper is
# installed (or symlinked) alongside this script in both supported layouts.
MISSED_HELPER="${CRONALARM_MISSED_HELPER:-$(cd "$(dirname "$0")" && pwd)/cronalarm-missed-runs.py}"

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
# v1.9 (2026-08-23, snag-daily-report-republishes-stale-alarm, Opie #2871):
# a once-daily job that failed at 04:30 was printed at 23:00 as "STILL FAIL
# at report time" — a true statement about the log that makes a false claim
# about the world. An alarm's state and the world's state are coupled ONLY
# at the instant of the check; anything that republishes an alarm without
# re-checking inherits that decoupling. Two fixes, both about honesty:
#   1. RE-VERIFY the jobs it is safe to re-run (read-only monitors, listed
#      in the reverify map) immediately before composing, and name when it
#      was done. A re-verified pass clears the banner; it never erases the
#      day (worst case 🟡 RECOVERED — 🟢 still requires zero failures all day).
#   2. Everything else gets its STALENESS NAMED — "NOT re-checked, 18h29m
#      stale" — so a reader can tell "red now" from "red this morning and
#      fixed since". A re-verify that cannot run degrades to that same
#      label, never to green.
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
        for (n in bad)
            printf "%s\t%d\t%s\t%s\t%d\n", n, bad[n], lastbad[n], last[n], oksince[n]
    }' "$LOG_FILE")

# Read-only re-verify allowlist, read from $REVERIFY_MAP — one line per
# job: job name, a TAB, then the command to run (tab-separated because job
# names contain spaces; # comments and blank lines ignored). A job belongs
# there ONLY if re-running it cannot change anything: no writes, no
# deploys, no backups, no spend, no notifications of its own. The report
# is a READER, not an actor — anything that auto-heals is deliberately
# absent. No map file (the default) = nothing is re-verified and every
# red keeps its honest stale label.
reverify_cmd() {
    [ -f "$REVERIFY_MAP" ] || { printf ''; return; }
    awk -F'\t' -v job="$1" \
        '$0 !~ /^[[:space:]]*(#|$)/ && $1 == job { print $2; exit }' \
        "$REVERIFY_MAP"
}

# cronalarm kills this job at its timeout and the report still has its
# delivery to make, so re-verification gets a hard shared budget. Jobs
# past the budget keep the stale label — the honest fallback, never green.
REVERIFY_BUDGET=90
REVERIFY_MAX=60

NOW_MIN=$(( 10#$(date '+%H') * 60 + 10#$(date '+%M') ))
age_of() {   # HH:MM (today) -> "18h29m" since it
    _h=${1%%:*}; _m=${1##*:}
    _age=$(( NOW_MIN - (10#${_h:-0} * 60 + 10#${_m:-0}) ))
    [ "$_age" -lt 0 ] && _age=$(( _age + 1440 ))
    printf '%dh%02dm' $(( _age / 60 )) $(( _age % 60 ))
}

STILL_FAILING=0
JOB_LINES=""
add_line() { JOB_LINES="${JOB_LINES}  - $1
"; }

while IFS=$'\t' read -r JN JCNT JLASTBAD JSTATE JOKSINCE; do
    [ -n "$JN" ] || continue

    if [ "$JSTATE" = "OK" ]; then
        add_line "${JN} ×${JCNT} — last bad ${JLASTBAD} · recovered (${JOKSINCE} OK since)"
        continue
    fi

    RV_CMD=$(reverify_cmd "$JN")
    if [ -z "$RV_CMD" ] || [ "$REVERIFY_BUDGET" -le 0 ]; then
        # Not mapped, or out of budget. Say so, and say how old the verdict is.
        STILL_FAILING=$(( STILL_FAILING + 1 ))
        add_line "${JN} ×${JCNT} — last bad ${JLASTBAD} · ${JSTATE}, NOT re-checked ($(age_of "$JLASTBAD") stale)"
        continue
    fi

    RV_START=$(date '+%s')
    RV_AT=$(date '+%H:%M')
    # </dev/null is load-bearing: the job list is fed to this loop on stdin,
    # and a re-verify that reads stdin (e.g. one that shells out to ssh,
    # which drains it) swallows every remaining job. First run of this
    # code printed 1 of 3 failing jobs for exactly that reason.
    # bash -c, so a map entry may be a command with arguments, exactly as
    # documented — a bare executable path still works. An unusable entry
    # surfaces as rc=126/127 below, never as a silent stale label.
    timeout "$REVERIFY_MAX" bash -c "$RV_CMD" >/dev/null 2>&1 </dev/null
    RV_RC=$?
    REVERIFY_BUDGET=$(( REVERIFY_BUDGET - ( $(date '+%s') - RV_START ) ))

    case "$RV_RC" in
        0)
            # Genuinely fixed since the failing run. The day keeps its reds.
            add_line "${JN} ×${JCNT} — last bad ${JLASTBAD} · RE-VERIFIED GREEN at ${RV_AT} (fixed since)"
            ;;
        124|125|126|127)
            # The re-verify itself failed to run. That is not evidence of
            # health — hold the red and name the gap (degrade-to-raw).
            STILL_FAILING=$(( STILL_FAILING + 1 ))
            add_line "${JN} ×${JCNT} — last bad ${JLASTBAD} · ${JSTATE}, re-verify COULD NOT RUN at ${RV_AT} (rc=${RV_RC}) — verdict $(age_of "$JLASTBAD") stale"
            ;;
        *)
            STILL_FAILING=$(( STILL_FAILING + 1 ))
            add_line "${JN} ×${JCNT} — last bad ${JLASTBAD} · RE-VERIFIED STILL RED at ${RV_AT} (rc=${RV_RC})"
            ;;
    esac
done <<EOF
$JOB_STATE
EOF

# Fail RED, not amber: if awk died and produced nothing, "recovered" must
# not be inferred from absence of evidence — treat every failure as still
# red and say the state is unknown. (Reviewer catch, 2026-08-19.)
if [ -z "$JOB_LINES" ] && [ $(( FAILED + TIMEOUTS )) -gt 0 ]; then
    STILL_FAILING=$(( FAILED + TIMEOUTS ))
    JOB_LINES="  - per-job state UNAVAILABLE — the job-state pass produced nothing; every failure held red"
fi
JOB_LINES=$(printf '%s\n' "$JOB_LINES" | grep . | sort)

# ── MISSED RUNS (v2.0, 2026-08-25, Opie #2938) ───────────────────────
# Every counter above reads the log, so all of them answer "how did the
# runs that HAPPENED turn out?". None could ask "did the run happen at
# all?". On 08-24 cron.service stopped 96 seconds before a nightly job's
# slot and the slot evaporated — no FAIL, no exit code, no line, and the
# day still reported clean. A schedule of once-daily jobs turns every
# swallowed slot into a full-day hole.
#
# The helper derives expected slots from the LIVE crontab (never a hand
# list, which would drift into its own silent failure) and reports slots
# with no START. It is a reader: it never triggers, backfills or
# reschedules anything — detection is the fix; catch-up is out of scope.
#
# A helper that cannot run must NOT read as zero missed: absence of evidence
# is the exact defect being fixed here. It degrades to UNKNOWN and blocks
# green — and its stderr is kept and shown, because "helper rc=1" with the
# traceback discarded is undiagnosable.
MISSED_ERRF=$(mktemp)
MISSED_JSON=$(CRONALARM_DIR="$CRONALARM_DIR" \
    python3 "$MISSED_HELPER" --date "$DATE_TAG" --json 2>"$MISSED_ERRF")
MISSED_RC=$?
MISSED_ERR=$(head -c 300 "$MISSED_ERRF" | tail -2 | tr '\n' ' ')
rm -f "$MISSED_ERRF"
if [ "$MISSED_RC" -ne 0 ] || [ -z "$MISSED_JSON" ]; then
    MISSED_TOTAL=0; MISSED_UNEXPLAINED=0; MISSED_DOWN=0
    EXPECTED_SLOTS=0; UNASSESSABLE=0; MISSED_LINES=""
    MISSED_STATE="UNKNOWN"
else
    # THREE traps here, all hit during test, all worth naming:
    #  1. `python3 -c` needed nested quotes inside an already-quoted shell
    #     string -> SyntaxError, EMPTY line list, counts still looked right.
    #  2. `printf ... | python3 - <<'PY'` does NOT work: the heredoc IS stdin,
    #     so the pipe is discarded and json.load reads nothing. The payload
    #     travels in the ENVIRONMENT — the same lesson already written twenty
    #     lines below about CRONREPORT_TEXT.
    #  3. A failed extraction must not read as "nothing missed". First cut set
    #     MISSED_STATE=KNOWN before checking, and a crashed parser rendered as
    #     a clean "0 missed" — rebuilding, inside the fix, the exact silence
    #     this whole change exists to remove.
    MISSED_PARSED=$(MISSED_JSON="$MISSED_JSON" python3 - <<'PY'
import json, os, sys
try:
    d = json.loads(os.environ["MISSED_JSON"])
    m = d["missed"]
    print(len(m), sum(1 for x in m if x.get("scheduler_up") is True),
          sum(1 for x in m if x.get("scheduler_up") is False),
          d["expected"], d.get("unassessable_slots", 0),
          len(d.get("unparsed_cronalarm_lines", [])))
    for x in m:
        print(f"  - {x['job']} — slot {x['slot']} [{x['schedule']}] · {x['cause']}")
except Exception as e:
    print(f"PARSE_FAILED {e}", file=sys.stderr)
    sys.exit(1)
PY
)
    if [ $? -ne 0 ] || [ -z "$MISSED_PARSED" ]; then
        MISSED_TOTAL=0; MISSED_UNEXPLAINED=0; MISSED_DOWN=0
        EXPECTED_SLOTS=0; UNASSESSABLE=0; MISSED_LINES=""
        MISSED_STATE="UNKNOWN"; MISSED_RC="parse"; MISSED_ERR="helper JSON did not parse"
    else
        read -r MISSED_TOTAL MISSED_UNEXPLAINED MISSED_DOWN EXPECTED_SLOTS UNASSESSABLE UNPARSED_CT \
            <<< "$(printf '%s' "$MISSED_PARSED" | head -1)"
        MISSED_LINES=$(printf '%s' "$MISSED_PARSED" | tail -n +2)
        MISSED_STATE="KNOWN"
    fi
fi
MISSED_TOTAL=${MISSED_TOTAL:-0}; MISSED_UNEXPLAINED=${MISSED_UNEXPLAINED:-0}
MISSED_DOWN=${MISSED_DOWN:-0}; EXPECTED_SLOTS=${EXPECTED_SLOTS:-0}
UNASSESSABLE=${UNASSESSABLE:-0}; UNPARSED_CT=${UNPARSED_CT:-0}
MISSED_RAN=$(( EXPECTED_SLOTS - MISSED_TOTAL ))

# Two SEPARATE closed identities, deliberately not merged. The started-based
# one counts every START in the log — including manual runs and jobs no longer
# in the crontab. The slot-based one counts only assessable scheduled slots.
# Forcing them into one sum would require a fudge term, and a counter that
# needs a fudge term is the thing v1.2 was written to kill.
if [ "$MISSED_STATE" = "UNKNOWN" ]; then
    MISSED_CLAUSE="; MISSED CHECK UNAVAILABLE (helper rc=${MISSED_RC}) — cannot say whether any scheduled run was skipped"
else
    # Unassessable slots are NAMED in the accounting, never silently absent:
    # "0 ran + 0 missed = 0 scheduled" with a day of unassessable slots
    # would be absence of evidence rendering as a clean report.
    MISSED_CLAUSE="; slots: ${MISSED_RAN} ran + ${MISSED_TOTAL} missed = ${EXPECTED_SLOTS} scheduled"
    [ "$UNASSESSABLE" -gt 0 ] && MISSED_CLAUSE="${MISSED_CLAUSE} (${UNASSESSABLE} slot(s) NOT assessable — schedule newer than its provable floor)"
    [ "$UNPARSED_CT" -gt 0 ] && MISSED_CLAUSE="${MISSED_CLAUSE} (${UNPARSED_CT} cronalarm crontab line(s) could not be parsed and are NOT checked)"
fi

if [ "$IN_FLIGHT" -lt 0 ] || [ "$OVER_COMPLETED" -gt 0 ] \
   || [ "$IN_FLIGHT" -ne "$IN_FLIGHT_MEASURED" ]; then
    # The counter itself is wrong. Never green.
    EMOJI="🔴"
    STATUS_WORD="COUNTER MISMATCH"
    ACCOUNTING="derived ${IN_FLIGHT} vs measured ${IN_FLIGHT_MEASURED} in flight, ${OVER_COMPLETED} over-completed — ${PASSED} passed + ${FAILED} failed + ${TIMEOUTS} timeout of ${TOTAL} started${MISSED_CLAUSE}"
elif [ "$MISSED_STATE" = "UNKNOWN" ]; then
    # Cannot assert the runs happened. Never green on an unrun check.
    EMOJI="🟡"
    STATUS_WORD="MISSED CHECK UNAVAILABLE"
    ACCOUNTING="${PASSED} passed + ${FAILED} failed + ${TIMEOUTS} timeout + ${IN_FLIGHT} in flight at report time = ${TOTAL} started${MISSED_CLAUSE}"
elif [ "$EXPECTED_SLOTS" -eq 0 ] && [ "$UNASSESSABLE" -gt 0 ]; then
    # The helper ran but could not vouch for a single slot (typically the
    # first run on a machine with no readable crontab mtime — the floor
    # arms itself and tomorrow is covered). "0 ran + 0 missed = 0
    # scheduled" must never wear green while a day of slots went unchecked.
    EMOJI="🟡"
    STATUS_WORD="MISSED CHECK NOT ARMED"
    ACCOUNTING="${PASSED} passed + ${FAILED} failed + ${TIMEOUTS} timeout + ${IN_FLIGHT} in flight at report time = ${TOTAL} started${MISSED_CLAUSE}"
elif [ "$MISSED_UNEXPLAINED" -gt 0 ]; then
    # A slot passed, the scheduler was up, and the job did not start. That is
    # a harder red than a failure: a failure at least produced an exit code.
    EMOJI="🔴"
    STATUS_WORD="MISSED RUNS"
    ACCOUNTING="${PASSED} passed + ${FAILED} failed + ${TIMEOUTS} timeout + ${IN_FLIGHT} in flight at report time = ${TOTAL} started${MISSED_CLAUSE}; ${MISSED_UNEXPLAINED} of ${MISSED_TOTAL} missed slot(s) have NO scheduler outage to explain them"
elif [ "$FAILED" -eq 0 ] && [ "$TIMEOUTS" -eq 0 ] && [ "$MISSED_TOTAL" -gt 0 ] \
     && [ "$MISSED_DOWN" -eq "$MISSED_TOTAL" ]; then
    # Missed, and every miss is accounted for by the scheduler being down.
    # Amber, not green: the runs did not happen and the reader must know.
    EMOJI="🟡"
    STATUS_WORD="MISSED (SCHEDULER DOWN)"
    ACCOUNTING="${PASSED} passed + ${FAILED} failed + ${TIMEOUTS} timeout + ${IN_FLIGHT} in flight at report time = ${TOTAL} started${MISSED_CLAUSE}; every missed slot falls in a scheduler outage"
elif [ "$FAILED" -eq 0 ] && [ "$TIMEOUTS" -eq 0 ] && [ "$MISSED_TOTAL" -gt 0 ]; then
    # Missed with the scheduler's state unknown (journal unusable, or a
    # non-systemd box). The headline must not assert an outage the
    # evidence does not show — the per-slot lines carry the detail.
    EMOJI="🟡"
    STATUS_WORD="MISSED (CAUSE UNKNOWN)"
    ACCOUNTING="${PASSED} passed + ${FAILED} failed + ${TIMEOUTS} timeout + ${IN_FLIGHT} in flight at report time = ${TOTAL} started${MISSED_CLAUSE}; scheduler state could not be determined for the missed slot(s)"
elif [ "$FAILED" -eq 0 ] && [ "$TIMEOUTS" -eq 0 ]; then
    EMOJI="🟢"
    STATUS_WORD="ALL CLEAR"
    ACCOUNTING="${PASSED} passed + ${FAILED} failed + ${TIMEOUTS} timeout + ${IN_FLIGHT} in flight at report time = ${TOTAL} started${MISSED_CLAUSE}"
elif [ "$STILL_FAILING" -eq 0 ]; then
    # Every job that failed today passed its most recent run. Amber, not
    # green: the reds happened and stay listed — this clears the banner,
    # it does not erase the day.
    EMOJI="🟡"
    STATUS_WORD="RECOVERED"
    ACCOUNTING="${PASSED} passed + ${FAILED} failed + ${TIMEOUTS} timeout + ${IN_FLIGHT} in flight at report time = ${TOTAL} started${MISSED_CLAUSE}; every failing job is green at report time (recovered on a later run, or re-verified now)"
else
    EMOJI="🔴"
    STATUS_WORD="ISSUES"
    ACCOUNTING="${PASSED} passed + ${FAILED} failed + ${TIMEOUTS} timeout + ${IN_FLIGHT} in flight at report time = ${TOTAL} started${MISSED_CLAUSE}; ${STILL_FAILING} job(s) still red at report time"
fi

# ── Warnings surface (v2.3) ──────────────────────────────────────────
# A warn-class check that prints ⚠️ and exits 0 reaches nobody: CronAlarm
# alerts on exit codes, so its warnings evaporated on green days (found in
# the 2026-08 guard-audience audit: "warn_check class reaches nobody").
# Contract: any job may APPEND lines to $WARN_DIR/YYYY-MM-DD.log; this
# report surfaces today's file. Warnings never page and never make a day
# red — but a warnings-only day is AMBER and goes to the configured
# channels, because a warning with no reader is not a warning.
WARN_FILE="$WARN_DIR/${DATE_TAG}.log"
WARN_COUNT=0
if [ -s "$WARN_FILE" ]; then
    # 2>/dev/null: an unreadable file (cross-user WARN_DIR) must read as
    # zero, not crash the arithmetic below. NOT `|| echo 0` — grep -c
    # prints its 0 before exiting 1, and that idiom re-creates the v1.1
    # "0\n0" counting bug documented above.
    WARN_COUNT=$(grep -c . "$WARN_FILE" 2>/dev/null)
    [ -n "$WARN_COUNT" ] || WARN_COUNT=0
fi
if [ "$WARN_COUNT" -gt 0 ] && [ "$STATUS_WORD" = "ALL CLEAR" ]; then
    EMOJI="🟡"
    STATUS_WORD="WARNINGS"
    ACCOUNTING="${ACCOUNTING}; ${WARN_COUNT} warning line(s), zero failures"
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

if [ "$MISSED_STATE" = "UNKNOWN" ]; then
    REPORT_DISCORD="${REPORT_DISCORD}
🟡 **MISSED-RUN CHECK DID NOT RUN** (helper rc=${MISSED_RC}${MISSED_ERR:+ · ${MISSED_ERR}}) — this report cannot say whether a scheduled job was skipped. Treat the absence of a MISSED section below as unknown, NOT as none."
    REPORT_PLAIN="${REPORT_PLAIN} Missed-run check unavailable (rc=${MISSED_RC})."
elif [ "$MISSED_TOTAL" -gt 0 ]; then
    # Named separately from failures on purpose: a missed run produced no exit
    # code, so folding it into FAILED would misreport what happened.
    REPORT_DISCORD="${REPORT_DISCORD}
⬛ **${MISSED_TOTAL} MISSED — scheduled slot(s) with no run at all** (${MISSED_UNEXPLAINED} with no scheduler outage to explain them):
${MISSED_LINES}"
    REPORT_PLAIN="${REPORT_PLAIN} ${MISSED_TOTAL} missed slots (${MISSED_UNEXPLAINED} unexplained)."
fi


# ── GitHub Actions standing state (optional, Opie #2429) ─────────────
# Enabled by pointing CRONALARM_GHA_STATE_FILE at a retention jsonl kept
# by a CI-watching job; unset (the default) skips the section. Read from
# the retention file, NOT from tonight's job output: cronalarm keeps
# output only on failure, so on a night where every red is acknowledged
# the job exits OK and the silenced reds would vanish from the one report
# with a reader. An ack must be visible while it lasts. A stale
# observation is named stale, never quoted as current (a stale literal
# and a live read look identical).
if [ -n "$GHA_STATE_FILE" ]; then
    GHA_LINE=$(GHA_STATE_FILE="$GHA_STATE_FILE" \
        CRONALARM_GHA_WATCH_HHMM="${CRONALARM_GHA_WATCH_HHMM:-}" \
        python3 - 2>&1 <<'PY'
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
    # CRONALARM_GHA_WATCH_HHMM in ~/.cronalarm/env, which must match the
    # crontab entry for the watching job. Unset = no anchor to judge
    # freshness against, so the entry is quoted WITH its timestamp — a
    # stale literal and a live read must never look identical.
    hhmm = os.environ.get("CRONALARM_GHA_WATCH_HHMM", "")
    summary = (f"{d.get('workflows', '?')} workflows: "
               f"{len(d.get('red', []))} red, "
               f"{len(d.get('acknowledged', []))} acknowledged")
    if not hhmm:
        print(f"{summary} — as of {d['at'][:16]} (no schedule configured "
              f"to judge freshness; set CRONALARM_GHA_WATCH_HHMM)")
        for r in d.get("acknowledged", []):
            print(f"  ACK {r}")
    else:
        h, m = (int(x) for x in hhmm.split(":"))
        now_local = datetime.now().astimezone()
        anchor = now_local.replace(hour=h, minute=m, second=0, microsecond=0)
        if now_local < anchor:
            anchor -= timedelta(days=1)
        if at < anchor:
            print(f"STALE — no entry from the {anchor:%m-%d} {hhmm} run — "
                  f"newest is {d['at'][:16]}Z")
        else:
            print(summary)
            for r in d.get("acknowledged", []):
                print(f"  ACK {r}")
except Exception as e:
    print(f"unreadable ({e})")
PY
)
    REPORT_DISCORD="${REPORT_DISCORD}
**GitHub Actions** [$(basename "$GHA_STATE_FILE")]: ${GHA_LINE}"
    REPORT_PLAIN="${REPORT_PLAIN} GHA: $(printf '%s' "$GHA_LINE" | head -1)."
fi

# Warnings section LAST on purpose: the Discord sender truncates at 2000
# chars from the END, so whatever sits at the tail is what a heavy day
# cuts. Warnings are the lowest-severity section — they must be the first
# thing truncated, never the GHA standing state above (whose own contract
# is "an ack must be visible while it lasts"). The inbox copy below
# always carries the full file.
if [ "$WARN_COUNT" -gt 0 ]; then
    # grep . on BOTH sides: WARN_COUNT counts non-blank lines, so the
    # display must select the same set — a raw tail on a file with blank
    # lines would silently render fewer warnings than the cap admits.
    # The file is in append order (writers that dedup write first-seen
    # first); the cap keeps the tail and NAMES the omission + full path,
    # so nothing is silently lost either way.
    WARN_LINES=$(grep . "$WARN_FILE" | tail -n 30)
    if [ "$WARN_COUNT" -gt 30 ]; then
        WARN_LINES="[... $((WARN_COUNT - 30)) earlier line(s) omitted — full file: ${WARN_FILE}]
${WARN_LINES}"
    fi
    REPORT_DISCORD="${REPORT_DISCORD}
⚠️ **${WARN_COUNT} warning line(s)** — non-critical by the emitting job's own ruling, surfaced here because warnings never page:
${WARN_LINES}"
    REPORT_PLAIN="${REPORT_PLAIN} ${WARN_COUNT} warning line(s)."
fi

echo "$REPORT_DISCORD"

# ── Delivery ─────────────────────────────────────────────────────────
# TWO DEFECTS WERE FIXED HERE in 1.1, and both had to be — otherwise the
# same bug gets rebuilt in every new pipe:
#
#   1. The old Discord POST sent NO User-Agent. Discord/Cloudflare 403s
#      urllib's default agent. The sibling wrapper script has carried
#      the correct header (and a comment explaining why) the whole time,
#      so the fix sat twenty lines away in the next file.
#   2. The failure was caught, printed to stderr, and the script carried
#      on to exit 0 — so CronAlarm logged "OK: Daily Report (0s)" every
#      night while ZERO reports landed between 2026-02-13 and 2026-07-25.
#
# Net effect: this job's entire purpose was to say "everything is fine",
# and it was itself broken for five months and said nothing. Its silence
# was indistinguishable from the all-clear it was meant to send. That is
# why every delivery failure below exits 1: this job screaming about
# itself is the only defense it has.
SEND_FAILED=0

# v1.7 (2026-08-22, Opie #2835): a green night does not address an inbox.
# Daily ALL CLEARs sent to a person buried their real mail (488 unread,
# near-all green). ALL CLEAR -> one line appended to the green digest
# (queryable on demand; the full report is already in
# $INBOX_DIR/CRON-REPORT-<date>.md). Non-green days still go to the
# configured channels — those need a reader. A failed digest append exits
# 1 exactly like a failed POST: this job's five-month silent death is why
# delivery failures are never quiet here.
if [ "$STATUS_WORD" = "ALL CLEAR" ]; then
CRONREPORT_TEXT="$REPORT_DISCORD" GREEN_DIGEST="$GREEN_DIGEST" \
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
path = os.path.expanduser(os.environ["GREEN_DIGEST"])
try:
    with open(path, "a") as f:
        f.write(line + "\n")
except OSError as e:
    print(f"green digest append FAILED: {e}", file=sys.stderr)
    sys.exit(1)
print(f"green -> digest: {path}")
PY
else
    DELIVERED=0

    if [ -n "$BUS_URL" ]; then
        DELIVERED=1
# The report travels in the environment, not on stdin: stdin is already
# carrying the Python script itself via the heredoc.
CRONREPORT_TEXT="$REPORT_DISCORD" \
python3 - "$BUS_URL" "$BUS_TO" "$STATUS_WORD" "$DATE_TAG" "$HOSTNAME" "$TOTAL" "$PASSED" "$FAILED" "$TIMEOUTS" "$IN_FLIGHT" "$STILL_FAILING" <<'PY' || SEND_FAILED=1
import json, os, sys, urllib.request, urllib.error

bus, bus_to, status, date_tag, host, total, passed, failed, timeouts, in_flight, still_failing = sys.argv[1:12]
report = os.environ.get("CRONREPORT_TEXT", "")

payload = json.dumps({
    # from: cron-report, a machine identity: automated traffic must not
    # wear a person's or an agent's name.
    "mesh_version": "0.5", "from": "cron-report", "to": bus_to,
    "subject": f"cronalarm-daily-report-{date_tag}-{status.lower().replace(' ', '-')}",
    "body": {
        "host": host, "date": date_tag, "status": status,
        "total": int(total), "passed": int(passed),
        "failed": int(failed), "timeouts": int(timeouts),
        "in_flight_at_report_time": int(in_flight),
        "still_failing_at_report_time": int(still_failing),
        "accounting": f"{passed}+{failed}+{timeouts}+{in_flight}={total}",
        "report": report,
        "note": "Sent because status is not ALL CLEAR; green days append "
                "to the local digest instead of addressing a reader.",
    },
}).encode()

req = urllib.request.Request(bus, data=payload, method="POST", headers={
    "Content-Type": "application/json",
    # Never omit this again. See the comment block above.
    "User-Agent": "CronAlarmReport/2.1",
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

    if [ -n "$REPORT_WEBHOOK" ]; then
        DELIVERED=1
CRONREPORT_TEXT="$REPORT_DISCORD" \
python3 - "$REPORT_WEBHOOK" <<'PY' || SEND_FAILED=1
import json, os, sys, urllib.request, urllib.error

msg = json.dumps({"content": os.environ.get("CRONREPORT_TEXT", "")[:2000]})
req = urllib.request.Request(sys.argv[1], data=msg.encode(), method="POST", headers={
    "Content-Type": "application/json",
    # Discord/Cloudflare 403s urllib's default user-agent — must send a real one
    "User-Agent": "CronAlarmReport/2.1",
})
try:
    with urllib.request.urlopen(req, timeout=15) as r:
        if r.status >= 300:
            print(f"report webhook rejected: HTTP {r.status}", file=sys.stderr)
            sys.exit(1)
except (urllib.error.URLError, OSError) as e:
    print(f"report webhook FAILED: {e}", file=sys.stderr)
    sys.exit(1)
PY
    fi

    if [ "$DELIVERED" -eq 0 ]; then
        echo "no delivery channel configured (CRONALARM_BUS_URL / CRONALARM_REPORT_WEBHOOK unset) — report written to inbox only"
    fi
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
    echo "- **Missed slots:** $MISSED_TOTAL (${MISSED_UNEXPLAINED} unexplained, ${MISSED_DOWN} in scheduler outages, check state: $MISSED_STATE)"
    echo "- **Scheduled slots assessed:** $EXPECTED_SLOTS (${UNASSESSABLE} not assessable)"
    echo "- **Accounting:** $ACCOUNTING"
    if [ "$WARN_COUNT" -gt 0 ]; then
        # The inbox is the durability anchor — full warnings file, no cap.
        # Without this, a warnings-only day on an inbox-only install would
        # flip amber yet persist the warning text NOWHERE (v2.3 review).
        echo ""
        echo "## Warnings (${WARN_COUNT} non-blank line(s), non-critical)"
        echo '```'
        cat "$WARN_FILE" 2>/dev/null || echo "[warnings file unreadable: $WARN_FILE]"
        echo '```'
    fi
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
    echo "DAILY REPORT NOT DELIVERED — a configured channel failed (inbox copy written to $REPORT_FILE)" >&2
    exit 1
fi
exit 0
