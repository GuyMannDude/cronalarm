#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════
#  vital-services-monitor.sh — Check endpoints + disk, scream if dead
# ═══════════════════════════════════════════════════════════════════
#  Example health check script for CronAlarm.
#  Customize the URLs and thresholds for your setup.
# ═══════════════════════════════════════════════════════════════════

FAILURES=""
WARNINGS=""

check() {
    local name="$1"
    local cmd="$2"
    if eval "$cmd" > /dev/null 2>&1; then
        echo "  ✅ $name"
    # Retry once after a 20s pause before screaming — rides out transient
    # blips (a service mid-restart, a brief network rebind) that would
    # otherwise cry wolf every time they last a few seconds.
    elif sleep 20 && eval "$cmd" > /dev/null 2>&1; then
        echo "  ✅ $name (recovered on retry)"
    else
        echo "  ❌ $name"
        FAILURES="${FAILURES}\n- $name is DOWN"
    fi
}

warn_check() {
    local name="$1"
    local cmd="$2"
    if eval "$cmd" > /dev/null 2>&1; then
        echo "  ✅ $name"
    elif sleep 20 && eval "$cmd" > /dev/null 2>&1; then
        echo "  ✅ $name (recovered on retry)"
    else
        echo "  ⚠️  $name"
        WARNINGS="${WARNINGS}\n- $name: not running"
    fi
}

echo "=== Vital Services Check: $(date '+%Y-%m-%d %H:%M:%S') ==="

# ─── Customize these for your setup ───

# Web services (add your URLs)
# check "My Web App" "curl -sf http://localhost:3000/health --max-time 5"
# check "API Server" "curl -sf http://localhost:8080/api/status --max-time 5"
# check "Database" "pg_isready -h localhost"

# Systemd services (add your services)
# warn_check "nginx" "systemctl is-active nginx"
# warn_check "postgresql" "systemctl is-active postgresql"
# warn_check "redis" "systemctl is-active redis"

# Docker containers (add yours)
# check "app-container" "docker ps --filter name=myapp --filter status=running -q | grep -q ."

# Disk space check (warn if any mount > 90%)
DISK_WARN=$(df -h / /home 2>/dev/null | awk 'NR>1 {gsub(/%/,"",$5); if ($5 > 90) print $6 " at " $5 "%"}')
if [ -n "$DISK_WARN" ]; then
    echo "  ⚠️  Disk space: $DISK_WARN"
    WARNINGS="${WARNINGS}\n- Disk space critical: $DISK_WARN"
fi

# Remote host disk check (if you have SSH access)
# REMOTE_DISK=$(ssh myserver "df -h / 2>/dev/null | awk 'NR>1 {gsub(/%/,\"\",\$5); if (\$5 > 90) print \$6 \" at \" \$5 \"%\"}'" 2>/dev/null)
# if [ -n "$REMOTE_DISK" ]; then
#     echo "  ⚠️  Remote disk: $REMOTE_DISK"
#     WARNINGS="${WARNINGS}\n- Remote disk critical: $REMOTE_DISK"
# fi

# Results
echo ""
if [ -n "$FAILURES" ]; then
    echo "🚨 FAILURES DETECTED:"
    echo -e "$FAILURES"
    exit 1
elif [ -n "$WARNINGS" ]; then
    echo "⚠️  Warnings (non-critical):"
    echo -e "$WARNINGS"
    # Persist for the daily report (v2.3): an exit-0 warning reaches no
    # alerting path on its own, so drop it where cronalarm-report.sh
    # looks. Dedup'd per day — a 15-minute cadence must not write 96
    # copies of the same outage.
    WARN_DIR="${CRONALARM_WARN_DIR:-$HOME/.cronalarm/warnings}"
    mkdir -p "$WARN_DIR"
    WARN_FILE="$WARN_DIR/$(date '+%Y-%m-%d').log"
    # Timestamp records WHEN each warning first fired; the dedup key is the
    # message WITHOUT it, or every cadence tick would defeat the dedup.
    echo -e "$WARNINGS" | grep . | while IFS= read -r w; do
        msg="$(basename "$0"): ${w#- }"
        grep -qF -- "$msg" "$WARN_FILE" 2>/dev/null || echo "$(date '+%H:%M') $msg" >> "$WARN_FILE"
    done
    exit 0
else
    echo "🟢 All systems operational."
    exit 0
fi
