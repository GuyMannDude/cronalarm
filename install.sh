#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  install.sh — CronAlarm One-Click Installer
# ═══════════════════════════════════════════════════════════════════
#
#  Run this once. It installs everything:
#    1. cronalarm wrapper (the screamer)
#    2. All monitoring scripts (if present)
#    3. Crontab with every job
#    4. Notification setup (Discord, SMS, Telegram)
#    5. Log rotation
#
#  Usage:
#    bash install.sh
#
#  Or for unattended installs:
#    CRONALARM_DISCORD_WEBHOOK="https://..." \
#    CRONALARM_SMS_PHONE="5551234567" \
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
cp "$INSTALLER_DIR/sparks-cron.sh" "$SCRIPTS_DIR/cronalarm"
cp "$INSTALLER_DIR/cronalarm-report.sh" "$SCRIPTS_DIR/cronalarm-report.sh"
chmod +x "$SCRIPTS_DIR/cronalarm"
chmod +x "$SCRIPTS_DIR/cronalarm-report.sh"

echo "  ✅ Core scripts installed"

# ─── Copy optional scripts if present ───
OPTIONAL_SCRIPTS=(
    "vital-services-monitor.sh"
    "soul-capture.sh"
    "april-bedding-reminder.sh"
    "cleanup-transcripts.sh"
)

INSTALLED_OPTIONAL=0
for script in "${OPTIONAL_SCRIPTS[@]}"; do
    if [ -f "$INSTALLER_DIR/$script" ]; then
        cp "$INSTALLER_DIR/$script" "$SCRIPTS_DIR/$script"
        chmod +x "$SCRIPTS_DIR/$script"
        ((INSTALLED_OPTIONAL++))
    fi
done

if [ "$INSTALLED_OPTIONAL" -gt 0 ]; then
    echo "  ✅ $INSTALLED_OPTIONAL optional scripts installed"
fi

# ═══════════════════════════════════════════════════
#  Notification Setup
# ═══════════════════════════════════════════════════

echo ""
echo "  ─── Notification Setup ───"
echo ""

# Load existing config if present
if [ -f "$ENV_FILE" ]; then
    source "$ENV_FILE"
fi

# --- Discord ---
CURRENT_DISCORD="${CRONALARM_DISCORD_WEBHOOK:-}"

if [ "$AUTO_YES" != "--yes" ]; then
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

# --- SMS ---
CURRENT_PHONE="${CRONALARM_SMS_PHONE:-}"
CURRENT_SMS_KEY="${CRONALARM_SMS_KEY:-textbelt}"

if [ "$AUTO_YES" != "--yes" ]; then
    echo "  📱 SMS Alerts via Textbelt"
    echo "     Free: 1 text/day | Paid: \$0.01/text (textbelt.com)"
    echo "     Just needs a phone number — no account required for free tier"
    echo ""
    if [ -n "$CURRENT_PHONE" ]; then
        echo "     Current: $CURRENT_PHONE"
        read -p "     Keep existing? (y/n): " KEEP_PHONE
        if [ "$KEEP_PHONE" != "y" ]; then
            read -p "     Phone number (digits only, Enter to skip): " PHONE_INPUT
            CURRENT_PHONE="${PHONE_INPUT:-$CURRENT_PHONE}"
        fi
    else
        read -p "     Phone number (digits only, Enter to skip): " PHONE_INPUT
        CURRENT_PHONE="${PHONE_INPUT:-}"
    fi

    if [ -n "$CURRENT_PHONE" ]; then
        echo ""
        echo "     Free key 'textbelt' = 1 text/day (good for testing)"
        echo "     Get unlimited at https://textbelt.com for \$0.01/text"
        read -p "     Textbelt API key (Enter for free tier): " KEY_INPUT
        CURRENT_SMS_KEY="${KEY_INPUT:-textbelt}"
    fi
    echo ""
fi

# --- Telegram ---
CURRENT_TEL_TOKEN="${CRONALARM_TELEGRAM_BOT_TOKEN:-}"
CURRENT_TEL_CHAT="${CRONALARM_TELEGRAM_CHAT_ID:-}"

if [ "$AUTO_YES" != "--yes" ]; then
    echo "  ✈️  Telegram (optional)"
    if [ -n "$CURRENT_TEL_TOKEN" ]; then
        echo "     Current bot configured. Keep? (y/n)"
        read -p "     " KEEP_TEL
        if [ "$KEEP_TEL" != "y" ]; then
            read -p "     Bot token (Enter to skip): " TEL_TOKEN_INPUT
            CURRENT_TEL_TOKEN="${TEL_TOKEN_INPUT:-$CURRENT_TEL_TOKEN}"
            if [ -n "$CURRENT_TEL_TOKEN" ]; then
                read -p "     Chat ID: " TEL_CHAT_INPUT
                CURRENT_TEL_CHAT="${TEL_CHAT_INPUT:-$CURRENT_TEL_CHAT}"
            fi
        fi
    else
        read -p "     Bot token (Enter to skip): " TEL_TOKEN_INPUT
        CURRENT_TEL_TOKEN="${TEL_TOKEN_INPUT:-}"
        if [ -n "$CURRENT_TEL_TOKEN" ]; then
            read -p "     Chat ID: " TEL_CHAT_INPUT
            CURRENT_TEL_CHAT="${TEL_CHAT_INPUT:-}"
        fi
    fi
    echo ""
fi

# ─── Write environment file ───
cat > "$ENV_FILE" << ENVEOF
# ═══════════════════════════════════════════════════
# CronAlarm Environment — Edit to change settings
# ═══════════════════════════════════════════════════

# Discord webhook for failure alerts
CRONALARM_DISCORD_WEBHOOK="${CURRENT_DISCORD}"

# SMS via Textbelt (free: 1/day with key "textbelt")
# Get unlimited at https://textbelt.com for \$0.01/text
CRONALARM_SMS_PHONE="${CURRENT_PHONE}"
CRONALARM_SMS_KEY="${CURRENT_SMS_KEY}"

# Telegram bot (optional)
CRONALARM_TELEGRAM_BOT_TOKEN="${CURRENT_TEL_TOKEN}"
CRONALARM_TELEGRAM_CHAT_ID="${CURRENT_TEL_CHAT}"

# Default timeout per job (seconds)
CRONALARM_TIMEOUT=300

# Where to drop failure reports (default: ~/.cronalarm/inbox)
# Set this to your agent's inbox if you use one:
# CRONALARM_INBOX_DIR="\$HOME/.openclaw/workspace/DESK/inbox"
CRONALARM_INBOX_DIR="\$HOME/.cronalarm/inbox"
ENVEOF

echo "  ✅ Config saved to $ENV_FILE"

# ─── Summary of configured channels ───
echo ""
echo "  ─── Notification Channels ───"
[ -n "$CURRENT_DISCORD" ] && echo "  ✅ Discord: configured" || echo "  ⬜ Discord: not set"
[ -n "$CURRENT_PHONE" ]   && echo "  ✅ SMS:     $CURRENT_PHONE ($CURRENT_SMS_KEY)" || echo "  ⬜ SMS:     not set"
[ -n "$CURRENT_TEL_TOKEN" ] && echo "  ✅ Telegram: configured" || echo "  ⬜ Telegram: not set"
echo "  ✅ Local:   always on → $INBOX_DIR"
echo ""

# ─── Log rotation script ───
cat > "$CRONALARM_DIR/rotate-logs.sh" << 'ROTEOF'
#!/usr/bin/env bash
# Keep only 30 days of cron logs
find "$HOME/.cronalarm/logs" -name "*.log" -mtime +30 -delete 2>/dev/null
find "$HOME/.cronalarm/inbox" -name "CRON-*" -mtime +30 -delete 2>/dev/null
echo "Log rotation complete"
ROTEOF
chmod +x "$CRONALARM_DIR/rotate-logs.sh"

# ─── Install example crontab ───
echo "  ─── Crontab Setup ───"
echo ""

EXAMPLE_CRONTAB="# ═══════════════════════════════════════════════════
# CronAlarm — Managed crontab
# Every job runs through the cronalarm wrapper
# Failures → Discord + SMS + Telegram + local inbox
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
        "$SCRIPTS_DIR/cronalarm" "Install Test" bash -c "echo 'CronAlarm is alive!' && exit 1" 2>/dev/null || true
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
echo "    $SCRIPTS_DIR/cronalarm \"Test Fail\" bash -c \"exit 1\""
echo ""
echo "  View today's log:"
echo "    cat $LOG_DIR/$(date '+%Y-%m-%d').log"
echo ""
echo "  ⚡ Every job screams on failure. No silent drops. Ever."
echo ""
