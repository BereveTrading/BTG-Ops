# BTG TimescaleDB — ohlcv retention & rollup policy (from prior production)

Source of truth for Stage 4 policy config. Apply BEFORE/around backfill, never after.
See ~/.claude memory: btg-timescale-retention-gate.

## Raw hypertable: ohlcv (1m candles, ~9 exchanges, all major pairs)
- chunk_time_interval: **1 month** (TimescaleDB normalizes this to fixed **30-day** chunks — expected; chunk boundaries are 30-day, not calendar-month)
- raw retention: **30 days** on 1m data
  - NOTE: NOT 7 days — 7d caused chart rendering gaps in April.
    Older than 30d is served from aggregates.
- compression: auto-compress chunks older than **2 days**
- enable **timescaledb.enable_chunk_skipping**
- composite index on raw: **(canonical_symbol, source, timeframe, timestamp DESC)** — made **UNIQUE** (doubles as upsert arbiter + query index)

## Ingest contract (build the ingest service against this)
- Ingest is **UPSERT**: `INSERT ... ON CONFLICT (canonical_symbol, source, timeframe, "timestamp") DO UPDATE`
  (in-progress candles mutate as they form).
- Conflict target = the UNIQUE index `(canonical_symbol, source, timeframe, timestamp)`.
- Column `timestamp` is a reserved word → must be quoted `"timestamp"` in SQL.
- OHLC/volume columns are `double precision`.
- Upserts target the current (recent, uncompressed) bucket, so they never hit compressed chunks.

## Continuous aggregates: ohlcv_1h, ohlcv_4h, ohlcv_1d
- refresh cadence: 1h→hourly, 4h→every 4h, 1d→daily
- retention on caggs: **none (keep indefinitely)**
- index on each cagg: **(canonical_symbol, source, timestamp DESC)**

## Hard constraint
- chunk count on ohlcv must stay **well under 100**. Verify after restore.

## Critical ordering nuance (raw 30d vs caggs indefinite)
Raw is dropped at 30d but caggs are kept forever, so caggs MUST be
materialized over the FULL historical range before the 30-day retention
job drops old raw chunks. Restore procedure must guarantee this
(materialize caggs before enabling/allowing raw retention to run), UNLESS
the dump already contains the materialized cagg data.
