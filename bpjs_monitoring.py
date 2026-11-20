#!/usr/bin/env python3
"""
tatareka-bpjs-monitoring: keeps SIMGOS's copy of BPJS claim status current, without anyone opening a screen.

  tatareka-bpjs-monitoring run      ask now, as the nightly timer does (01:00)
  tatareka-bpjs-monitoring plan     show what it would ask, ask nothing
  tatareka-bpjs-monitoring status   is it on, does it run here, last run, claims by BPJS status
  tatareka-bpjs-monitoring dashboard  rebuild the dashboard data (every 15 minutes, and after each run)

Why: SIMGOS learns BPJS's verdict on a claim (approved, pending, tidak layak) only when someone opens Monitoring >
Status Klaim dari BPJS for a discharge date. Then SIMGOS asks BPJS (VClaim Monitoring/Klaim), stores the answer in
bpjs.klaim, and its triggers copy the status onto the claim (inacbg.hasil_grouping.KLAIM) and its bill
(pembayaran.tagihan_klaim.STATUS). This package opens that same SIMGOS web service on this server, every night.

The whole rule:
  Every night, if a staff computer has called BPJS through SIMGOS in the last 24 hours (so never on a copy of a
  hospital's server), ask about the discharge dates of the last 180 days that still have a final claim BPJS has not
  approved: each such date the first night it is open, then once a week, on the weekday it was discharged (a turn
  missed because a night was skipped or cut short is taken the next night that runs). One date
  and care type = 3 BPJS calls (status 1, 2, 3), 1 s apart, covering all the date's claims. Every attempt counts as
  asked. A failing date is skipped; 3 in a row (BPJS or SIMGOS down) stop the night. At most 60 minutes.
So the first night catches up on everything (at most 180 days x 2 care types x 3 = 1.080 calls, ~25 min), and after
that every night asks about a seventh of the open dates, the same small load each night.

This program holds no BPJS access: SIMGOS makes the calls with the hospital's own, and logs them. It reads SIMGOS with
its own read-only MySQL account (bpjs_mon: inacbg.grouping, inacbg.hasil_grouping, bpjs.klaim, and two columns of
SIMGOS's BPJS call log: when, and from which computer) and reads nothing from BPJS's answers but the result code. Its
own state is the list of dates it asked and when (/var/lib/tatareka-bpjs-monitoring/state.db, root only).

The dashboard ("Dashboard Klaim BPJS" in SIMGOS's Monitoring menu) shows dashboard.json, rebuilt from SIMGOS every 15
minutes: one row per final claim discharged in the window, with SIMGOS's claim value and BPJS's status and amounts.
It is readable by the web server's group only and served by api.php to logged-in SIMGOS users. Licence: Apache-2.0.
"""
import collections
import configparser
import datetime as dt
import json
import os
import sqlite3
import subprocess
import sys
import time
import urllib.request

LOGIN = "/etc/tatareka-bpjs-monitoring/mysql.cnf"   # bpjs_mon's login ([clientbpjsmon])
MYSQL = ["mysql"] + (["--defaults-file=" + LOGIN] if os.path.exists(LOGIN) else [])

STATE_DIR = os.environ.get("BPJS_MON_STATE", "/var/lib/tatareka-bpjs-monitoring")        # env: tests only
SIMGOS_WS = os.environ.get("BPJS_MON_SIMGOS_WS", "http://127.0.0.1/webservice/bpjservice/")  # env: tests only
CONF = "/etc/tatareka-bpjs-monitoring/monitoring.ini"
TODAY = dt.date.today()
WINDOW_DAYS = 180       # BPJS's claim deadline is 6 months: older claims cannot change any more
PAUSE_S = 1
LIMIT_MIN = 60
# hasil_grouping.KLAIM = bpjs.klaim.status_id: 1 proses verifikasi, 2 pending OR tidak layak (BPJS's status 2 covers
# both; the text in bpjs.klaim.status tells them apart), 3 klaim (approved)
APPROVED = "3"
STATUS_NAMES = {"1": "proses verifikasi", "2": "pending or tidak layak", "3": "klaim (approved)"}


def setting(key, default):
    c = configparser.ConfigParser(inline_comment_prefixes=(";",))
    c.read(CONF)
    return (c.get("monitoring", key, fallback=default) or default).strip()


def sql(q):
    """SIMGOS, read-only, as bpjs_mon (LOGIN, written by setup.sh)."""
    env = dict(os.environ, MYSQL_GROUP_SUFFIX=os.environ.get("MYSQL_GROUP_SUFFIX") or "bpjsmon")
    r = subprocess.run(MYSQL + ["-N", "-B", "-e", q], capture_output=True, text=True, env=env)
    if r.returncode:
        raise RuntimeError("SIMGOS: " + r.stderr.strip()[:300])
    return [[None if c == "NULL" else c for c in line.split("\t")] for line in r.stdout.splitlines()]


def state():
    os.makedirs(STATE_DIR, mode=0o750, exist_ok=True)
    path = os.path.join(STATE_DIR, "state.db")
    con = sqlite3.connect(path)
    os.chmod(path, 0o600)
    con.executescript("""
    CREATE TABLE IF NOT EXISTS lookups (tanggal TEXT, jenis INT, asked TEXT, PRIMARY KEY (tanggal, jenis));
    CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);
    """)
    return con


def meta(con, k, v=None):
    if v is not None:
        con.execute("INSERT OR REPLACE INTO meta VALUES (?, ?)", (k, str(v)))
        return v
    r = con.execute("SELECT v FROM meta WHERE k=?", (k,)).fetchone()
    return r[0] if r else None


def claims():
    """Final claims discharged in the window: [(discharge date, care type 1 inap / 2 jalan, BPJS status id or None)]."""
    since = TODAY - dt.timedelta(days=WINDOW_DAYS)
    first = (since - dt.timedelta(days=60)).strftime("%y%m%d") + "0000"     # NOPEN = YYMMDD + counter; stays start earlier
    out = []
    for nopen, data, status in sql("SELECT g.NOPEN, g.DATA, hg.KLAIM FROM inacbg.grouping g JOIN inacbg.hasil_grouping hg "
                                   f"ON hg.NOPEN = g.NOPEN WHERE g.NOPEN >= '{first}'"):
        try:
            d = json.loads(data or "{}")
        except ValueError:
            continue
        day = str(d.get("tgl_keluar") or "")[:10]
        if not (str(d.get("status")) == "1" and str(d.get("final_inacbg")) == "1" and day[:4].isdigit()):
            continue                                      # not final in SIMGOS yet: cannot be at BPJS
        if since.isoformat() <= day < TODAY.isoformat():
            care = 1 if str(d.get("jns_rawat") or d.get("jns_perawatan") or "") == "1" else 2
            out.append((day, care, str(status) if status not in (None, "", "0") else None))
    return out


def plan(con, rows=None):
    """[(discharge date, care type, why)] due tonight, never asked first. Due: open (a final claim not approved) and not
    asked since its turn, the most recent day on its discharge weekday (today, or up to 6 days ago). So a date is asked
    the first night, then weekly on its weekday, and a turn missed (a skipped night, the time limit) is taken the next
    night that runs."""
    rows = claims() if rows is None else rows
    asked = {(t, int(j)): a for t, j, a in con.execute("SELECT tanggal, jenis, asked FROM lookups")}
    waiting = collections.Counter((day, care) for day, care, status in rows if status != APPROVED)
    due = []
    for (day, care), n in waiting.items():
        last = asked.get((day, care)) or ""
        turn = TODAY - dt.timedelta(days=(TODAY - dt.date.fromisoformat(day)).days % 7)
        if last and last[:10] >= turn.isoformat():
            continue
        due.append((last, day, care, f"{n} claim{'s' if n > 1 else ''} not approved yet, "
                                     + (f"last asked {last[:10]}" if last else "never asked")))
    due.sort()                                            # "" (never asked) first, then the oldest ask, then the date
    return [(day, care, why) for _, day, care, why in due]


def in_use():
    """(True, why) when a staff computer called BPJS through SIMGOS in the last 24 hours (SIMGOS's own jobs on this
    server log as 127.0.0.1 / ::1 and don't count). A copy of a hospital's server (test, development, a trial) has no
    staff using it, so it never asks BPJS with that hospital's access. Unreadable = not in use."""
    try:
        n = int(sql("SELECT COUNT(*) FROM logs.bridge_log WHERE TGL_REQUEST >= NOW() - INTERVAL 1 DAY "
                    "AND ACCESS_FROM_IP NOT IN ('127.0.0.1', '::1')")[0][0] or 0)
    except Exception as e:                                # noqa: BLE001 - no account / other SIMGOS layout
        return False, f"SIMGOS's BPJS call log is not readable ({str(e)[:120]}); run /opt/tatareka-bpjs-monitoring/setup.sh install"
    if not n:
        return False, "no staff computer called BPJS through SIMGOS in the last 24 hours (a copy or test server, or a day off)"
    return True, f"{n} BPJS calls from staff computers in the last 24 hours"


def ask_simgos(day, care, status):
    """One lookup by SIMGOS's own Monitoring Klaim web service: SIMGOS asks BPJS, logs the call and stores the rows.
    Only the result code is read here; the answer names patients."""
    url = f"{SIMGOS_WS}monitoring/klaim?tanggal={day}&jenis={care}&status={status}&jenisPengambilanData=1"
    with urllib.request.urlopen(url, timeout=30) as r:
        d = (json.load(r) or {}).get("data") or {}
    m = d.get("metadata") or d.get("metaData") or {}
    return str(m.get("code") or ""), str(m.get("message") or "")[:120]


def ask(con, due, say=print):
    """Ask about every date due. Returns (dates asked, one-line summary)."""
    until = time.monotonic() + 60 * LIMIT_MIN
    asked = failed = in_a_row = calls = 0
    for day, care, _ in due:
        if in_a_row >= 3 or time.monotonic() > until:
            break
        now = dt.datetime.now().isoformat(timespec="seconds")
        # counted before asking: a date that fails waits for its next turn like any other
        con.execute("INSERT OR REPLACE INTO lookups VALUES (?,?,?)", (day, care, now))
        con.commit()
        asked += 1
        in_a_row += 1                                     # back to 0 below once all 3 calls answer
        for status in (1, 2, 3):                          # proses verifikasi, pending / tidak layak, klaim
            calls += 1
            try:
                code, msg = ask_simgos(day, care, status)
            except Exception as e:                        # noqa: BLE001
                code, msg = "", str(e)[:120]
            if code not in ("200", "201"):                # 201: BPJS has no claim in that status for the date
                failed += 1
                meta(con, "last_error", f"{now} {day} jenis {care} status {status}: {code} {msg}".strip())
                break
            time.sleep(PAUSE_S)
        else:
            in_a_row = 0
    why = ("; stopped after 3 failed dates in a row" if in_a_row >= 3 else
           f"; {len(due) - asked} left at the {LIMIT_MIN}-minute limit, for tomorrow" if asked < len(due) else "")
    summary = (f"{asked} dates asked ({calls} BPJS calls), {failed} failed" + why
               + (f" (last error: {meta(con, 'last_error')})" if failed else ""))
    if failed:
        say(f"tatareka-bpjs-monitoring: {failed} dates failed{why}: {meta(con, 'last_error')}")
    return asked, summary


def kind(bpjs_status, status_id):
    """approved | pending | tidak_layak | verifikasi | unseen, from bpjs.klaim's status text (status_id 2 is both
    pending and tidak layak) or, without a bpjs.klaim row, SIMGOS's per-claim copy (hasil_grouping.KLAIM)."""
    t = (bpjs_status or "").lower()
    if "tidak layak" in t:
        return "tidak_layak"
    if "pending" in t:
        return "pending"
    return {"3": "approved", "2": "pending", "1": "verifikasi"}.get(str(status_id or ""), "unseen")


def dashboard(con):
    """Write dashboard.json for the SIMGOS screen (one row per final claim in the window). Returns the row count."""
    since = TODAY - dt.timedelta(days=WINDOW_DAYS)
    first = (since - dt.timedelta(days=60)).strftime("%y%m%d") + "0000"
    bpjs = {sep: (st, sid, aju, setuju, fpk, cbg) for sep, st, sid, aju, setuju, fpk, cbg in sql(
        "SELECT noSEP, status, status_id, biaya_byPengajuan, biaya_bySetujui, noFPK, inacbg_kode FROM bpjs.klaim "
        f"WHERE tglPulang >= '{since - dt.timedelta(days=31)}'")}
    asked = {(t, int(j)): a for t, j, a in con.execute("SELECT tanggal, jenis, asked FROM lookups")}
    rows = []
    for nopen, data, sep, cbg, tarif, tarif_rs, klaim in sql(
            "SELECT g.NOPEN, g.DATA, hg.NOSEP, hg.CODECBG, hg.TOTALTARIF, hg.TARIFRS, hg.KLAIM FROM inacbg.grouping g "
            f"JOIN inacbg.hasil_grouping hg ON hg.NOPEN = g.NOPEN WHERE g.NOPEN >= '{first}'"):
        try:
            d = json.loads(data or "{}")
        except ValueError:
            continue
        day = str(d.get("tgl_keluar") or "")[:10]
        if not (str(d.get("status")) == "1" and str(d.get("final_inacbg")) == "1" and since.isoformat() <= day < TODAY.isoformat()):
            continue
        care = 1 if str(d.get("jns_rawat") or d.get("jns_perawatan") or "") == "1" else 2
        sep = sep or d.get("no_sep") or ""
        b = bpjs.get(sep)
        num = lambda v: round(float(v)) if v not in (None, "") else None   # noqa: E731
        rows.append({"nopen": nopen, "sep": sep, "norm": str(d.get("norm") or ""), "nama": str(d.get("nm_pasien") or ""),
                     "pulang": day, "care": care, "cbg": (b and b[5]) or cbg or "",
                     "status": kind(b and b[0], (b and b[1]) or klaim), "status_text": (b and b[0] or "").split("#")[-1],
                     "rp_rs": num(tarif_rs), "rp_klaim": num(tarif), "rp_aju": num(b and b[2]), "rp_setuju": num(b and b[3]),
                     "fpk": (b and b[4]) or "", "asked": (asked.get((day, care)) or "")[:16]})
    rows.sort(key=lambda r: r["pulang"], reverse=True)
    ok, why = in_use()
    on = setting("refresh", "on").lower() == "on"
    out = {"built": dt.datetime.now().isoformat(timespec="minutes"), "window_days": WINDOW_DAYS,
           "refresh": {"on": on, "runs_here": on and ok, "why": why if on else f"refresh = off di {CONF}",
                       "last_run": meta(con, "last_run") or ""},
           "rows": rows}
    path = os.path.join(STATE_DIR, "dashboard.json")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(out, f, ensure_ascii=False, separators=(",", ":"))
    os.chmod(tmp, 0o640)
    try:                                                  # readable by the web server's group (set by setup.sh on the folder)
        os.chown(tmp, 0, os.stat(STATE_DIR).st_gid)
    except OSError:
        pass
    os.replace(tmp, path)
    return len(rows)


def run(con):
    now = dt.datetime.now().isoformat(timespec="seconds")
    ok, why = in_use()
    if setting("refresh", "on").lower() != "on":
        ok, why = False, f"off (refresh = off in {CONF})"
    if not ok:
        meta(con, "last_run", f"{now} not run: {why}")
    else:
        due = plan(con)
        _, summary = ask(con, due)
        meta(con, "last_run", f"{now} {summary}")
    con.commit()
    print(f"tatareka-bpjs-monitoring: {meta(con, 'last_run')}")
    try:
        dashboard(con)
    except Exception as e:                                # noqa: BLE001 - the run itself is done and saved
        print(f"tatareka-bpjs-monitoring: dashboard not rebuilt: {str(e)[:200]}")
    return 0


def status(con):
    ok, why = in_use()
    on = setting("refresh", "on").lower() == "on"
    print(f"refresh: {'on' if on else 'off'} ({CONF}); " + (("runs here: " if ok else "would not run now: ") + why))
    print(f"last run: {meta(con, 'last_run') or 'never (nightly at 01:00)'}")
    try:
        rows = claims()
    except Exception as e:                                # noqa: BLE001
        print(f"claims: not readable ({str(e)[:150]})")
        return 1
    by = collections.Counter(STATUS_NAMES.get(s, "not seen at BPJS yet") if s else "not seen at BPJS yet" for _, _, s in rows)
    print(f"final claims discharged in the last {WINDOW_DAYS} days: {len(rows)}; BPJS status: "
          + ", ".join(f"{k} {v}" for k, v in by.most_common()))
    print(f"discharge dates due tonight: {len(plan(con, rows))}")
    return 0


def main():
    cmd = (sys.argv[1:] or ["status"])[0]
    con = state()
    if cmd == "run":
        return run(con)
    if cmd == "plan":
        due = plan(con)
        for day, care, why in due:
            print(f"{day}  {'rawat inap ' if care == 1 else 'rawat jalan'}  {why}")
        print(f"{len(due)} discharge dates due ({3 * len(due)} BPJS calls, ~{max(1, round(len(due) * 3 * 1.3 / 60))} min); "
              f"{in_use()[1]}")
        return 0
    if cmd == "status":
        return status(con)
    if cmd == "dashboard":
        dashboard(con)
        return 0
    print(__doc__.split("\n\n")[1])
    return 2


if __name__ == "__main__":
    sys.exit(main())
