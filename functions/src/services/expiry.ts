const CLEANUP_INTERVAL_SECONDS = 60;

export async function cleanExpiredMessages(db: D1Database): Promise<void> {
  const now = Math.floor(Date.now() / 1000);

  // Skip if a cleanup ran recently (timestamp kept in the _worker_meta table).
  await ensureMetaTable(db);

  const lastCleanup = await db
    .prepare(`SELECT value FROM _worker_meta WHERE key = 'last_expiry_cleanup'`)
    .first<{ value: string }>();

  const lastCleanupTs = lastCleanup ? parseInt(lastCleanup.value, 10) : 0;

  if (now - lastCleanupTs < CLEANUP_INTERVAL_SECONDS) {
    return; // Too soon — skip
  }

  // Null out expired message payloads
  await db
    .prepare(
      `UPDATE messages
       SET encrypted_payload = NULL
       WHERE expires_at IS NOT NULL
         AND expires_at < ?
         AND encrypted_payload IS NOT NULL`,
    )
    .bind(now)
    .run();

  // Update last cleanup timestamp
  await db
    .prepare(
      `INSERT INTO _worker_meta (key, value)
       VALUES ('last_expiry_cleanup', ?)
       ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
    )
    .bind(String(now))
    .run();
}

async function ensureMetaTable(db: D1Database): Promise<void> {
  await db
    .prepare(
      `CREATE TABLE IF NOT EXISTS _worker_meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )`,
    )
    .run();
}
