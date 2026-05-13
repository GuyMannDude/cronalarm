#!/usr/bin/env bash
# robot-install.sh — non-interactive CronAlarm installer (JSON-manifest wrapper).
#
# Usage:
#   ./robot-install.sh [path/to/manifest.json]
#   default manifest: ./robot.install
#
# Reads robot.install, exports the channel env vars the underlying
# install.sh expects, and invokes `install.sh --yes`. Emits a single
# JSON object on stdout for the caller to parse; human-readable
# progress goes to stderr.
#
# Stdout shape (always valid JSON):
#   {
#     "ok": true|false,
#     "steps": {
#       "deps":       {"ok": true},
#       "manifest":   {"ok": true, "channels_enabled": ["discord"]},
#       "install":    {"ok": true, "exit_code": 0},
#       "smoke_test": {"ok": true, "log_entry_written": true}
#     },
#     "error": "<reason>"  // only present when ok=false
#   }
#
# Exit codes:
#   0 — success (ok:true)
#   1 — failure (ok:false; error field describes which step blew up)
#
# Env overrides for sandboxed testing:
#   CRONALARM_INSTALL_DRY_RUN=1   skip install.sh + smoke test

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${1:-${REPO_DIR}/robot.install}"
DRY_RUN="${CRONALARM_INSTALL_DRY_RUN:-0}"

log() { printf '[cronalarm] %s\n' "$*" >&2; }

STEPS='{}'

set_step() {
  local key="$1" value="$2"
  STEPS=$(python3 - "$STEPS" "$key" "$value" <<'PY'
import json, sys
steps = json.loads(sys.argv[1])
steps[sys.argv[2]] = json.loads(sys.argv[3])
print(json.dumps(steps))
PY
)
}

emit() {
  local ok="$1" error="${2:-}"
  python3 - "$ok" "$error" "$STEPS" <<'PY'
import json, sys
ok = sys.argv[1] == "true"
err = sys.argv[2]
steps = json.loads(sys.argv[3])
out = {"ok": ok, "steps": steps}
if not ok and err:
    out["error"] = err
print(json.dumps(out, indent=2))
PY
  [ "$ok" = "true" ] && exit 0 || exit 1
}

if ! command -v python3 >/dev/null 2>&1; then
  printf '{"ok": false, "error": "python3 not found", "steps": {}}\n'
  exit 1
fi

# ─── step 1/4: dependency check ──────────────────────────────────────

log "step 1/4 — dependencies"
missing=""
for c in bash curl crontab; do
  command -v "$c" >/dev/null 2>&1 || missing="$missing $c"
done
if [ -n "${missing// }" ]; then
  set_step deps "{\"ok\": false, \"missing\":\"${missing# }\"}"
  emit false "missing dependencies:${missing}"
fi
set_step deps '{"ok": true}'

# ─── step 2/4: parse manifest, prepare env ──────────────────────────

log "step 2/4 — parsing $MANIFEST"

PARSED=$(python3 - "$MANIFEST" <<'PY'
import json, os, re, sys
from pathlib import Path

path = Path(sys.argv[1])
if not path.exists():
    print(f"__ERROR__=manifest not found: {path}")
    sys.exit(0)

try:
    raw = path.read_text()
    cleaned = "\n".join(
        re.sub(r"^\s*//.*$", "", line) for line in raw.splitlines()
    )
    data = json.loads(cleaned)
except json.JSONDecodeError as e:
    print(f"__ERROR__=invalid JSON in {path}: {e}")
    sys.exit(0)

channels = data.get("channels") or {}
enabled = []

def emit_export(env_var, value):
    if env_var and value:
        # Escape single quotes for shell.
        v = value.replace("'", "'\\''")
        print(f"export {env_var}='{v}'")

# Discord
disc = channels.get("discord") or {}
if disc.get("enabled"):
    env_var = disc.get("webhook_env", "CRONALARM_DISCORD_WEBHOOK")
    val = os.environ.get(env_var, "")
    if val:
        emit_export(env_var, val)
        enabled.append("discord")

# SMS
sms = channels.get("sms") or {}
if sms.get("enabled"):
    phone_env = sms.get("phone_env", "CRONALARM_SMS_PHONE")
    key_env = sms.get("key_env", "CRONALARM_SMS_KEY")
    phone = os.environ.get(phone_env, "")
    key = os.environ.get(key_env, "textbelt")
    if phone:
        emit_export("CRONALARM_SMS_PHONE", phone)
        emit_export("CRONALARM_SMS_KEY", key)
        enabled.append("sms")

# Telegram
tg = channels.get("telegram") or {}
if tg.get("enabled"):
    bot_env = tg.get("bot_token_env", "CRONALARM_TELEGRAM_BOT_TOKEN")
    chat_env = tg.get("chat_id_env", "CRONALARM_TELEGRAM_CHAT_ID")
    bot = os.environ.get(bot_env, "")
    chat = os.environ.get(chat_env, "")
    if bot and chat:
        emit_export("CRONALARM_TELEGRAM_BOT_TOKEN", bot)
        emit_export("CRONALARM_TELEGRAM_CHAT_ID", chat)
        enabled.append("telegram")

# Timeout
timeout = data.get("timeout_seconds")
if timeout:
    emit_export("CRONALARM_TIMEOUT", str(int(timeout)))

# Report what's enabled
print(f"__ENABLED__={','.join(enabled)}")
PY
)

if echo "$PARSED" | grep -q '^__ERROR__='; then
  err=$(echo "$PARSED" | sed -n 's/^__ERROR__=//p')
  set_step manifest '{"ok": false}'
  emit false "$err"
fi

ENABLED=$(echo "$PARSED" | sed -n 's/^__ENABLED__=//p')
# Apply the export lines from the parser
eval "$(echo "$PARSED" | grep '^export ')"

set_step manifest "{\"ok\": true, \"channels_enabled\": $(python3 -c "import json,sys; print(json.dumps('$ENABLED'.split(',') if '$ENABLED' else []))")}"
log "channels enabled: ${ENABLED:-none}"

# ─── step 3/4: invoke install.sh ─────────────────────────────────────

if [ "$DRY_RUN" = "1" ]; then
  log "step 3/4 — install.sh (skipped, DRY_RUN=1)"
  set_step install '{"ok": true, "dry_run": true}'
else
  log "step 3/4 — install.sh --yes"
  if bash "$REPO_DIR/install.sh" --yes >&2; then
    set_step install '{"ok": true, "exit_code": 0}'
  else
    set_step install '{"ok": false, "exit_code": "non-zero"}'
    emit false "install.sh failed"
  fi
fi

# ─── step 4/4: smoke test ────────────────────────────────────────────

if [ "$DRY_RUN" = "1" ]; then
  log "step 4/4 — smoke test (skipped)"
  set_step smoke_test '{"ok": true, "skipped": true}'
  emit true
fi

log "step 4/4 — smoke test"
SMOKE_LOG="${HOME}/.cronalarm/logs/$(date +%Y-%m-%d).log"
# Invoke wrapper directly to verify everything wired
if "$REPO_DIR/sparks-cron.sh" "robot-install-smoke" /bin/true 2>/dev/null; then
  if grep -q "robot-install-smoke" "$SMOKE_LOG" 2>/dev/null; then
    set_step smoke_test "{\"ok\": true, \"log_entry_written\": true, \"log_path\": \"$SMOKE_LOG\"}"
    emit true
  else
    set_step smoke_test "{\"ok\": false, \"log_entry_written\": false, \"log_path\": \"$SMOKE_LOG\"}"
    emit false "smoke test: wrapper ran but no log entry at $SMOKE_LOG"
  fi
else
  set_step smoke_test '{"ok": false, "error": "wrapper invocation failed"}'
  emit false "smoke test: cronalarm wrapper failed"
fi
