import type { SqlDatabase, SqlStatement } from '../database/turso.js';

const DEFAULT_BATCH_SIZE = 100;

export async function runBatched(
  db: SqlDatabase,
  statements: SqlStatement[],
  batchSize = DEFAULT_BATCH_SIZE,
): Promise<void> {
  for (let i = 0; i < statements.length; i += batchSize) {
    await db.batch(statements.slice(i, i + batchSize));
  }
}
