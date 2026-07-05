# btg-ops

Operational / deployment artifacts for the BTG primary workstation (`dean-MS-7E62`).

## Contents
- **`stage4-install.sh`** — provisions the dedicated DB drive (`nvme0n1p2` → `/var/lib/postgresql`), installs PostgreSQL 16 + TimescaleDB (official Timescale apt repo), creates the `btg` database and enables the extension. Idempotent, halts on first error, does **not** ingest data.
- **`stage4-schema.sql`** — fresh `ohlcv` hypertable + policies + continuous aggregates (`ohlcv_1h/4h/1d`), per `ohlcv-policy-spec.md`. Ends with a verification block.
- **`inspect-db-drive.sh`** — read-only inspection of a drive before adopting it (no writes/format).
- **`ohlcv-policy-spec.md`** — source of truth for the TimescaleDB retention/compression/rollup policy **and the ingest UPSERT contract**. Build the ingest service against this.

## Apply the schema
```
sudo -u postgres psql -d btg -v ON_ERROR_STOP=1 < stage4-schema.sql
```

## Key invariants
- Retention/continuous-aggregate policies are configured **before** any data ingest.
- `ohlcv` chunk count must stay well under 100 (30-day chunks + 30-day retention → ~1–2).
