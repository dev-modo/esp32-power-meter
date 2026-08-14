# ESP32 Power Meter — API Server

A small FastAPI + SQLite backend that sits between the ESP32 power meter
(which pushes a reading once a second) and the dashboard hosted on
GitHub Pages (which polls the read endpoints). No external database, no
accounts — one Python file and one SQLite file.

```
ESP32 ──POST /api/ingest──▶  this server  ◀──GET /api/latest|history|stats── dashboard (GitHub Pages)
```

---

## ⚠️ HTTPS / mixed content — read this before wiring up the dashboard

The dashboard is served from GitHub Pages over **https**. Browsers refuse to
let an https page call a plain **http** API ("mixed content") — the requests
are silently blocked and the dashboard will just show "offline", with errors
only visible in the browser console.

**You must expose this API over https** and use that https URL in the
dashboard settings. The usual home-server recipe:

1. **Get a domain** — e.g. a free [DuckDNS](https://www.duckdns.org)
   subdomain pointed at your public IP (or use a Cloudflare Tunnel /
   Tailscale Funnel if you don't want to open ports).
2. **Put a reverse proxy with TLS in front of the API** — e.g.
   [Nginx Proxy Manager](https://nginxproxymanager.com):
   * add a Proxy Host: `powermeter.yourname.duckdns.org` → forward to this
     container (`powermeter-api`, port `8000`, scheme `http`),
   * on the SSL tab, request a **Let's Encrypt** certificate (DuckDNS
     supports the DNS challenge, so this works even without opening port 80),
   * enable "Force SSL".
3. **Use the https URL** in both places:
   * dashboard settings → API base URL: `https://powermeter.yourname.duckdns.org`
   * ESP32 config portal → server URL (the ESP32 doesn't care about mixed
     content, but reusing the same URL keeps things simple).
4. **Set an `API_KEY`** (see below) — once the API is reachable from the
   internet, you don't want strangers pushing fake readings.

If you only ever open the dashboard from `http://localhost` or run it
locally, plain http works fine — the restriction comes from the browser,
not from this server.

---

## Run with Docker Compose (recommended)

```bash
cd server
cp .env.example .env   # optional: set API_KEY etc. (stack starts without it too)
docker compose up -d --build
curl http://localhost:8000/api/health   # -> {"status":"ok"}
```

The SQLite database is persisted in `./data/powermeter.db` on the host, so
`docker compose down` / image rebuilds never lose your readings.

> Note: the compose file marks `.env` as optional, which needs Docker
> Compose **v2.24+**. On older versions, either create the `.env` file or
> delete the `env_file:` block and put the variables under `environment:`.

## Run with a plain Python venv

```bash
cd server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

# optional configuration:
export API_KEY=change-me
export RETENTION_DAYS=90

uvicorn main:app --host 0.0.0.0 --port 8000
```

The database is created at `./data/powermeter.db` (override with `DB_PATH`).

## Environment variables

| Variable         | Default                | Description                                                                                             |
| ---------------- | ---------------------- | ------------------------------------------------------------------------------------------------------- |
| `API_KEY`        | *(unset — auth off)*   | If set, `POST /api/ingest` requires a matching `X-API-Key` header, otherwise it answers `401`.          |
| `CORS_ORIGINS`   | `*`                    | Comma-separated list of allowed browser origins, e.g. `https://yourname.github.io`. `*` = allow all.    |
| `RETENTION_DAYS` | `90`                   | Hourly cleanup deletes readings older than this many days. `0` disables cleanup (keep forever).         |
| `DB_PATH`        | `./data/powermeter.db` | SQLite file path. The compose file sets it to `/app/data/powermeter.db` (mounted volume).               |

## API reference

All request and response bodies are JSON. Default port: **8000**.

### `POST /api/ingest` — ESP32 pushes one reading

Headers: `Content-Type: application/json`, plus `X-API-Key: <key>` when the
server has `API_KEY` set. The timestamp is assigned **server-side** at
receive time. Any metric may be `null` if the PZEM read failed.

```bash
curl -X POST http://localhost:8000/api/ingest \
  -H 'Content-Type: application/json' \
  -H 'X-API-Key: change-me' \
  -d '{"device_id":"powermeter-01","voltage":231.2,"current":1.234,"power":285.1,"energy":12.345,"frequency":50.0,"pf":0.95,"rssi":-61,"uptime_s":12345}'
```

Responses: `200 {"ok": true}` · `401` wrong/missing key · `422` malformed body.

### `GET /api/latest[?device_id=]` — newest reading

```json
{
  "device_id": "powermeter-01", "ts": 1765352410.5,
  "voltage": 231.2, "current": 1.234, "power": 285.1, "energy": 12.345,
  "frequency": 50.0, "pf": 0.95, "rssi": -61, "uptime_s": 12345,
  "age_s": 1.7, "online": true
}
```

`ts` is unix seconds (float, server receive time); `online` is
`age_s < 10`. Returns `404 {"detail":"no data"}` while the database is empty.

### `GET /api/history?minutes=60&max_points=500[&device_id=]` — chart data

* `minutes`: window length, default `60` (1 … 44640, i.e. up to 31 days)
* `max_points`: downsampling cap, default `500` (10 … 5000)

Returns `{"points":[{"ts","voltage","current","power","energy","frequency","pf"}, ...]}`
in ascending `ts`, bucket-downsampled to at most `max_points` points
(per-bucket average; `energy` uses the bucket maximum because it is a
cumulative counter).

### `GET /api/stats?hours=24[&device_id=]` — summary statistics

* `hours`: window length, default `24` (1 … 8760, i.e. up to a year)

```json
{
  "hours": 24, "samples": 43128,
  "energy_kwh": 6.42, "avg_power": 267.5, "max_power": 2140.0,
  "min_voltage": 224.1, "max_voltage": 236.8,
  "first_ts": 1765266010.1, "last_ts": 1765352410.5
}
```

`energy_kwh` is `max(energy) - min(energy)` over the window (delta of the
cumulative counter, clamped at ≥ 0 in case the counter was reset). Fields
are `null` when there is no data in the window.

### `GET /api/health` — liveness check

Returns `200 {"status":"ok"}`. Handy for Docker healthchecks and uptime
monitors.

## Data & retention

* One reading every second ≈ **86 400 rows/day/device**. Measured on a real
  database this table costs ~85 bytes/row including its indexes, so budget
  roughly **7 MB/day, 220 MB/month, and 0.65 GB at the default 90-day
  retention**. Fine on any home server, but plan the disk — this is the main
  cost of the 1-second cadence, and it is why the retention job exists.
* To cut that down, either raise `REPORT_INTERVAL_MS` in the firmware (2 s
  halves everything) or lower `RETENTION_DAYS`. The charts read from the
  downsampled `/api/history` endpoint, so a coarser cadence costs you nothing
  visually beyond the very shortest time ranges.
* An hourly background task deletes rows older than `RETENTION_DAYS`.
* Back up the meter history by copying `./data/powermeter.db`
  (stop the container first, or use `sqlite3 powermeter.db ".backup ..."`).
