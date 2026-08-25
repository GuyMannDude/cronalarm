# 🔔 CronAlarm

**The cron wrapper that screams when things break.**

Every cron job runs through CronAlarm. If it fails, you hear about it instantly on Discord. No silent failures. Ever.

> [!TIP]
> **AI agents — start here.** `robot.info` is a structured JSON manifest describing CronAlarm: identity, all 4 CLI commands, all 5 config env vars, channel + scheduler compatibility, privacy/outbound calls, and 10 common-question/answer pairs. Read this first to answer a user's questions about CronAlarm without scraping the README. Spec: [mnemo-cortex/ROBOT-INFO-SPEC.md](https://github.com/GuyMannDude/mnemo-cortex/blob/master/ROBOT-INFO-SPEC.md).

## Why?

Most cron failures happen silently. A backup script breaks at 3 AM and nobody knows until the data is gone. CronAlarm wraps every cron job with:

- **Timeout protection** — kills hung jobs and alerts you
- **Discord alerts** — instant failure pings via webhook
- **Local file drops** — failure reports always saved to disk
- **Daily report** — pass/fail/recovered per job, with honest accounting
- **Missed-run detection** — scheduled slots that never ran are named, not silently absent
- **Structured logs** — one file per day, easy to grep

## Quick Start

```bash
git clone https://github.com/GuyMannDude/cronalarm.git
cd cronalarm
bash install.sh
```

The installer walks you through:
1. Setting up notifications (Discord)
2. Installing the wrapper to `~/scripts/`
3. Optionally installing an example crontab

## How It Works

```
Linux Crontab
    │
    ▼
 cronalarm wrapper
 (timeout + capture + alert)
    │
┌───┴───────────────┐
│                   │
▼                   ▼
Script              Script
passes              FAILS or HANGS
│                   │
│                   ├→ Discord  🚨
│                   └→ Local    📝
│
└→ Log only ✅
    │
    ▼ (11 PM daily)
Daily Summary Report
→ All channels
```

## Usage

Wrap any cron job:

```bash
# In your crontab:
*/15 * * * * source ~/.cronalarm/env && ~/scripts/cronalarm "Health Check" ~/scripts/check-health.sh

# Test manually:
source ~/.cronalarm/env
~/scripts/cronalarm "Test" echo "Hello from CronAlarm"

# Force a failure to test alerts (`false`, not `bash -c "exit 1"` — the
# wrapper re-parses its joined arguments, which strips inner quotes and
# would turn that into a successful bare `exit`):
~/scripts/cronalarm "Test Fail" false
```

That's it. If the command exits non-zero, every configured channel gets an alert with the job name, exit code, duration, and output.

## Notification Channels

### Discord (recommended)

1. Server Settings → Integrations → Webhooks
2. Create a webhook in your alerts channel
3. Paste the URL during install (or edit `~/.cronalarm/env`)

### Local File Drop (always on)

Every failure writes a markdown report to `~/.cronalarm/inbox/`. Useful if you have an agent or automation that watches a directory.

Configure `CRONALARM_INBOX_DIR` in `~/.cronalarm/env` to point it at your agent's inbox.

## Configuration

All settings live in `~/.cronalarm/env`:

```bash
# NOTE: every var must be exported — cron runs `source env && cronalarm ...`,
# and without export the wrapper (a child process) sees none of these.

# Discord webhook for per-failure alerts
export CRONALARM_DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."

# Job timeout (seconds, default 300)
export CRONALARM_TIMEOUT=300

# Where failure reports are dropped
export CRONALARM_INBOX_DIR="$HOME/.cronalarm/inbox"

# ── Daily report delivery (all optional — unset = inbox only) ──

# Discord webhook for the daily report on NON-green days. Separate from
# the alert webhook above so your alert channel stays skim-free.
# ALL CLEAR days append one line to a local green digest instead.
export CRONALARM_REPORT_WEBHOOK="https://discord.com/api/webhooks/..."

# Or/and a JSON POST endpoint (message bus, automation):
# export CRONALARM_BUS_URL="https://your-endpoint/..."
# export CRONALARM_BUS_TO="ops"
```

The report also supports live re-verification of read-only checks
(`~/.cronalarm/reverify.map`, one `job name<TAB>command` per line) so a
morning failure that has been fixed since is labeled honestly instead of
republished as current — see `robot.info` for the full option list.

## Adding Jobs

```bash
# 1. Write your script
cat > ~/scripts/check-database.sh << 'EOF'
#!/bin/bash
pg_isready -h localhost || exit 1
echo "Database is up"
EOF
chmod +x ~/scripts/check-database.sh

# 2. Add to crontab
echo '*/5 * * * * source ~/.cronalarm/env && ~/scripts/cronalarm "DB Check" ~/scripts/check-database.sh' \
    >> ~/.cronalarm/crontab

# 3. Install
crontab ~/.cronalarm/crontab
```

**The rule:** Your script exits 0 = success, anything else = CronAlarm screams.

## Files

```
~/scripts/
├── cronalarm                 ← The wrapper (runs every job)
├── cronalarm-report.sh       ← Daily report generator
└── cronalarm-missed-runs.py  ← Missed-run detector (used by the report)

~/.cronalarm/
├── env                    ← All notification settings
├── crontab                ← Your managed crontab
├── crontab.example        ← Example with commented jobs
├── rotate-logs.sh         ← Log cleanup (30 day retention)
├── inbox/                 ← Failure reports (local drop)
└── logs/
    ├── 2026-03-11.log     ← Today's log
    └── ...
```

## Log Format

```
[2026-03-11 03:00:01] START: Daily Backup — /home/user/scripts/backup.sh
[2026-03-11 03:00:14] OK:    Daily Backup (13s)
[2026-03-11 03:15:00] START: Health Check — /home/user/scripts/health.sh
[2026-03-11 03:15:02] FAIL:  Health Check — exit=1 (2s)
```

## Example Scripts

The `examples/` directory includes starter scripts for common tasks:

- `vital-services-monitor.sh` — Check HTTP endpoints, services + disk space (retries once before screaming)
- `backup-to-remote.sh` — Archive files to a remote server
- `cleanup-old-files.sh` — Age-based file cleanup with archive

These are templates — customize for your setup.

## Unattended Install

For automation or provisioning:

```bash
CRONALARM_DISCORD_WEBHOOK="https://discord.com/api/webhooks/..." \
bash install.sh --yes
```

## Requirements

- Linux with `bash` 4+ (macOS works for the wrapper; the report's missed-run
  outage attribution needs a systemd journal and degrades to "scheduler
  state unknown" without one)
- `python3` (notifications, daily report, missed-run detection)
- `timeout` (GNU coreutils)

## License

MIT — do whatever you want with it.

---

Built by [Project Sparks](https://projectsparks.ai) — Guy, Rocky 🦞, and Opie ⚡
