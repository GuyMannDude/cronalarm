# CronAlarm Changelog

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
