#!/usr/bin/env python3
"""Pins the crontab seen-record floor shared by cronalarm.sh (writer at
every job start) and cronalarm-missed-runs.py (reader + fallback writer).

Run: python3 tests/test-missed-runs-floor.py   (exit 1 on any failure)
"""
import hashlib, importlib.util, json, os, subprocess, sys, tempfile
from datetime import datetime, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location(
    "missed", HERE.parent / "cronalarm-missed-runs.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
real_run = mod.subprocess.run

CRON_A = "0 3 * * * /bin/true\n"
CRON_B = "0 3 * * * /bin/true\n0 4 * * * /bin/false\n"
sha = lambda t: hashlib.sha256(t.encode()).hexdigest()
iso = lambda dt: dt.isoformat(timespec="seconds")
fails = 0


def check(name, cond):
    global fails
    print(("ok   " if cond else "FAIL ") + name)
    fails += 0 if cond else 1


def source(live_text, d, record=None):
    """crontab_source() against a fake live crontab in scratch dir d."""
    os.environ["CRONALARM_DIR"] = d
    mod.SPOOL = Path(d) / "no-such-spool"            # Debian: unreadable
    rec = Path(d) / "crontab.seen.json"
    if record is not None:
        rec.write_text(json.dumps(record))
    mod.subprocess.run = lambda *a, **k: subprocess.CompletedProcess(
        a, 0, stdout=live_text, stderr="")
    try:
        _, since, src = mod.crontab_source()
    finally:
        mod.subprocess.run = real_run
    return since, src, json.loads(rec.read_text())


now = datetime.now()
h = timedelta(hours=1)

with tempfile.TemporaryDirectory() as d:
    since, src, w = source(CRON_A, d, {"sha": sha(CRON_A), "since": iso(now - 3 * h)})
    check("unchanged text keeps the recorded floor",
          src == "seen-record" and abs((since - (now - 3 * h)).total_seconds()) < 1)

with tempfile.TemporaryDirectory() as d:
    since, src, w = source(CRON_A, d)
    check("first sighting floors at NOW and writes the record",
          src == "seen-record-new" and abs((since - now).total_seconds()) < 5
          and w["sha"] == sha(CRON_A))

with tempfile.TemporaryDirectory() as d:
    since, src, w = source(CRON_B, d, {"sha": sha(CRON_A), "since": iso(now - 3 * h)})
    check("changed text floors at NOW, never at a pre-write snapshot",
          src == "seen-record-new" and abs((since - now).total_seconds()) < 5
          and w["sha"] == sha(CRON_B))

with tempfile.TemporaryDirectory() as d:
    since, src, w = source(CRON_A, d, {"sha": sha(CRON_A), "since": "garbage"})
    check("a corrupt record is replaced, floor NOW",
          src == "seen-record-new" and w["since"] != "garbage")

# The writer: one wrapped job start in a scratch dir must leave a record
# the reader accepts as proof, hashed exactly as the reader hashes.
with tempfile.TemporaryDirectory() as d:
    env = dict(os.environ, CRONALARM_DIR=d)
    r = real_run(["bash", str(HERE.parent / "cronalarm.sh"), "Seen Test", "/bin/true"],
                 env=env, capture_output=True, text=True)
    rec = Path(d) / "crontab.seen.json"
    live = real_run(["crontab", "-l"], capture_output=True, text=True).stdout
    w = json.loads(rec.read_text()) if rec.exists() else {}
    check("cronalarm.sh writes the record at job start, hash matches the reader's",
          r.returncode == 0 and w.get("sha") == sha(live))
    first = w.get("since")
    real_run(["bash", str(HERE.parent / "cronalarm.sh"), "Seen Test", "/bin/true"],
             env=env, capture_output=True, text=True)
    check("a second start with unchanged text leaves the first sighting alone",
          json.loads(rec.read_text()).get("since") == first)
    os.environ["CRONALARM_DIR"] = d
    mod.SPOOL = Path(d) / "no-such-spool"
    _, since, src = mod.crontab_source()
    check("the reader accepts the wrapper's record as the floor",
          src == "seen-record" and iso(since) == first)

print(f"\n{fails} failure(s)")
sys.exit(1 if fails else 0)
