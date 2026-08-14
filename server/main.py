"""
ESP32 Power Meter -- API server.

A small FastAPI app that sits between an ESP32 (which POSTs a reading once a
second) and a static dashboard hosted on GitHub Pages (which polls the
GET endpoints). Data is stored in a single SQLite file -- no external
database needed.

Endpoints (see README.md for full details):

    POST /api/ingest    ESP32 pushes one reading (optionally API-key protected)
    GET  /api/latest    newest reading + online/offline status
    GET  /api/history   time-bucketed history for charts
    GET  /api/stats     summary stats (energy used, avg/max power, ...)
    GET  /api/health    liveness check

Run it with:

    uvicorn main:app --host 0.0.0.0 --port 8000

Configuration is done entirely through environment variables:

    DB_PATH         path to the SQLite file       (default: ./data/powermeter.db)
    API_KEY         ingest key; unset = no auth   (default: unset)
    CORS_ORIGINS    comma-separated origins       (default: "*")
    RETENTION_DAYS  delete rows older than this   (default: 90, 0 = keep forever)
"""

import asyncio
import contextlib
import logging
import os
import sqlite3
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, Header, HTTPException, Query
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# Configuration (from environment variables)
# ---------------------------------------------------------------------------

DB_PATH = os.environ.get("DB_PATH", "./data/powermeter.db")

# If API_KEY is set (and non-empty), POST /api/ingest requires a matching
# X-API-Key header. If it is unset, anyone can post readings.
API_KEY = os.environ.get("API_KEY") or None

# Comma-separated list of allowed browser origins. "*" allows everything,
# which is convenient for a GitHub-Pages dashboard.
CORS_ORIGINS = os.environ.get("CORS_ORIGINS", "*")

# How long to keep readings, in days. 0 disables the cleanup entirely.
RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "90"))

# A device is considered "online" if its newest reading is younger than this.
# The ESP32 posts every 1 s, so 10 s means ~10 missed posts in a row. Kept
# deliberately loose so a brief WiFi or network hiccup doesn't flap the
# dashboard's status pill; lower it if you want faster offline detection.
ONLINE_THRESHOLD_S = 10.0

log = logging.getLogger("powermeter")

# ---------------------------------------------------------------------------
# Database helpers (stdlib sqlite3, one short-lived connection per request --
# this is safe under uvicorn even with multiple worker threads)
# ---------------------------------------------------------------------------


def get_db() -> sqlite3.Connection:
    """Open a new SQLite connection. Caller must close() it."""
    conn = sqlite3.connect(DB_PATH, timeout=10)
    conn.row_factory = sqlite3.Row  # lets us access columns by name
    # WAL mode allows a reader and a writer at the same time without
    # "database is locked" errors. The setting persists in the DB file,
    # but re-applying it on every connection is cheap and harmless.
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init_db() -> None:
    """Create the data directory, the readings table and its indexes."""
    Path(DB_PATH).expanduser().resolve().parent.mkdir(parents=True, exist_ok=True)
    conn = get_db()
    try:
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS readings (
                id        INTEGER PRIMARY KEY,
                device_id TEXT NOT NULL,
                ts        REAL NOT NULL,   -- unix seconds, assigned by the server
                voltage   REAL,            -- volts        (NULL if PZEM read failed)
                current   REAL,            -- amps
                power     REAL,            -- watts
                energy    REAL,            -- kWh, CUMULATIVE counter from the PZEM
                frequency REAL,            -- Hz
                pf        REAL,            -- power factor 0..1
                rssi      INTEGER,         -- WiFi signal strength, dBm
                uptime_s  INTEGER          -- seconds since ESP32 boot
            );
            CREATE INDEX IF NOT EXISTS idx_readings_device_ts ON readings (device_id, ts);
            CREATE INDEX IF NOT EXISTS idx_readings_ts ON readings (ts);
            """
        )
        conn.commit()
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Background retention task: once an hour, delete rows older than
# RETENTION_DAYS so the SQLite file doesn't grow forever.
# ---------------------------------------------------------------------------


async def retention_loop() -> None:
    while True:
        try:
            cutoff = time.time() - RETENTION_DAYS * 86400
            conn = get_db()
            try:
                cur = conn.execute("DELETE FROM readings WHERE ts < ?", (cutoff,))
                conn.commit()
                if cur.rowcount:
                    log.info("retention: deleted %d old readings", cur.rowcount)
            finally:
                conn.close()
        except Exception:  # never let a hiccup kill the loop
            log.exception("retention: cleanup failed, will retry in an hour")
        await asyncio.sleep(3600)


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Runs once at startup (before requests) and once at shutdown."""
    init_db()
    task = None
    if RETENTION_DAYS > 0:
        task = asyncio.create_task(retention_loop())
    yield
    if task is not None:
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task


# ---------------------------------------------------------------------------
# App + CORS
# ---------------------------------------------------------------------------

app = FastAPI(title="ESP32 Power Meter API", lifespan=lifespan)

_origins = [o.strip() for o in CORS_ORIGINS.split(",") if o.strip()] or ["*"]
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"] if "*" in _origins else _origins,
    allow_credentials=False,  # must be False when origins is "*"
    allow_methods=["*"],
    allow_headers=["*"],
)

# ---------------------------------------------------------------------------
# Request model -- FastAPI/Pydantic validates the JSON body and returns
# 422 automatically when it is malformed (wrong types, missing device_id...).
# All metrics are Optional because the firmware sends null when the PZEM
# read fails (e.g. sensor unplugged) -- we still want the RSSI/uptime row.
# ---------------------------------------------------------------------------


class Reading(BaseModel):
    device_id: str
    voltage: Optional[float] = None
    current: Optional[float] = None
    power: Optional[float] = None
    energy: Optional[float] = None
    frequency: Optional[float] = None
    pf: Optional[float] = None
    rssi: Optional[int] = None
    uptime_s: Optional[int] = None


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------


@app.post("/api/ingest")
def ingest(reading: Reading, x_api_key: Optional[str] = Header(default=None)):
    """ESP32 -> server. One reading, every ~1 second."""
    # Auth is only enforced when API_KEY is configured on the server.
    if API_KEY is not None and x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="invalid or missing API key")

    ts = time.time()  # timestamp is assigned server-side at receive time
    conn = get_db()
    try:
        conn.execute(
            """
            INSERT INTO readings
                (device_id, ts, voltage, "current", power, energy,
                 frequency, pf, rssi, uptime_s)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                reading.device_id,
                ts,
                reading.voltage,
                reading.current,
                reading.power,
                reading.energy,
                reading.frequency,
                reading.pf,
                reading.rssi,
                reading.uptime_s,
            ),
        )
        conn.commit()
    finally:
        conn.close()
    return {"ok": True}


@app.get("/api/latest")
def latest(device_id: Optional[str] = None):
    """Newest reading (optionally for one device) + online flag."""
    conn = get_db()
    try:
        if device_id is not None:
            row = conn.execute(
                "SELECT * FROM readings WHERE device_id = ? ORDER BY ts DESC LIMIT 1",
                (device_id,),
            ).fetchone()
        else:
            row = conn.execute(
                "SELECT * FROM readings ORDER BY ts DESC LIMIT 1"
            ).fetchone()
    finally:
        conn.close()

    if row is None:
        # -> {"detail": "no data"}
        raise HTTPException(status_code=404, detail="no data")

    age_s = time.time() - row["ts"]
    return {
        "device_id": row["device_id"],
        "ts": row["ts"],
        "voltage": row["voltage"],
        "current": row["current"],
        "power": row["power"],
        "energy": row["energy"],
        "frequency": row["frequency"],
        "pf": row["pf"],
        "rssi": row["rssi"],
        "uptime_s": row["uptime_s"],
        "age_s": age_s,
        "online": age_s < ONLINE_THRESHOLD_S,
    }


@app.get("/api/history")
def history(
    minutes: int = Query(default=60, ge=1, le=44640),  # up to 31 days
    max_points: int = Query(default=500, ge=10, le=5000),
    device_id: Optional[str] = None,
):
    """
    Time-bucketed history for charts.

    The window is split into `max_points` equal buckets; each metric is
    averaged per bucket (energy takes the bucket MAX, since it's a
    cumulative counter). Done entirely in SQL so it stays fast even with
    hundreds of thousands of rows.
    """
    window_s = minutes * 60
    since = time.time() - window_s
    bucket_s = window_s / max_points  # seconds per bucket

    where = "ts >= ?"
    params: list = [bucket_s, since]
    if device_id is not None:
        where += " AND device_id = ?"
        params.append(device_id)
    params.append(max_points)

    conn = get_db()
    try:
        # Buckets are aligned to the unix epoch, so the window can touch
        # max_points + 1 buckets. Taking the newest max_points (DESC +
        # LIMIT) and reversing afterwards guarantees the cap while keeping
        # the most recent data.
        rows = conn.execute(
            f"""
            SELECT
                CAST(ts / ? AS INTEGER) AS bucket,
                AVG(voltage)   AS voltage,
                AVG("current") AS "current",
                AVG(power)     AS power,
                MAX(energy)    AS energy,
                AVG(frequency) AS frequency,
                AVG(pf)        AS pf
            FROM readings
            WHERE {where}
            GROUP BY bucket
            ORDER BY bucket DESC
            LIMIT ?
            """,
            params,
        ).fetchall()
    finally:
        conn.close()

    points = [
        {
            "ts": (row["bucket"] + 0.5) * bucket_s,  # bucket midpoint
            "voltage": row["voltage"],
            "current": row["current"],
            "power": row["power"],
            "energy": row["energy"],
            "frequency": row["frequency"],
            "pf": row["pf"],
        }
        for row in reversed(rows)  # back to ascending ts
    ]
    return {"points": points}


@app.get("/api/stats")
def stats(
    hours: int = Query(default=24, ge=1, le=8760),  # up to 1 year
    device_id: Optional[str] = None,
):
    """Summary statistics over the last `hours` hours."""
    since = time.time() - hours * 3600

    where = "ts >= ?"
    params: list = [since]
    if device_id is not None:
        where += " AND device_id = ?"
        params.append(device_id)

    conn = get_db()
    try:
        # SQL aggregates skip NULLs and return NULL for an empty set,
        # which maps straight onto the "null fields when no data" rule.
        row = conn.execute(
            f"""
            SELECT
                COUNT(*)     AS samples,
                MIN(energy)  AS energy_min,
                MAX(energy)  AS energy_max,
                AVG(power)   AS avg_power,
                MAX(power)   AS max_power,
                MIN(voltage) AS min_voltage,
                MAX(voltage) AS max_voltage,
                MIN(ts)      AS first_ts,
                MAX(ts)      AS last_ts
            FROM readings
            WHERE {where}
            """,
            params,
        ).fetchone()
    finally:
        conn.close()

    # energy is a cumulative kWh counter, so consumption over the window is
    # simply max - min. Guard against None (no non-null energy rows) and
    # against a counter reset making the delta negative.
    energy_kwh = None
    if row["energy_max"] is not None and row["energy_min"] is not None:
        energy_kwh = max(row["energy_max"] - row["energy_min"], 0.0)

    return {
        "hours": hours,
        "samples": row["samples"],
        "energy_kwh": energy_kwh,
        "avg_power": row["avg_power"],
        "max_power": row["max_power"],
        "min_voltage": row["min_voltage"],
        "max_voltage": row["max_voltage"],
        "first_ts": row["first_ts"],
        "last_ts": row["last_ts"],
    }


@app.get("/api/health")
def health():
    """Liveness check for Docker healthchecks / uptime monitors."""
    return {"status": "ok"}
