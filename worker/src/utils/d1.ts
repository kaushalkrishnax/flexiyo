const DEFAULT_BATCH_SIZE = 100;

/** D1 rejects oversized batches; submit large statement lists in bounded chunks. */
export async function runBatched(
  db: D1Database,
  statements: D1PreparedStatement[],
  batchSize = DEFAULT_BATCH_SIZE,
): Promise<void> {
  for (let i = 0; i < statements.length; i += batchSize) {
    await db.batch(statements.slice(i, i + batchSize));
  }
}
