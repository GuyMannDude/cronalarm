#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  install.sh — CronAlarm One-Click Installer
# ═══════════════════════════════════════════════════════════════════
#
#  Run this once. It installs everything:
#    1. cronalarm wrapper (the screamer)
#    2. Daily report + missed-run detector + example monitor
#    3. Crontab with every job
#    4. Notification setup (Discord)
#    5. Log rotation
#
#  Usage:
#    bash install.sh
#
#  Or for unattended installs:
#    CRONALARM_DISCORD_WEBHOOK="https://..." \
#    bash install.sh --yes
#
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPTS_DIR="$HOME/scripts"
CRONALARM_DIR="$HOME/.cronalarm"
LOG_DIR="$CRONALARM_DIR/logs"
INBOX_DIR="$CRONALARM_DIR/inbox"
ENV_FILE="$CRONALARM_DIR/env"
AUTO_YES="${1:-}"

echo ""
echo "  ╔═══════════════════════════════════════════════╗"
echo "  ║  🔔 CronAlarm — The Job Runner That Screams  ║"
echo "  ║     No silent failures. Ever.                 ║"
echo "  ╚═══════════════════════════════════════════════╝"
echo ""
echo "  Installing to: $SCRIPTS_DIR"
echo "  Config:        $CRONALARM_DIR"
echo ""

# ─── Create directories ───
mkdir -p "$SCRIPTS_DIR" "$CRONALARM_DIR" "$LOG_DIR" "$INBOX_DIR"

# ─── Find source directory ───
INSTALLER_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Copy core scripts ───
cp "$INSTALLER_DIR/cronalarm.sh" "$SCRIPTS_DIR/cronalarm"
cp "$INSTALLER_DIR/cronalarm-report.sh" "$SCRIPTS_DIR/cronalarm-report.sh"
cp "$INSTALLER_DIR/cronalarm-missed-runs.py" "$SCRIPTS_DIR/cronalarm-missed-runs.py"
chmod +x "$SCRIPTS_DIR/cronalarm"
chmod +x "$SCRIPTS_DIR/cronalarm-report.sh"
chmod +x "$SCRIPTS_DIR/cronalarm-missed-runs.py"

echo "  ✅ Core scripts installed"

# ─── Copy example monitor (a starting point, not required) ───
if [ -f "$INSTALLER_DIR/examples/vital-services-monitor.sh" ]; then
    cp "$INSTALLER_DIR/examples/vital-services-monitor.sh" "$SCRIPTS_DIR/vital-services-monitor.sh"
    chmod +x "$SCRIPTS_DIR/vital-services-monitor.sh"
    echo "  ✅ Example monitor installed (customize $SCRIPTS_DIR/vital-services-monitor.sh)"
fi

# ═══════════════════════════════════════════════════
#  Notification Setup
# ═══════════════════════════════════════════════════

echo ""
echo "  ─── Notification Setup ───"
echo ""

# An existing env file is the user's config, not the installer's — it may
# carry settings this template knows nothing about (report channels, custom
# timeouts). Upgrades keep it untouched; only a fresh install writes one.
if [ -f "$ENV_FILE" ]; then
    ENV_EXISTS=1
    source "$ENV_FILE"
else
    ENV_EXISTS=0
fi

# --- Discord ---
CURRENT_DISCORD="${CRONALARM_DISCORD_WEBHOOK:-}"

if [ "$ENV_EXISTS" -eq 0 ] && [ "$AUTO_YES" != "--yes" ]; then
    echo "  📢 Discord Webhook (recommended)"
    echo "     Get one: Server Settings → Integrations → Webhooks"
    echo ""
    if [ -n "$CURRENT_DISCORD" ]; then
        echo "     Current: ${CURRENT_DISCORD:0:45}..."
        read -p "     Keep existing? (y/n): " KEEP_DISCORD
        if [ "$KEEP_DISCORD" != "y" ]; then
            read -p "     Paste webhook URL (Enter to skip): " DISCORD_INPUT
            CURRENT_DISCORD="${DISCORD_INPUT:-$CURRENT_DISCORD}"
        fi
    else
        read -p "     Paste webhook URL (Enter to skip): " DISCORD_INPUT
        CURRENT_DISCORD="${DISCORD_INPUT:-}"
    fi
    echo ""
fi

# ─── Write environment file (fresh installs only) ───
if [ "$ENV_EXISTS" -eq 1 ]; then
    echo "  ✅ Existing config kept at $ENV_FILE (edit it directly to change settings)"
else
cat > "$ENV_FILE" << ENVEOF
# ═══════════════════════════════════════════════════
# CronAlarm Environment — Edit to change settings
# ═══════════════════════════════════════════════════

# NOTE: every var must be exported — cron runs \`source env && cronalarm ...\`,
# and without export the wrapper (a child process) sees none of these.

# Discord webhook for failure alerts
export CRONALARM_DISCORD_WEBHOOK="${CURRENT_DISCORD}"

# Optional mention prepended to Discord failure alerts (e.g. "@here" or "<@USER_ID>").
# Set your Discord channel to "Only @mentions" and failures will be the only
# messages that make a sound — success/info posts stay silent.
export CRONALARM_MENTION=""

# Default timeout per job (seconds)
export CRONALARM_TIMEOUT=300

# Where to drop failure reports (default: ~/.cronalarm/inbox)
# Set this to your agent's inbox if you use one:
# CRONALARM_INBOX_DIR="\$HOME/.agent/inbox"
export CRONALARM_INBOX_DIR="\$HOME/.cronalarm/inbox"

# ─── Daily report delivery (all optional — unset = inbox only) ───

# Discord webhook for the daily report on NON-GREEN days. Deliberately a
# separate webhook from the failure-alert one above, so your alert channel
# stays skim-free. ALL CLEAR days never post anywhere — they append one
# line to the green digest below instead.
# export CRONALARM_REPORT_WEBHOOK=""

# JSON POST endpoint for the daily report on non-green days (for a message
# bus or automation that reads reports). Empty = skipped.
# export CRONALARM_BUS_URL=""
# export CRONALARM_BUS_TO="ops"          # recipient field in the payload

# Where ALL CLEAR days append their one-line digest entry.
# export CRONALARM_GREEN_DIGEST="\$HOME/.cronalarm/green-digest.jsonl"

# Warnings surface (v2.3): jobs append non-critical warning lines to
# \$CRONALARM_WARN_DIR/YYYY-MM-DD.log; the daily report shows them and a
# warnings-only day goes amber. Warnings never page.
# export CRONALARM_WARN_DIR="\$HOME/.cronalarm/warnings"

# Read-only re-verify map: jobs the report may safely re-run right before
# composing, so a morning failure that's been fixed since is labeled
# honestly. One line per job: job name, a TAB, the command. Only list
# commands that change NOTHING (pure health checks).
# Create at: \$HOME/.cronalarm/reverify.map

# GitHub Actions section: point this at a retention jsonl kept by a
# CI-watching job to include CI state in the daily report. Unset = skipped.
# CRONALARM_GHA_WATCH_HHMM is that job's schedule (HH:MM) — the report uses
# it to judge whether the file carries tonight's run or a stale entry.
# export CRONALARM_GHA_STATE_FILE=""
# export CRONALARM_GHA_WATCH_HHMM=""

# Scheduler unit for missed-run attribution (which misses fall in an
# outage). Debian/Ubuntu = cron.service (default); cronie/RHEL = crond.service.
# export CRONALARM_CRON_UNIT="cron.service"
ENVEOF
echo "  ✅ Config saved to $ENV_FILE"
fi

# ─── Summary of configured channels ───
echo ""
echo "  ─── Notification Channels ───"
[ -n "$CURRENT_DISCORD" ] && echo "  ✅ Discord: configured" || echo "  ⬜ Discord: not set"
echo "  ✅ Local:   always on → $INBOX_DIR"
echo ""

# ─── Log rotation script ───
cat > "$CRONALARM_DIR/rotate-logs.sh" << 'ROTEOF'
#!/usr/bin/env bash
# Keep only 30 days of cron logs
find "$HOME/.cronalarm/logs" -name "*.log" -mtime +30 -delete 2>/dev/null
find "$HOME/.cronalarm/inbox" -name "CRON-*" -mtime +30 -delete 2>/dev/null
find "$HOME/.cronalarm/warnings" -name "*.log" -mtime +30 -delete 2>/dev/null
echo "Log rotation complete"
ROTEOF
chmod +x "$CRONALARM_DIR/rotate-logs.sh"

# ─── Install example crontab ───
echo "  ─── Crontab Setup ───"
echo ""

EXAMPLE_CRONTAB="# ═══════════════════════════════════════════════════
# CronAlarm — Managed crontab
# Every job runs through the cronalarm wrapper
# Failures → Discord + local inbox
# ═══════════════════════════════════════════════════

SHELL=/bin/bash

# ─── Example jobs (uncomment and customize) ───

# System health check — every 15 minutes
# */15 * * * * source $ENV_FILE && $SCRIPTS_DIR/cronalarm \"Health Check\" $SCRIPTS_DIR/vital-services-monitor.sh

# Log rotation — daily at 2 AM
# 0 2 * * * source $ENV_FILE && $SCRIPTS_DIR/cronalarm \"Log Rotation\" $CRONALARM_DIR/rotate-logs.sh

# Daily report — 11 PM every night
# 0 23 * * * source $ENV_FILE && $SCRIPTS_DIR/cronalarm \"Daily Report\" $SCRIPTS_DIR/cronalarm-report.sh

# ═══════════════════════════════════════════════════
# To add a job:
#   1. Write your script in ~/scripts/
#   2. Add a line using the cronalarm wrapper:
#      */30 * * * * source ~/.cronalarm/env && ~/scripts/cronalarm \"My Job\" ~/scripts/my-script.sh
#   3. Run: crontab ~/.cronalarm/crontab
# ═══════════════════════════════════════════════════
"

echo "$EXAMPLE_CRONTAB" > "$CRONALARM_DIR/crontab.example"
echo "  Example crontab saved to $CRONALARM_DIR/crontab.example"

# Don't auto-install crontab on first install — let the user decide
if [ "$AUTO_YES" = "--yes" ]; then
    echo "  (Unattended mode — skipping crontab install)"
else
    echo ""
    read -p "  Install example crontab now? (y/n): " INSTALL_CRON
    if [ "$INSTALL_CRON" = "y" ]; then
        cp "$CRONALARM_DIR/crontab.example" "$CRONALARM_DIR/crontab"
        crontab "$CRONALARM_DIR/crontab"
        echo "  ✅ Crontab installed (all jobs commented out — uncomment what you need)"
    else
        echo "  ⏭️  Skipped. Install later: crontab $CRONALARM_DIR/crontab"
    fi
fi

# ─── Test notification channels ───
echo ""
if [ "$AUTO_YES" != "--yes" ]; then
    read -p "  Send a test alert to all configured channels? (y/n): " DO_TEST
    if [ "$DO_TEST" = "y" ]; then
        echo "  Sending test..."
        source "$ENV_FILE"
        # `false` and not `bash -c "exit 1"`: the wrapper joins its args with
        # spaces and re-parses them, which strips the inner quotes and turns
        # `bash -c exit 1` into a SUCCESSFUL command — a test that cannot fail.
        "$SCRIPTS_DIR/cronalarm" "Install Test" false 2>/dev/null || true
        echo "  ✅ Test alert sent — check your channels!"
    fi
fi

# ─── Done ───
echo ""
echo "  ╔═══════════════════════════════════════════════╗"
echo "  ║  🔔 CronAlarm — Installation Complete        ║"
echo "  ╚═══════════════════════════════════════════════╝"
echo ""
echo "  Scripts:  $SCRIPTS_DIR/cronalarm"
echo "  Config:   $ENV_FILE"
echo "  Logs:     $LOG_DIR/"
echo "  Inbox:    $INBOX_DIR/"
echo ""
echo "  Quick test:"
echo "    source $ENV_FILE"
echo "    $SCRIPTS_DIR/cronalarm \"Test\" echo \"Hello from CronAlarm\""
echo ""
echo "  Force a failure to test alerts:"
echo "    source $ENV_FILE"
echo "    $SCRIPTS_DIR/cronalarm \"Test Fail\" false"
echo ""
echo "  View today's log:"
echo "    cat $LOG_DIR/$(date '+%Y-%m-%d').log"
echo ""
echo "  ⚡ Every job screams on failure. No silent drops. Ever."
echo ""
