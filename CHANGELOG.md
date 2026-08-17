# CronAlarm Changelog

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
