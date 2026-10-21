# SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0 (see LICENSE)
"""Line-by-line port of PrgDayStart / PrgBrokerOffset / PrgZoneOffset (MonEngine.mqh), checked against zoneinfo:
for every hour 2020-2026, on each broker clock and reset zone, the reset instant must be the last moment the zone's
wall clock showed reset_hour:00 (converted back to server time).   python3 tests/check_day_start.py"""
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

def sunday_from(y, m, d, h):
    t = datetime(y, m, d, tzinfo=timezone.utc)
    return t + timedelta(days=(6 - t.weekday()) % 7, hours=h)     # MQL day_of_week: Sunday=0; Python Sunday=6

def us_dst(u): return sunday_from(u.year, 3, 8, 7) <= u < sunday_from(u.year, 11, 1, 6)
def eu_dst(u): return sunday_from(u.year, 3, 25, 1) <= u < sunday_from(u.year, 10, 25, 1)

def zone_off(z, u):
    return {"Prague": 2 if eu_dst(u) else 1, "London": 1 if eu_dst(u) else 0,
            "NewYork": -4 if us_dst(u) else -5, "UTC": 0}[z] * 3600

def broker_off(clock, srv):        # srv is a naive "server clock" value stored as UTC-aware datetime
    if clock == "EET": return (3 if eu_dst(srv - timedelta(hours=2)) else 2) * 3600
    return (3 if us_dst(srv - timedelta(hours=2)) else 2) * 3600

def floor_to_hour(t, h):
    k = int(t.timestamp()) - h * 3600
    return t - timedelta(seconds=k % 86400)

def day_start(clock, zone, h, srv):
    utc = srv - timedelta(seconds=broker_off(clock, srv))
    loc = utc + timedelta(seconds=zone_off(zone, utc))
    rl = floor_to_hour(loc, h)
    ru = rl - timedelta(seconds=zone_off(zone, rl - timedelta(seconds=zone_off(zone, utc))))
    return ru + timedelta(seconds=broker_off(clock, ru + timedelta(hours=2)))

TZ = {"Prague": "Europe/Prague", "London": "Europe/London", "NewYork": "America/New_York", "UTC": "UTC"}
SRV = {"NY": "America/New_York", "EET": "Europe/Athens"}      # NY close = New York + 7h; EET = Athens

def truth(clock, zone, h, srv):
    # server wall clock -> UTC
    if clock == "NY":
        ny = srv.replace(tzinfo=None) - timedelta(hours=7)
        utc = ny.replace(tzinfo=ZoneInfo("America/New_York")).astimezone(timezone.utc)
    else:
        utc = srv.replace(tzinfo=None).replace(tzinfo=ZoneInfo("Europe/Athens")).astimezone(timezone.utc)
    loc = utc.astimezone(ZoneInfo(TZ[zone]))
    r = loc.replace(hour=h, minute=0, second=0, microsecond=0)
    if r > loc: r -= timedelta(days=1)
    r = r.replace(tzinfo=None).replace(tzinfo=ZoneInfo(TZ[zone])).astimezone(timezone.utc)
    # UTC -> server wall clock
    if clock == "NY":
        s = r.astimezone(ZoneInfo("America/New_York")).replace(tzinfo=None) + timedelta(hours=7)
    else:
        s = r.astimezone(ZoneInfo("Europe/Athens")).replace(tzinfo=None)
    return s.replace(tzinfo=timezone.utc)

bad = total = 0
for clock in ("NY", "EET"):
    for zone, h in (("Prague", 0), ("UTC", 0), ("NewYork", 17), ("London", 22), ("Prague", 23)):
        t = datetime(2020, 1, 1, tzinfo=timezone.utc)
        n_bad = 0
        while t < datetime(2027, 1, 1, tzinfo=timezone.utc):
            for minute in (0, 30):
                s = t + timedelta(minutes=minute)
                total += 1
                if day_start(clock, zone, h, s) != truth(clock, zone, h, s):
                    n_bad += 1
                    if n_bad <= 3:
                        print(f"  {clock} {zone} {h:02d}h srv {s:%Y-%m-%d %H:%M}: got {day_start(clock, zone, h, s):%m-%d %H:%M} want {truth(clock, zone, h, s):%m-%d %H:%M}")
            t += timedelta(hours=1)
        bad += n_bad
        print(f"{clock:3} {zone:8} {h:02d}:00  mismatches {n_bad}")
print(f"total {total} checks, {bad} mismatches")
