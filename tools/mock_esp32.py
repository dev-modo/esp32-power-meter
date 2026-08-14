#!/usr/bin/env python3
"""
Mock ESP32 power meter -- develop the dashboard without any hardware.

Simulates a house: a standby base load plus appliances that switch on and off
(fridge cycling, kettle boiling, AC running, evening lights...). Voltage sags
slightly under load, power factor follows the load mix, and energy accumulates
as a cumulative kWh counter exactly like the real PZEM-004T does.

It speaks the same contract as the firmware: POST /api/ingest every 2 seconds
with device_id, voltage, current, power, energy, frequency, pf, rssi, uptime_s.

Usage
-----
    # Fill the last 6 hours with history, then stream live every 2 s
    python3 tools/mock_esp32.py --backfill 6

    # Just stream live against a remote server
    python3 tools/mock_esp32.py --url https://abc123.ngrok-free.app --key demo-key-12345

    # Send 100 samples and exit
    python3 tools/mock_esp32.py --count 100

Backfill writes straight into the SQLite file (--db) because the API stamps
its own receive time -- there is no way to POST a reading "in the past". Live
mode always goes through the real HTTP API.
"""

import argparse
import json
import math
import random
import sqlite3
import sys
import time
import urllib.error
import urllib.request

# --------------------------------------------------------------------------
# The simulated house
# --------------------------------------------------------------------------

NOMINAL_VOLTAGE = 230.0   # volts (use 120.0 for North America)
NOMINAL_FREQ = 50.0       # Hz    (use 60.0 for North America)
BASE_LOAD_W = 75.0        # always-on standby: router, clocks, phantom draw

# name -> (watts, power factor, mean minutes ON, mean minutes OFF)
APPLIANCES = {
    "fridge":    (150.0, 0.65,  18,  42),   # compressor cycles all day
    "lights":    (180.0, 0.95,  90, 180),   # evening-ish
    "tv":        (120.0, 0.92, 120, 240),
    "kettle":   (2000.0, 0.99,   3, 220),   # short, brutal spikes
    "ac":       (1250.0, 0.88,  45, 150),
    "washer":    (500.0, 0.75,  40, 600),
}


class Appliance:
    """An appliance that randomly toggles between on and off."""

    def __init__(self, name, watts, pf, on_min, off_min):
        self.name, self.watts, self.pf = name, watts, pf
        self.on_s, self.off_s = on_min * 60, off_min * 60
        self.on = random.random() < 0.3
        self.remaining = self._draw()

    def _draw(self):
        """Exponential-ish dwell time so switching looks natural, not clockwork."""
        mean = self.on_s if self.on else self.off_s
        return max(30.0, random.expovariate(1.0 / mean))

    def step(self, dt):
        self.remaining -= dt
        if self.remaining <= 0:
            self.on = not self.on
            self.remaining = self._draw()
        if not self.on:
            return 0.0, self.pf
        # Real appliances aren't perfectly steady: +/-4% wobble.
        return self.watts * random.uniform(0.96, 1.04), self.pf


class House:
    """Aggregates appliances into one PZEM-style reading."""

    def __init__(self, start_energy_kwh=None):
        self.appliances = [Appliance(n, *cfg) for n, cfg in APPLIANCES.items()]
        # A meter that's been installed a while already has a reading on it.
        self.energy = start_energy_kwh if start_energy_kwh is not None else round(
            random.uniform(400, 900), 3)
        self.t = 0.0

    def step(self, dt):
        """Advance the simulation by dt seconds and return one reading dict."""
        self.t += dt

        active_w, weighted_pf = BASE_LOAD_W, BASE_LOAD_W * 0.98
        for a in self.appliances:
            w, pf = a.step(dt)
            active_w += w
            weighted_pf += w * pf

        power = active_w
        pf = weighted_pf / power if power > 0 else 1.0

        # Grid voltage: slow drift + a sag proportional to the load drawn.
        drift = 2.0 * math.sin(self.t / 900.0)
        sag = power / 1000.0 * 1.6
        voltage = NOMINAL_VOLTAGE + drift - sag + random.gauss(0, 0.25)

        frequency = NOMINAL_FREQ + random.gauss(0, 0.02)
        current = power / (voltage * pf) if voltage > 0 and pf > 0 else 0.0

        # Cumulative kWh counter, exactly like the PZEM's own register.
        self.energy += power * dt / 3_600_000.0

        return {
            "voltage": round(voltage, 1),
            "current": round(current, 3),
            "power": round(power, 1),
            "energy": round(self.energy, 3),
            "frequency": round(frequency, 1),
            "pf": round(min(pf, 1.0), 2),
        }


# --------------------------------------------------------------------------
# Backfill: write history straight into SQLite
# --------------------------------------------------------------------------

def backfill(db_path, device_id, hours, interval, quiet=False):
    """Generate `hours` of past readings and insert them directly."""
    conn = sqlite3.connect(db_path)
    # The server creates this table at startup; be tolerant if it hasn't yet.
    conn.execute(
        """CREATE TABLE IF NOT EXISTS readings (
               id INTEGER PRIMARY KEY, device_id TEXT NOT NULL, ts REAL NOT NULL,
               voltage REAL, current REAL, power REAL, energy REAL,
               frequency REAL, pf REAL, rssi INTEGER, uptime_s INTEGER)"""
    )

    now = time.time()
    start = now - hours * 3600
    # Backfill at a coarser cadence than live: 6 h at 2 s would be 10 800 rows
    # of detail no chart can show. One row per `interval` seconds is plenty.
    house = House()
    rows, ts, uptime = [], start, 0

    while ts < now:
        r = house.step(interval)
        rows.append((device_id, ts, r["voltage"], r["current"], r["power"],
                     r["energy"], r["frequency"], r["pf"],
                     random.randint(-72, -48), uptime))
        ts += interval
        uptime += int(interval)

    conn.executemany(
        """INSERT INTO readings (device_id, ts, voltage, current, power, energy,
                                 frequency, pf, rssi, uptime_s)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        rows,
    )
    conn.commit()
    conn.close()

    if not quiet:
        print(f"backfilled {len(rows)} readings over {hours} h "
              f"(one every {interval:g} s), energy now {house.energy:.3f} kWh")
    # Hand the live simulation the same house state so the counter is continuous.
    return house


# --------------------------------------------------------------------------
# Live mode: POST through the real API, like the firmware does
# --------------------------------------------------------------------------

def post(url, key, payload, timeout=10):
    req = urllib.request.Request(
        url.rstrip("/") + "/api/ingest",
        data=json.dumps(payload).encode(),
        method="POST",
    )
    req.add_header("Content-Type", "application/json")
    if key:
        req.add_header("X-API-Key", key)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status


def live(url, key, device_id, interval, count, house, fail_rate, quiet=False):
    boot = time.time()
    sent = failed = 0

    while count is None or sent < count:
        r = house.step(interval)

        # Occasionally the PZEM read fails (loose wiring, bad CRC). The firmware
        # sends JSON null for every metric in that case -- exercise that path so
        # the dashboard's gap rendering gets tested too.
        if random.random() < fail_rate:
            r = {k: None for k in
                 ("voltage", "current", "power", "energy", "frequency", "pf")}

        payload = {
            "device_id": device_id,
            **r,
            "rssi": random.randint(-72, -48),
            "uptime_s": int(time.time() - boot),
        }

        try:
            status = post(url, key, payload)
            if status == 200:
                sent += 1
                failed = 0
                if not quiet:
                    if payload["power"] is None:
                        print(f"[{sent:5d}] PZEM read failed -> nulls sent")
                    else:
                        print(f"[{sent:5d}] {payload['power']:7.1f} W  "
                              f"{payload['voltage']:6.1f} V  "
                              f"{payload['current']:6.3f} A  "
                              f"pf {payload['pf']:.2f}  "
                              f"{payload['energy']:.3f} kWh")
            else:
                failed += 1
                print(f"  ! server returned HTTP {status}", file=sys.stderr)
        except urllib.error.HTTPError as e:
            failed += 1
            print(f"  ! HTTP {e.code}: {e.read()[:120].decode(errors='replace')}",
                  file=sys.stderr)
        except Exception as e:
            failed += 1
            print(f"  ! {type(e).__name__}: {e}", file=sys.stderr)

        if failed == 3:
            print("  ! three failures in a row -- is the server up and the key right?",
                  file=sys.stderr)

        time.sleep(interval)

    return sent


def main():
    p = argparse.ArgumentParser(
        description="Mock ESP32 power meter -- posts realistic PZEM-004T readings.")
    p.add_argument("--url", default="http://127.0.0.1:8000",
                   help="backend base URL (default: %(default)s)")
    p.add_argument("--key", default="", help="X-API-Key, if the server requires one")
    p.add_argument("--device-id", default="powermeter-01")
    p.add_argument("--interval", type=float, default=2.0,
                   help="seconds between readings (default: %(default)s, matches firmware)")
    p.add_argument("--count", type=int, default=None,
                   help="stop after N readings (default: run forever)")
    p.add_argument("--backfill", type=float, metavar="HOURS", default=0,
                   help="seed this many hours of history into the DB first")
    p.add_argument("--backfill-interval", type=float, default=30.0,
                   help="seconds between backfilled rows (default: %(default)s)")
    p.add_argument("--db", default="server/data/powermeter.db",
                   help="SQLite path, only used by --backfill (default: %(default)s)")
    p.add_argument("--fail-rate", type=float, default=0.01,
                   help="fraction of readings sent as nulls, simulating a failed "
                        "PZEM read (default: %(default)s)")
    p.add_argument("--quiet", action="store_true")
    args = p.parse_args()

    house = None
    if args.backfill > 0:
        house = backfill(args.db, args.device_id, args.backfill,
                         args.backfill_interval, args.quiet)
    if house is None:
        house = House()

    if not args.quiet:
        target = "forever" if args.count is None else f"{args.count} readings"
        print(f"streaming to {args.url} every {args.interval:g}s ({target}) "
              f"as {args.device_id} -- Ctrl-C to stop")

    try:
        live(args.url, args.key, args.device_id, args.interval,
             args.count, house, args.fail_rate, args.quiet)
    except KeyboardInterrupt:
        print("\nstopped")


if __name__ == "__main__":
    main()
