-- The scheduled rate-limit bucket pruner filters by window_start.
-- The primary key only helps UPSERTs by key; this index prevents a table scan.
CREATE INDEX IF NOT EXISTS idx_rate_limit_buckets_window
  ON rate_limit_buckets(window_start);
