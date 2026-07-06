# CronAlarm Changelog

## 1.0 — 2026-07-05 — Version anchor (backfill)

CronAlarm predates the fleet changelog rule; this entry anchors the current
shipped state as the truth source for the robot.info drift guard
(tests/check-manifest.sh): pure-bash cron wrapper (sparks-cron.sh) with
multi-channel failure/timeout alerts (Discord webhook, SMS, Telegram),
daily 11 PM summary (cronalarm-report.sh), installer (install.sh), no
daemon and no runtime beyond stock Linux. From here on: every version
bump gets an entry BEFORE robot.info moves.
