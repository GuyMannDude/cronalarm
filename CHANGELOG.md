# CronAlarm Changelog

## 2.4 — 2026-08-27 — A report script with no argument guard treats `--help` as "deliver now"; and a verdict without its coverage reads as full coverage

**Problem 1.** `cronalarm-report.sh` ignored unknown arguments, so *any*
invocation — including an exploratory `--help` — composed the full daily
report and delivered it to every configured channel. On 2026-08-27 a
hand `--help` POSTed a stray daily report to the bus 22.5 hours before
the real one. A script whose every run has side effects must refuse
invocations it does not recognize, before doing anything at all.

**Fix 1.** Argument guard first thing in the script: `-h`/`--help`
prints usage and exits 0; any unrecognized argument prints usage and
exits 2 — in both cases nothing is composed and nothing is sent. New
`--dry-run` composes and prints the full report, then stops before
every side effect (no digest append, no bus POST, no webhook, no inbox
file) — hand-runs for inspection are legitimate and now have a lane.

**Problem 2.** The missed-run check reports how many scheduled slots it
could actually assess (on a young schedule floor, 157 of 877), but the
ratio sat in a mid-report accounting clause while the headline said
"0 missed" — a skimming reader concludes *nothing was missed* when the
true claim is *nothing was missed among the 18% we can prove*.

**Fix 2.** The coverage ratio moves into the Status headline itself —
`ALL CLEAR [missed-run check covered 157 of 877 slots, 17%]` — on every
report where the check ran. A verdict travels with its scope; when the
check did not run, the headline already says so and no coverage number
is invented.

## 2.3 — 2026-08-26 — A warning that only prints and exits 0 reaches nobody

**Problem.** The example monitor's `warn_check` class printed `⚠️` and
exited 0 — and CronAlarm alerts on exit codes, so on an otherwise-green
day those warnings evaporated: no alert (correct — they are
non-critical), but also no reader, ever. A 2026-08 guard-audience audit
("who is told when this fires?") found the entire class delivered to
nobody. Detection was never the problem; delivery was.

**Fix.** A warnings surface with a file contract: any job may append
lines to `$CRONALARM_WARN_DIR/YYYY-MM-DD.log` (default
`~/.cronalarm/warnings/`). The daily report shows today's warning lines
(tail-biased cap of 30, omissions counted and named — same
which-end-matters rule as v2.2). Warnings never page and never make a
day red, but a warnings-only day is now AMBER (`WARNINGS`) and goes to
the configured report channels instead of the silent green digest — a
warning with no reader is not a warning. The example monitor persists
its `warn_check` misses there, dedup'd per day so a 15-minute cadence
cannot write 96 copies of one outage.

## 2.2 — 2026-08-25 — A failing job's captured output was cut from the wrong end, so the error that caused the failure was never written

**Problem.** The wrapper captured the last 50 lines of a failed job's
output (tail-biased, correct) and then wrote only the *first* 500
characters of that capture to the log — and the first 1500 to Discord,
the first 500 to the inbox drop. Progress output is chronological and
the error comes last, so the head-biased cap preferentially discarded
the diagnosis and preserved the preamble: the more a job explained
itself, the less of its failure survived. Two real 2026-08-24 failures
left no recoverable exit reason — the evidence was never written, so no
later investigation could recover it. The truncation was also silent (a
capped log looks like a log), and an empty capture wrote an empty
`Output:` line indistinguishable from a job that was never captured.

**Fix.** All three sinks now keep the *end* of the capture via a shared
`tail_cap` helper: truncation is marked with how many leading characters
were dropped, and an empty capture states `(no output)` explicitly. The
Discord output share drops to 1200 characters to leave header room,
and the 2000-character hard-limit gate itself is now tail-preserving
(head + `[...]` + tail) instead of a plain head cut — a long command
line can no longer push the diagnosis past the final gate
(review catch, 2026-08-25).

## 2.1 — 2026-08-25 — The repo and its reference deployment had drifted into two different products

**Problem.** The repository copy of the report script was three releases
behind the deployment it was written against — and what *had* been committed
carried that one deployment's wiring as product code: a hardcoded report
recipient, a digest path inside another system's directory, a CI-watch
section reading a state file no fresh install has, and a Discord webhook
that was read but never used. A fresh install's daily report delivered
nowhere. Separately, the installer referenced optional scripts that don't
exist in the repo, rewrote an existing config file on every re-run (losing
any setting it didn't know about), and its own suggested failure test —
`cronalarm "Test Fail" bash -c "exit 1"` — could never fail: the wrapper
joins its arguments with spaces and re-parses them, which strips the inner
quotes and turns the command into a successful bare `exit`.

**Fix.** Every site-specific value in the report is now configuration with
a local-or-empty default: `CRONALARM_BUS_URL` / `CRONALARM_BUS_TO` (JSON
POST endpoint + recipient), `CRONALARM_REPORT_WEBHOOK` (a Discord webhook
for non-green daily reports, deliberately separate from the failure-alert
webhook so alert channels stay skim-free), `CRONALARM_GREEN_DIGEST`
(where ALL CLEAR days append), `CRONALARM_GHA_STATE_FILE` (CI section,
unset = skipped), `CRONALARM_REVERIFY_MAP` (the 1.9 re-verify allowlist,
moved from a hardcoded list to `~/.cronalarm/reverify.map`), and
`CRONALARM_MISSED_HELPER` (defaults to the copy installed next to the
report script). With nothing configured the report degrades to inbox-only
— never a POST at an empty string. `cronalarm-missed-runs.py` now ships
in the repo. The wrapper is renamed `sparks-cron.sh` → `cronalarm.sh`
(products carry role names, not their maker's project names) and both it
and the report self-source `~/.cronalarm/env`, so a manual run behaves
exactly like a cron run. The installer keeps an existing env file
untouched on re-run, installs the example monitor from `examples/`, and
recommends `false` as the failure test — one that can actually fail. The
example monitor gains a retry-once-after-20s pause before screaming, so
transient blips stop crying wolf.

**Adversarial review of this release then found — and this release fixes —
five ways the missed-run detector itself could lie.** (1) On a machine
where no crontab mtime is readable (a stock Debian `--yes` install), the
assessability floor fell back to "now", every slot was silently dropped,
and the report went green over a day of unchecked slots — absence of
evidence rendering as a clean report, rebuilt inside the very feature
built to kill it. The detector now keeps its own crontab seen-record
(hash + first-seen time) as the floor of last resort, the report names
unassessable slots in its accounting line, and a day where *nothing* was
assessable goes 🟡 MISSED CHECK NOT ARMED, never green. (2) A crontab
line using Vixie names (`MON`, `JAN`) or `@daily` crashed the parser and
turned every future report amber; names and @-macros now parse, each
line parses inside its own guard so one bad entry can't sink the rest,
and lines that still can't be parsed are counted and shown — never
silently unchecked. (3) `journalctl` for a wrong or absent unit exits 0
with no entries, which read as "scheduler up all day" and made every
reboot miss a false UNEXPLAINED red; the unit is now verified loaded
first (and configurable: `CRONALARM_CRON_UNIT`, for cronie's
`crond.service`), with anything else honestly reported as scheduler
state unknown — including a new 🟡 MISSED (CAUSE UNKNOWN) status so the
headline never asserts an outage the evidence doesn't show. (4) The
helper's stderr was discarded, making failures undiagnosable; it now
travels into the report beside the exit code. (5) A re-verify map entry
with arguments failed a `-x` test and silently degraded to the stale
label; entries now run as documented — commands, not just bare paths.

*Releases 1.7, 1.9 and 2.0 below first ran in the reference deployment;
2.1 is the first repository release that contains them. There is no 1.8 —
the numbering skipped it.*

## 2.0 — 2026-08-25 — A run that never happened left no trace at all

**Problem.** Every counter in the daily report reads the day's log, so all
of them answer "how did the runs that happened turn out?" — none could ask
"did the run happen at all?". When the scheduler was down for 96 seconds
across a job's only daily slot, the slot simply evaporated: no FAIL, no
exit code, no log line. A day with a swallowed run was indistinguishable
from a day with nothing to report, and for once-daily jobs that's a
full-day hole.

**Fix.** `cronalarm-missed-runs.py` derives every expected slot from the
LIVE crontab (never a hand-maintained list, which would drift into its own
silent failure), matches slots against START lines with a 120s tolerance,
and checks the scheduler's own service journal to split misses into
"scheduler was down" vs "scheduler was up — unexplained". The report gains
a slot accounting line (`ran + missed = scheduled`) and two new statuses:
🔴 MISSED RUNS (a slot passed with the scheduler up — harder than a
failure, which at least produced an exit code) and 🟡 MISSED (SCHEDULER
DOWN). Expectations are only asserted for slots after the crontab's own
mtime, so adding a job today can never fabricate this morning's miss. A
helper that cannot run degrades to 🟡 MISSED CHECK UNAVAILABLE and blocks
green — absence of evidence is the exact defect this release fixes. The
helper is a reader: it never triggers, backfills or reschedules anything.

## 1.9 — 2026-08-23 — The 11 PM report republished a 4:30 AM alarm as if it were news

**Problem.** A once-daily job that failed at 04:30 was printed at 23:00 as
"STILL FAIL at report time" — a true statement about the log that makes a
false claim about the world. An alarm's state and the world's state are
coupled only at the instant of the check; anything that republishes an
alarm without re-checking inherits that decoupling.

**Fix.** Two halves, both about honesty. (1) Jobs that are safe to re-run
— read-only monitors on an explicit allowlist — are RE-VERIFIED immediately
before the report composes, with the time named: a pass renders as
`RE-VERIFIED GREEN at 22:59 (fixed since)` and clears the banner without
erasing the day (worst case 🟡 RECOVERED; 🟢 still requires zero failures
all day). (2) Everything else gets its staleness named — `STILL FAIL, NOT
re-checked (18h29m stale)` — so a reader can tell "red now" from "red this
morning and fixed since". A re-verify that cannot run holds the red and
names the gap; it never degrades to green. Re-verification runs under a
hard shared time budget so the report itself can't blow its own timeout.

## 1.7 — 2026-08-22 — A green night does not address an inbox

**Problem.** The daily report delivered every night, including ALL CLEAR
nights, to a channel with a reader on the other end. Hundreds of green
ticks buried the real mail — an inbox that is almost all "nothing
happened" trains its reader to skim, which is the exact reflex an alert
route exists to avoid.

**Fix.** ALL CLEAR nights append one JSON line to a local green digest
(queryable on demand; the full report is already written to the inbox
directory either way). Non-green nights — RECOVERED, ISSUES, COUNTER
MISMATCH — still deliver to the configured channels: those need a reader.
A failed digest append exits 1 exactly like a failed delivery; this job
once died silently for five months, so delivery failures are never quiet.

## 1.6 — 2026-08-19 — The daily report answered "did anything break today?" when the reader asks "is anything broken now?"

**Problem.** Two defects in the daily report, both found on the same real day
(2026-08-18). First, a calendar-day sum has no concept of "fixed since": both
of the day's failure causes were repaired by mid-afternoon and the machine was
clean for ~8 hours, yet the 23:00 report still said ISSUES — an alarm that is
correct and useless trains the reader to skim past it. Second, the failure
list kept the first 10 *occurrences*: all ten printed were the same repeated
job, and the day's only singleton failure — a different job with a different
owner — fell below the cut. Frequency is not importance.

**Fix.** A per-job pass tags every failing job with its last completion of
the day. Every failure cleared by a later pass → new 🟡 `RECOVERED` status:
amber, never green, with counts and the full per-job list preserved (clearing
the banner is not erasing the day). A fail→pass→fail job stays red — only
final state counts. Any job still red → `ISSUES` plus `N job(s) still red at
report time`. The occurrence-capped listing is replaced by one line per
distinct failing job with a ×count and its recovery state
(`Sentinel ×26 — last bad 17:45 · recovered (1 OK since)`), never truncated —
a singleton can no longer be hidden by a noisy neighbor. If the per-job pass
itself produces nothing, every failure is treated as still red: "recovered"
is never inferred from absence of evidence. `COUNTER MISMATCH` and
`ALL CLEAR` behavior unchanged.

## 1.5 — 2026-08-17 — A timeout counted as two completions, and the balance line could never say so

**Problem.** A timed-out job wrote both `FAIL:` and `TIMEOUT:` lines, so the
daily report counted one job as two completions — and because in-flight was
the derived remainder (`total - completions`), the error was silently
absorbed there and the accounting line still balanced. A reconciliation that
balances by construction is reassurance, not a check. (Found via Opie #2338;
on 2026-08-10 the report said 5 in flight when the true number was 6.)

**Fix.** Two halves, either alone insufficient:
1. The wrapper writes ONE completion line per job — `TIMEOUT:` for exit 124,
   `FAIL:` otherwise. Timeouts get their own name listing in the report so
   they stay visible without a FAIL line.
2. The report now measures in-flight independently (per job name: starts
   minus completions) and compares it to the derived remainder. Disagreement
   or an over-completed job forces `COUNTER MISMATCH`, never green — so the
   next double-log class, whatever it is, surfaces instead of vanishing.
   Counts are also anchored to the log timestamp format so job output
   containing "FAIL:" can't inflate them.

Gate honored (Opie #2338): a fixture with a deliberate double-count must
make the accounting FAIL — verified, along with the healthy-log pass case.

## 1.4 — 2026-08-17 — Repo catches up with the live Telegram removal

**Problem.** The live install dropped the Telegram channel on 2026-07-25, but
the repo never got the matching sweep — so `install.sh` would resurrect the
channel on a reinstall, and the docs (README, robot.info, llms.txt) still
advertised it. The robot-install files also still carried config plumbing for
the SMS channel removed in 1.2: dead vars the wrapper hasn't read since July,
advertising channels that don't exist.

**Fix.** Telegram removed from the wrapper, installer, docs, and robot
manifests, matching the 1.2 SMS sweep; the SMS leftovers in
`robot.install`/`robot-install.sh` went in the same pass. Channels are now
Discord webhook + local file drop, and the repo matches the live install.
Also removed `ALERT_PLAIN`, a Telegram-era variable nothing consumed.

## 1.3 — 2026-08-01 — Alert-failure WARN branches were unreachable

**Problem.** Both the Discord and Telegram senders caught every delivery
exception, printed to stderr (which cron swallows), and exited 0 — so the
`WARN: <channel> alert failed` log lines after them could NEVER fire. A
failing webhook left a clean log: silent alert loss with no trace. Found by
firing the path against a deliberately invalid webhook rather than reading
the code — the log showed no WARN.

**Fix.** The embedded python now exits non-zero on delivery failure, guarded
with `|| <CHANNEL>_SEND_FAILED=1` on the command (a bare exit would abort the
whole script under `set -euo pipefail` and skip the WARN *and* everything
after it — the naive fix made the failure path worse, which only a fired
test could see). The WARN branches now trigger on the flag. Both channels
verified by firing against an invalid URL: WARN lands, later channels and
the local file drop still run.

## 1.2 — 2026-07-07 — Remove Textbelt SMS channel

**Problem.** Textbelt disabled free-tier SMS for US numbers, and the paid tier
is a redundant cost next to a working Discord webhook (fixed in 1.1). Decision
via bus ping #1111: drop SMS entirely rather than maintain a dead channel.

**Removed.** All Textbelt SMS code and docs: `CRONALARM_SMS_PHONE` /
`CRONALARM_SMS_KEY` env vars, the SMS send path in the wrapper and the daily
report, the installer's SMS prompts, and SMS references in README / robot.info
/ llms.txt. Remaining channels: Discord webhook, Telegram bot, local file drop
(always on). Existing installs: the wrapper simply ignores leftover SMS vars
in `~/.cronalarm/env`; delete them at leisure.

## 1.1 — 2026-07-07 — Fix mute alerting (two bugs); add CRONALARM_MENTION

**Problem 1 — env not exported.** The installer wrote `~/.cronalarm/env` with
plain (unexported) assignments. Cron invokes `source env && cronalarm ...` —
sourcing sets shell variables in the cron shell, but the wrapper runs as a
child process and inherits none of them. Result: Discord/SMS/Telegram alerting
was silently dead on every install; only the local log + inbox file drop
worked. Discovered 2026-07-07 when a job that had been failing nightly for 13
nights turned out to have never sent a single alert.

**Fix.** `install.sh` now writes `export` on every env var. Existing installs:
`sed -i 's/^CRONALARM_/export CRONALARM_/' ~/.cronalarm/env`.

**Problem 2 — Discord 403.** Even with the env fixed, the Discord POST was
rejected: Discord/Cloudflare returns 403 Forbidden for Python urllib's default
`User-Agent`. The wrapper now sends `User-Agent: CronAlarm/1.1`. (The webhook
itself was valid — GET returned 200 — only the POST was blocked.)

**Also noted.** Textbelt has disabled free-tier SMS for US numbers ("free SMS
are disabled for this country due to abuse") — the free `textbelt` key no
longer works; SMS requires a paid key.

**Added.** `CRONALARM_MENTION` (optional, default empty): a mention string
(e.g. `@here` or `<@USER_ID>`) prepended to Discord failure alerts. Combined
with Discord's per-channel "Only @mentions" notification setting, failures
audibly ping while success/info posts in the same channel stay silent —
failure and success get distinguishable sounds.

## 1.0 — 2026-07-05 — Version anchor (backfill)

CronAlarm predates the fleet changelog rule; this entry anchors the current
shipped state as the truth source for the robot.info drift guard
(tests/check-manifest.sh): pure-bash cron wrapper (sparks-cron.sh) with
multi-channel failure/timeout alerts (Discord webhook, SMS, Telegram),
daily 11 PM summary (cronalarm-report.sh), installer (install.sh), no
daemon and no runtime beyond stock Linux. From here on: every version
bump gets an entry BEFORE robot.info moves.
