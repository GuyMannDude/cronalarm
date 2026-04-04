# 🔔 CronAlarm

**The cron wrapper that screams when things break.**

Every cron job runs through CronAlarm. If it fails, you hear about it instantly — Discord, SMS, Telegram, or all three. No silent failures. Ever.

## Why?

Most cron failures happen silently. A backup script breaks at 3 AM and nobody knows until the data is gone. CronAlarm wraps every cron job with:

- **Timeout protection** — kills hung jobs and alerts you
- **Multi-channel alerts** — Discord, SMS (via Textbelt), Telegram
- **Local file drops** — failure reports always saved to disk
- **Daily summaries** — one report at end of day, all channels
- **Structured logs** — one file per day, easy to grep

## Quick Start

```bash
git clone https://github.com/GuyMannDude/cronalarm.git
cd cronalarm
bash install.sh
```

The installer walks you through:
1. Setting up notification channels (Discord, SMS, Telegram)
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
│                   ├→ SMS      📱
│                   ├→ Telegram ✈️
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

# Force a failure to test alerts:
~/scripts/cronalarm "Test Fail" bash -c "exit 1"
```

That's it. If the command exits non-zero, every configured channel gets an alert with the job name, exit code, duration, and output.

## Notification Channels

### Discord (recommended)

1. Server Settings → Integrations → Webhooks
2. Create a webhook in your alerts channel
3. Paste the URL during install (or edit `~/.cronalarm/env`)

### SMS via Textbelt

Just a phone number — no account needed for the free tier.

| Tier | Cost | Limit |
|------|------|-------|
| Free | $0 | 1 text/day (key: `textbelt`) |
| Paid | $0.01/text | Unlimited (get key at [textbelt.com](https://textbelt.com)) |

Daily summary SMS only fires if there were failures — won't spam you on green days.

### Telegram

1. Create a bot via [@BotFather](https://t.me/botfather)
2. Get your chat ID via [@userinfobot](https://t.me/userinfobot)
3. Enter both during install

### Local File Drop (always on)

Every failure writes a markdown report to `~/.cronalarm/inbox/`. Useful if you have an agent or automation that watches a directory.

Configure `CRONALARM_INBOX_DIR` in `~/.cronalarm/env` to point it at your agent's inbox.

## Configuration

All settings live in `~/.cronalarm/env`:

```bash
# Discord
CRONALARM_DISCORD_WEBHOOK="https://discord.com/api/webhooks/..."

# SMS
CRONALARM_SMS_PHONE="5551234567"
CRONALARM_SMS_KEY="textbelt"          # or your paid API key

# Telegram
CRONALARM_TELEGRAM_BOT_TOKEN="..."
CRONALARM_TELEGRAM_CHAT_ID="..."

# Job timeout (seconds, default 300)
CRONALARM_TIMEOUT=300

# Where failure reports are dropped
CRONALARM_INBOX_DIR="$HOME/.cronalarm/inbox"
```

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
├── cronalarm              ← The wrapper (runs every job)
└── cronalarm-report.sh    ← Daily summary generator

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

- `vital-services-monitor.sh` — Check HTTP endpoints + disk space
- `soul-capture.sh` — Archive config/state files to a remote server
- `cleanup-transcripts.sh` — Age-based file cleanup with archive

These are templates — customize for your setup.

## Unattended Install

For automation or provisioning:

```bash
CRONALARM_DISCORD_WEBHOOK="https://discord.com/api/webhooks/..." \
CRONALARM_SMS_PHONE="5551234567" \
bash install.sh --yes
```

## Requirements

- Linux/macOS with `bash` 4+
- `curl` (for notifications)
- `python3` (for safe JSON encoding)
- `timeout` (GNU coreutils)

## License

MIT — do whatever you want with it.

---

Built by [Project Sparks](https://projectsparks.ai) — Guy, Rocky 🦞, and Opie ⚡
