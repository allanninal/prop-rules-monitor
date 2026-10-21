# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 (see LICENSE)
"""The MT4 history scan of MonEngine.mqh (Prop Rules Monitor MT4) against an independent Python rebuild.

    python3 tests/mt4/check_mt4.py <folder with the snapshot files>

Input: tests/mt4/PrgTrader.mq4 snapshots (<tag>_<SYM>_<TF>_state.csv, the engine's results at many moments) and its
final order list (_orders.csv). For each snapshot the account history at that moment is rebuilt from the orders: an
opening for every buy/sell order opened by then (not the "from #" rest of a partly closed one), the P&L (profit + swap +
commission) of every order closed by then, in time order (in one second: closes, then openings, then reading order).
Then, as PrgScanHistory specifies: closed P&L and trading days per reset day (the reset instant from the line-by-line
port in tests/check_day_start.py), the initial balance (no deposit in the tester
history: the balance minus the closed P&L), the peak balance and the peak end-of-day balance (running sums anchored to
the balance), and the day-start balance rebuilt from the deals since the reset. Configs: tests/mt4/configs.tsv."""
import csv
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ZONE = {"0": "server", "1": "Prague", "2": "UTC", "3": "NewYork", "4": "London", "5": "UTC3"}
CLOCK = {"0": "NY", "1": "NY", "2": "EET"}                     # AUTO = New York close in the tester


def sunday_from(y, m, d, h):
    t = datetime(y, m, d, tzinfo=timezone.utc)
    return t + timedelta(days=(6 - t.weekday()) % 7, hours=h)


def us_dst(u): return sunday_from(u.year, 3, 8, 7) <= u < sunday_from(u.year, 11, 1, 6)
def eu_dst(u): return sunday_from(u.year, 3, 25, 1) <= u < sunday_from(u.year, 10, 25, 1)


def zone_off(z, u):
    return {"Prague": 2 if eu_dst(u) else 1, "London": 1 if eu_dst(u) else 0, "NewYork": -4 if us_dst(u) else -5,
            "UTC": 0, "UTC3": 3}[z] * 3600


def broker_off(clock, srv):
    if clock == "EET":
        return (3 if eu_dst(srv - timedelta(hours=2)) else 2) * 3600
    return (3 if us_dst(srv - timedelta(hours=2)) else 2) * 3600


def floor_to_hour(t, h):
    return t - timedelta(seconds=(int(t.timestamp()) - h * 3600) % 86400)


def day_start(clock, zone, h, srv_ts):
    srv = datetime.fromtimestamp(srv_ts, timezone.utc)
    if zone == "server":
        return int(floor_to_hour(srv, h).timestamp())
    utc = srv - timedelta(seconds=broker_off(clock, srv))
    loc = utc + timedelta(seconds=zone_off(zone, utc))
    rl = floor_to_hour(loc, h)
    ru = rl - timedelta(seconds=zone_off(zone, rl - timedelta(seconds=zone_off(zone, utc))))
    return int((ru + timedelta(seconds=broker_off(clock, ru + timedelta(hours=2)))).timestamp())


def events_of(orders):
    """(time, kind, seq, value, server): kind 1 close, 2 opening (balance operations, kind 0, are not in the tester
    history); server = a stop-loss / take-profit close (the tester fills it before the EA's tick)"""
    ev = []
    for o in orders:
        ty = int(o["type"])
        if ty > 1:
            continue
        if not o["comment"].startswith("from #"):
            ev.append((int(o["open_time"]), 2, len(ev), 0.0, False))
        if o["pool"] == "history":
            ev.append((int(o["close_time"]), 1, len(ev), float(o["profit"]) + float(o["swap"]) + float(o["commission"]),
                       "[sl]" in o["comment"] or "[tp]" in o["comment"]))
    ev.sort(key=lambda e: (e[0], e[1], e[2]))
    return ev


def seen(e, now, final=False):
    """in the history at the snapshot: before its second, or a server close in it (the snapshot is taken at the start of
    the EA's tick, before its own trades of that second)"""
    return e[0] < now or (e[0] == now and (e[4] or final))


def scan(ev, now, bal, ds, final=False):
    ev = [e for e in ev if seen(e, now, final)]
    run = peak = eod = day_end = 0.0
    day = 0
    days = {}                                   # key -> [pnl, traded]
    order = []
    for t, kind, _, v, _ in ev:
        key = ds(t)
        if key not in days:
            days[key] = [0.0, False]
            order.append(key)
        if kind == 2:
            days[key][1] = True
            continue
        if day and key != day:
            eod = max(eod, day_end)
        day = key
        run += v
        day_end = run
        days[key][0] += v
        peak = max(peak, run)
    n_money = len(ev)
    base = bal - run if n_money else 0.0
    run, peak, eod, day_end = run + base, peak + base, eod + base, day_end + base
    initial = bal - (run - base)
    if initial <= 0:
        initial = bal
    today = ds(now)
    peak_balance = max(peak, initial, bal)
    peak_eod = eod
    if day and day < today:
        peak_eod = max(peak_eod, day_end)
    peak_eod = max(peak_eod, initial)
    traded = sum(1 for k in order if days[k][1])
    today_closed = days[today][0] if today in days else 0.0
    rebuilt = bal - sum(e[3] for e in ev if e[0] >= today)
    return dict(initial=initial, peak_balance=peak_balance, peak_eod=peak_eod, trading_days=traded,
                today_closed=today_closed, rebuilt_ref=rebuilt, day_start=today,
                days=";".join(f"{k}:{days[k][0]:.2f}:{int(days[k][1])}" for k in order))


def main(root: Path) -> bool:
    cfg = {}
    for line in (HERE / "configs.tsv").read_text().splitlines():
        tag, _, ov = line.partition("\t")
        if tag:
            cfg[tag] = dict(kv.split("=", 1) for kv in ov.split(","))
    allok, snaps, files = True, 0, 0
    for sf in sorted(root.glob("*_state.csv")):
        stem = sf.name[:-len("_state.csv")]
        tag = next(t for t in sorted(cfg, key=len, reverse=True) if stem.startswith(t + "_"))
        c = cfg[tag]
        clock, zone, hour = CLOCK[c.get("InpClock", "0")], ZONE[c.get("InpResetZone", "1")], int(c.get("InpResetHour", "0"))
        ds = lambda t: day_start(clock, zone, hour, t)       # noqa: E731
        ev = events_of(list(csv.DictReader(open(root / f"{stem}_orders.csv"))))
        bad, first, n = 0, "", 0
        for r in csv.DictReader(open(sf)):
            now, bal = int(r["now"]), float(r["balance"])
            want = scan(ev, now, bal, ds, r["final"] == "1")   # the last one: after the tester closed what was open
            diffs = []
            for k, w in want.items():
                g = r[k]
                if k == "days":
                    ok = g == w
                elif k in ("trading_days", "day_start"):
                    ok = int(g) == int(w)
                else:
                    ok = abs(float(g) - w) <= 0.0051 * max(1, abs(w))
                if not ok:
                    diffs.append(f"{k} {g if k != 'days' else '...'} vs {w if k != 'days' else '...'}")
            n += 1
            if diffs:
                bad += 1
                if not first:
                    first = f"{datetime.fromtimestamp(now, timezone.utc):%Y-%m-%d %H:%M}: " + "; ".join(diffs[:4])
        snaps += n
        files += 1
        allok &= bad == 0
        print(("PASS " if not bad else "FAIL ") + f"{stem:30} snapshots {n - bad}/{n}  clock {clock} reset {zone} {hour:02d}:00"
              f"  events {len(ev)}" + (f"\n      first: {first}" if first else ""))
    print(f"\n{'ALL PASS' if allok and files else 'FAILURES'} ({files} runs, {snaps} snapshots)")
    return bool(allok and files)


if __name__ == "__main__":
    sys.exit(0 if main(Path(sys.argv[1])) else 1)
