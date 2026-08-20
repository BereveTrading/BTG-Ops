-- BTG Stage 4 — fresh ohlcv schema + policies + continuous aggregates (NO DATA LOAD)
-- Run:  sudo -u postgres psql -d btg -v ON_ERROR_STOP=1 -f ~/btg/ops/stage4-schema.sql
-- Implements ~/btg/ops/ohlcv-policy-spec.md on an empty database.
-- Column name "timestamp" is a reserved word -> quoted everywhere.

\echo '===> chunk-skipping GUC (database-scoped)'
ALTER DATABASE btg SET timescaledb.enable_chunk_skipping = on;
SET timescaledb.enable_chunk_skipping = on;

\echo '===> raw hypertable: ohlcv (1m candles)'
CREATE TABLE IF NOT EXISTS ohlcv (
    canonical_symbol text             NOT NULL,
    source           text             NOT NULL,   -- exchange
    timeframe        text             NOT NULL,
    "timestamp"      timestamptz      NOT NULL,
    open             double precision NOT NULL,
    high             double precision NOT NULL,
    low              double precision NOT NULL,
    close            double precision NOT NULL,
    volume           double precision NOT NULL
);
SELECT create_hypertable('ohlcv', by_range('timestamp', INTERVAL '1 month'),
                          if_not_exists => TRUE);

\echo '===> UNIQUE index on raw = upsert arbiter + composite query index: (canonical_symbol, source, timeframe, timestamp DESC)'
-- Ingest is upsert (ON CONFLICT (canonical_symbol, source, timeframe, "timestamp") DO UPDATE):
-- in-progress candles mutate. Column set includes the partition col + all compress_segmentby cols.
CREATE UNIQUE INDEX IF NOT EXISTS ohlcv_sym_src_tf_ts_uidx
    ON ohlcv (canonical_symbol, source, timeframe, "timestamp" DESC);

\echo '===> compression: segment by symbol/source/timeframe, compress chunks older than 2 days'
ALTER TABLE ohlcv SET (
    timescaledb.compress,
    timescaledb.compress_segmentby = 'canonical_symbol, source, timeframe',
    timescaledb.compress_orderby   = '"timestamp" DESC'
);
SELECT add_compression_policy('ohlcv', INTERVAL '2 days', if_not_exists => TRUE);

\echo '===> raw retention: drop chunks older than 30 days'
SELECT add_retention_policy('ohlcv', INTERVAL '30 days', if_not_exists => TRUE);

-- ---- continuous aggregates (real-time enabled; created empty via WITH NO DATA) ----
\echo '===> continuous aggregate: ohlcv_1h'
CREATE MATERIALIZED VIEW IF NOT EXISTS ohlcv_1h
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT canonical_symbol, source,
       time_bucket(INTERVAL '1 hour', "timestamp") AS "timestamp",
       first(open,  "timestamp") AS open,
       max(high)                 AS high,
       min(low)                  AS low,
       last(close,  "timestamp") AS close,
       sum(volume)               AS volume
FROM ohlcv
WHERE timeframe = '1m'
GROUP BY canonical_symbol, source, time_bucket(INTERVAL '1 hour', "timestamp")
WITH NO DATA;

\echo '===> continuous aggregate: ohlcv_4h'
CREATE MATERIALIZED VIEW IF NOT EXISTS ohlcv_4h
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT canonical_symbol, source,
       time_bucket(INTERVAL '4 hours', "timestamp") AS "timestamp",
       first(open,  "timestamp") AS open,
       max(high)                 AS high,
       min(low)                  AS low,
       last(close,  "timestamp") AS close,
       sum(volume)               AS volume
FROM ohlcv
WHERE timeframe = '1m'
GROUP BY canonical_symbol, source, time_bucket(INTERVAL '4 hours', "timestamp")
WITH NO DATA;

\echo '===> continuous aggregate: ohlcv_1d'
CREATE MATERIALIZED VIEW IF NOT EXISTS ohlcv_1d
WITH (timescaledb.continuous, timescaledb.materialized_only = false) AS
SELECT canonical_symbol, source,
       time_bucket(INTERVAL '1 day', "timestamp") AS "timestamp",
       first(open,  "timestamp") AS open,
       max(high)                 AS high,
       min(low)                  AS low,
       last(close,  "timestamp") AS close,
       sum(volume)               AS volume
FROM ohlcv
WHERE timeframe = '1m'
GROUP BY canonical_symbol, source, time_bucket(INTERVAL '1 day', "timestamp")
WITH NO DATA;

\echo '===> indexes on each cagg (canonical_symbol, source, timestamp DESC)'
CREATE INDEX IF NOT EXISTS ohlcv_1h_sym_src_ts_idx ON ohlcv_1h (canonical_symbol, source, "timestamp" DESC);
CREATE INDEX IF NOT EXISTS ohlcv_4h_sym_src_ts_idx ON ohlcv_4h (canonical_symbol, source, "timestamp" DESC);
CREATE INDEX IF NOT EXISTS ohlcv_1d_sym_src_ts_idx ON ohlcv_1d (canonical_symbol, source, "timestamp" DESC);

\echo '===> cagg refresh policies (1h hourly, 4h every 4h, 1d daily); caggs kept indefinitely (no retention)'
SELECT add_continuous_aggregate_policy('ohlcv_1h',
       start_offset => INTERVAL '3 hours',  end_offset => INTERVAL '1 hour',
       schedule_interval => INTERVAL '1 hour',  if_not_exists => TRUE);
SELECT add_continuous_aggregate_policy('ohlcv_4h',
       start_offset => INTERVAL '12 hours', end_offset => INTERVAL '4 hours',
       schedule_interval => INTERVAL '4 hours', if_not_exists => TRUE);
SELECT add_continuous_aggregate_policy('ohlcv_1d',
       start_offset => INTERVAL '3 days',   end_offset => INTERVAL '1 day',
       schedule_interval => INTERVAL '1 day',   if_not_exists => TRUE);

-- =====================  VERIFICATION (read-only)  =====================
\echo ''
\echo '################## VERIFICATION ##################'
\echo '-- hypertable + chunk interval:'
SELECT hypertable_name,
       (SELECT count(*) FROM timescaledb_information.dimensions d
          WHERE d.hypertable_name = h.hypertable_name) AS dims
FROM timescaledb_information.hypertables h WHERE hypertable_name='ohlcv';
SELECT hypertable_name, column_name, time_interval
FROM timescaledb_information.dimensions WHERE hypertable_name='ohlcv';

\echo '-- chunk count on ohlcv (expect 0 on a fresh DB):'
SELECT count(*) AS ohlcv_chunk_count
FROM timescaledb_information.chunks WHERE hypertable_name='ohlcv';

\echo '-- continuous aggregates defined:'
SELECT view_name, materialization_hypertable_name, materialized_only
FROM timescaledb_information.continuous_aggregates ORDER BY view_name;

\echo '-- compression enabled on ohlcv?:'
SELECT hypertable_name, compression_enabled
FROM timescaledb_information.hypertables WHERE hypertable_name='ohlcv';

\echo '-- scheduled jobs (retention / compression / refresh):'
SELECT job_id, application_name, proc_name, schedule_interval, hypertable_name, scheduled
FROM timescaledb_information.jobs
WHERE proc_name IN ('policy_retention','policy_compression','policy_refresh_continuous_aggregate')
ORDER BY hypertable_name, job_id;

\echo '-- indexes on ohlcv (confirm the UNIQUE upsert arbiter is present):'
SELECT indexname, indexdef FROM pg_indexes WHERE tablename='ohlcv' ORDER BY indexname;

\echo '-- chunk-skipping GUC in this session:'
SHOW timescaledb.enable_chunk_skipping;
\echo '################## END VERIFICATION ##################'
