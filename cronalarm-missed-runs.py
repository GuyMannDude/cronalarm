#!/usr/bin/env python3
"""
cronalarm-missed-runs.py — report cron slots that produced NO run.

WHY THIS EXISTS (snag-cron-reboot-window-silent-skip-2026-08-25, Opie #2938):
CronAlarm could only report on runs that HAPPENED. A job that never fired left
no FAIL, no exit code and no line — indistinguishable from a job with nothing
to report. On 2026-08-24 the machine rebooted at 22:47:57; cron.service had
stopped at 22:46:27, so the 22:47 "GitHub Actions Watch" slot evaporated and
nothing anywhere said so. 27 of 36 jobs run once-daily or rarer, so for those
a swallowed slot is a full-day gap.

This tool answers the question the report could not ask: "did the run happen
at all?" It is a READER — it never triggers, backfills or reschedules anything.
Catch-up is deliberately out of scope (Opie #2938: "Detection is the fix").

SOURCE OF TRUTH is the live crontab, parsed at call time. A hand-maintained
job list would drift and become its own silent failure.

TOLERANCE: 120s. Evidence: 7,580 matched START events across the 10 most
recent day logs show a start delay of 1s (median and p95) and 2s (max). 120s
is 60x the observed worst case, and stays well under half the 300s minimum
gap between consecutive slots of the tightest schedule (*/5), so a late start
can never be matched to the wrong slot.

THE CRONTAB-MTIME FLOOR (this is what keeps it from crying wolf): expectations
are only asserted for slots at or after the crontab's own last-modified time.
A job added at 14:00 today did not exist at 09:00, so claiming it "missed" the
09:00 slot would be a fabricated alarm — and an alarm that is wrong on the day
anyone adds a cron job is an alarm nobody will trust by the end of the week.
Slots below the floor are counted and NAMED as unassessable, never silently
dropped. This deliberately under-reports rather than over-reports: for a
watcher, a miss is recoverable and a false alarm is not.

⚠️ HISTORICAL REPLAY IS ONLY VALID WHILE THE SCHEDULE HAS NOT MOVED. The
crontab is read as it is NOW. A job that moved from 07:00 to 16:00 last week
makes replaying any earlier date against today's crontab invent missed slots
that never existed. Production use (today's log, today's crontab) is
unaffected; --date is a debugging and regression aid.
"""
import argparse, hashlib, json, os, re, subprocess, sys
from datetime import datetime, timedelta
from pathlib import Path

TOLERANCE_S = 120
LOG_DIR = Path(os.environ.get("CRONALARM_DIR",
                              str(Path.home() / ".cronalarm"))) / "logs"

STAMP = r'^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] '


# Vixie cron accepts names in the month and day-of-week fields ("MON",
# "jan"). int() on those raises, and one unparseable entry must never take
# detection down for every other job — so names are mapped and each crontab
# line parses inside its own guard.
NAMES = {"sun": 0, "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6,
         "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
         "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12}


def _num(tok):
    return NAMES.get(tok.strip().lower()[:3], None) if tok.strip().lower()[:1].isalpha() \
        else int(tok)


def expand(field, lo, hi):
    """Expand one cron field into the set of values it matches."""
    out = set()
    for part in field.split(","):
        step = 1
        if "/" in part:
            part, s = part.split("/", 1)
            step = int(s)
        if part == "*":
            a, b = lo, hi
        elif "-" in part:
            a, b = (_num(x) for x in part.split("-", 1))
        else:
            a = b = _num(part)
            if a is None:
                raise ValueError(f"unrecognized cron field token: {part!r}")
            if step == 1:
                out.add(a)
                continue
        if a is None or b is None:
            raise ValueError(f"unrecognized cron field token: {part!r}")
        out.update(range(a, b + 1, step))
    return {v for v in out if lo <= v <= hi}


# @-macros a slot can be predicted for. @reboot has no slot and lands in
# the unparsed count instead — visible, never silently dropped.
MACROS = {"@hourly": "0 * * * *", "@daily": "0 0 * * *",
          "@midnight": "0 0 * * *", "@weekly": "0 0 * * 0",
          "@monthly": "0 0 1 * *", "@yearly": "0 0 1 1 *",
          "@annually": "0 0 1 1 *"}


def parse_crontab(text):
    """(jobs, unparsed) — unparsed lists cronalarm-invoking lines this tool
    could not turn into a schedule. They are REPORTED, never silently
    skipped: a job excluded from checking must be visible as excluded."""
    jobs, unparsed = [], []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or re.match(r'^[A-Z_]+=', line):
            continue
        if line.startswith("@"):
            macro, _, rest_line = line.partition(" ")
            if macro in MACROS:
                line = f"{MACROS[macro]} {rest_line}"
            elif "cronalarm" in line:
                unparsed.append(line[:120])
                continue
            else:
                continue
        m = re.match(r'^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(.*)$', line)
        if not m:
            if "cronalarm" in line:
                unparsed.append(line[:120])
            continue
        mi, ho, dom, mon, dow, rest = m.groups()
        nm = re.search(r'''cronalarm\s+(?:"([^"]+)"|'([^']+)')''', rest)
        if not nm:
            # Not a recognizably cronalarm-wrapped job: it writes no START
            # line this tool can match, so it must not be claimed missing.
            # A cronalarm invocation with an unquoted job name is counted
            # as unparsed rather than guessed at.
            if re.search(r'cronalarm\s', rest):
                unparsed.append(line[:120])
            continue
        try:
            jobs.append({
                "name": nm.group(1) or nm.group(2),
                "min": expand(mi, 0, 59), "hour": expand(ho, 0, 23),
                "dom": expand(dom, 1, 31), "mon": expand(mon, 1, 12),
                "dow": expand(dow, 0, 7),
                "dom_restricted": dom != "*", "dow_restricted": dow != "*",
                "sched": f"{mi} {ho} {dom} {mon} {dow}",
            })
        except (ValueError, TypeError):
            # One bad line must not sink detection for every other job.
            unparsed.append(line[:120])
    return jobs, unparsed


def fires_on(job, day):
    if day.month not in job["mon"]:
        return False
    cron_dow = (day.weekday() + 1) % 7          # python Mon=0 -> cron Sun=0
    dow_hit = cron_dow in job["dow"] or (cron_dow == 0 and 7 in job["dow"])
    dom_hit = day.day in job["dom"]
    # Standard cron: if BOTH day-of-month and day-of-week are restricted the
    # job runs when EITHER matches; otherwise the restricted one governs.
    if job["dom_restricted"] and job["dow_restricted"]:
        return dom_hit or dow_hit
    return dom_hit and dow_hit


def slots_for(job, day, cutoff):
    out = []
    if not fires_on(job, day):
        return out
    for h in sorted(job["hour"]):
        for mi in sorted(job["min"]):
            t = day.replace(hour=h, minute=mi, second=0, microsecond=0)
            if t <= cutoff:
                out.append(t)
    return out


def starts_from_log(date_tag):
    """job name -> sorted list of START datetimes."""
    f = LOG_DIR / f"{date_tag}.log"
    if not f.exists():
        return None
    starts = {}
    for line in f.read_text(errors="replace").splitlines():
        m = re.match(STAMP + r'START: (.+?) — ', line)
        if m:
            starts.setdefault(m.group(2), []).append(
                datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))
    for v in starts.values():
        v.sort()
    return starts


def cron_up_intervals(day):
    """[(up_from, up_to)] for the day, from the journal — or None = unknown.

    Derived from systemd's Started/Stopped events for the scheduler unit
    (CRONALARM_CRON_UNIT, default cron.service — cronie systems use
    crond.service). A freeze logs no Stopped — but it logs no Started
    either, so the interval simply never reopens and the slot still reads
    DOWN. That is the correct answer by a different route, which is why
    boot markers are not parsed separately.

    "Journal answered with nothing" and "journal unusable" must not read
    the same: a wrong unit name or absent systemd exits journalctl 0 with
    no entries, which would render as "up all day" and turn every reboot
    miss into a false UNEXPLAINED red. So the unit must first prove it is
    known to systemd; anything else returns None — unknown, not fine.
    """
    unit = os.environ.get("CRONALARM_CRON_UNIT", "cron.service")
    lo = day.strftime("%Y-%m-%d")
    hi = (day + timedelta(days=1)).strftime("%Y-%m-%d")
    events = []
    try:
        probe = subprocess.run(
            ["systemctl", "show", "-p", "LoadState", "--value", unit],
            capture_output=True, text=True, timeout=10)
        if probe.returncode != 0 or probe.stdout.strip() != "loaded":
            return None                  # unit unknown here — degrade, don't guess
        res = subprocess.run(
            ["journalctl", "-u", unit, "-o", "short-iso",
             "--since", lo, "--until", hi, "--no-pager"],
            capture_output=True, text=True, timeout=30)
        if res.returncode != 0:
            return None
        out = res.stdout
        for line in out.splitlines():
            m = re.match(r'^(\S+?)[-+]\d{2}:\d{2}\s', line)
            if not m:
                continue
            ts = datetime.fromisoformat(m.group(1))
            if f"Started {unit}" in line:
                events.append(("up", ts))
            elif f"Stopped {unit}" in line:
                events.append(("down", ts))
    except Exception:
        return None                      # unknown, not "fine" — caller degrades

    events.sort(key=lambda e: e[1])
    intervals, cur = [], None
    # Was cron already up at 00:00? If the first event of the day is a "down",
    # it must have been.
    if events and events[0][0] == "down":
        cur = day.replace(hour=0, minute=0, second=0, microsecond=0)
    elif not events:
        cur = day.replace(hour=0, minute=0, second=0, microsecond=0)
    for kind, ts in events:
        if kind == "up" and cur is None:
            cur = ts
        elif kind == "down" and cur is not None:
            intervals.append((cur, ts))
            cur = None
    if cur is not None:
        intervals.append((cur, day.replace(hour=23, minute=59, second=59)))
    return intervals


def crontab_source(path=None):
    """(text, effective_from, floor_source). effective_from is the floor:
    expectations are only asserted for slots at or after it.

    The floor's job is "this schedule provably existed at that time". In
    order of strength:
      1. an explicit --crontab file's mtime (replay);
      2. the spool file's mtime, where the OS lets us stat it (it usually
         does not — Debian's spool dir is unreadable to its own user);
      3. a copy at ~/.cronalarm/crontab whose CONTENT matches the live
         crontab (a stale copy's mtime would fabricate misses for jobs
         added since, so a mismatched copy is skipped, not trusted);
      4. a self-maintained seen-record: this tool stores a hash of the
         crontab text with a timestamp. Unchanged text -> the recorded
         time is the floor. Changed or first-seen -> the floor is NOW,
         today's earlier slots are counted unassessable (and reported as
         such — never as a clean zero), and from tomorrow the record
         carries the floor. Without this, a machine where no mtime is
         readable would silently drop EVERY slot forever — absence of
         evidence rendering as a clean report, the exact defect this
         tool exists to catch.
    """
    if path:
        p = Path(path)
        return (p.read_text(),
                datetime.fromtimestamp(p.stat().st_mtime), "file-mtime")
    text = subprocess.run(["crontab", "-l"], capture_output=True,
                          text=True).stdout
    spool = Path("/var/spool/cron/crontabs") / Path.home().name
    try:
        return text, datetime.fromtimestamp(spool.stat().st_mtime), "spool-mtime"
    except OSError:
        pass
    copy = Path(os.environ.get("CRONALARM_DIR",
                               str(Path.home() / ".cronalarm"))) / "crontab"
    try:
        if copy.read_text() == text:
            return (text, datetime.fromtimestamp(copy.stat().st_mtime),
                    "verified-copy-mtime")
    except OSError:
        pass
    rec = Path(os.environ.get("CRONALARM_DIR",
                              str(Path.home() / ".cronalarm"))) / "crontab.seen.json"
    sha = hashlib.sha256(text.encode()).hexdigest()
    try:
        d = json.loads(rec.read_text())
        if d.get("sha") == sha:
            return text, datetime.fromisoformat(d["since"]), "seen-record"
    except (OSError, ValueError, KeyError):
        pass
    now = datetime.now()
    try:
        rec.parent.mkdir(parents=True, exist_ok=True)
        rec.write_text(json.dumps(
            {"sha": sha, "since": now.isoformat(timespec="seconds")}))
    except OSError:
        pass                             # floor stays NOW; tomorrow retries
    return text, now, "seen-record-new"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--date", default=datetime.now().strftime("%Y-%m-%d"))
    ap.add_argument("--now", help="override 'now' (HH:MM:SS) for replay")
    ap.add_argument("--crontab", help="replay against a saved crontab snapshot "
                                      "instead of the live one")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()

    day = datetime.strptime(a.date, "%Y-%m-%d")
    if a.now:
        now = datetime.strptime(f"{a.date} {a.now}", "%Y-%m-%d %H:%M:%S")
    elif day.date() < datetime.now().date():
        now = day.replace(hour=23, minute=59, second=59)
    else:
        now = datetime.now()
    cutoff = now - timedelta(seconds=TOLERANCE_S)

    starts = starts_from_log(a.date)
    if starts is None:
        print(f"no cron log for {a.date}", file=sys.stderr)
        return 0

    ct_text, ct_since, floor_source = crontab_source(a.crontab)
    jobs, unparsed = parse_crontab(ct_text)
    ups = cron_up_intervals(day)

    def cron_was_up(t):
        if ups is None:
            return None
        return any(lo <= t <= hi for lo, hi in ups)

    missed, expected_total, unassessable = [], 0, 0
    for job in jobs:
        seen = starts.get(job["name"], [])
        for slot in slots_for(job, day, cutoff):
            if slot < ct_since:
                # Predates the crontab we are holding. We do not know what was
                # scheduled then, so we assert nothing about it.
                unassessable += 1
                continue
            expected_total += 1
            if any(0 <= (s - slot).total_seconds() <= TOLERANCE_S for s in seen):
                continue
            up = cron_was_up(slot)
            missed.append({
                "job": job["name"], "slot": slot.strftime("%H:%M"),
                "schedule": job["sched"],
                "scheduler_up": up,
                "cause": ("scheduler was DOWN at this slot" if up is False
                          else "scheduler was up — cause unexplained" if up is True
                          else "scheduler state unknown (journal unreadable)"),
            })

    missed.sort(key=lambda m: (m["slot"], m["job"]))
    if a.json:
        print(json.dumps({"date": a.date, "expected": expected_total,
                          "missed": missed, "tolerance_s": TOLERANCE_S,
                          "missed_down": sum(1 for m in missed
                                             if m["scheduler_up"] is False),
                          "unassessable_slots": unassessable,
                          "unparsed_cronalarm_lines": unparsed,
                          "floor_source": floor_source,
                          "crontab_effective_from": ct_since.isoformat(
                              timespec="seconds")}))
    else:
        print(f"{a.date}: {expected_total} slots expected up to "
              f"{cutoff:%H:%M:%S}, {len(missed)} MISSED")
        for m in missed:
            print(f"  MISSED {m['slot']}  {m['job']}  [{m['schedule']}] — {m['cause']}")
        if unassessable:
            print(f"  ({unassessable} earlier slot(s) NOT assessed — they predate "
                  f"the crontab in hand, effective {ct_since:%Y-%m-%d %H:%M} "
                  f"[{floor_source}])")
        for u in unparsed:
            print(f"  UNPARSED (not checked): {u}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
