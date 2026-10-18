import { applyD1Migrations, env } from 'cloudflare:test';
import type { D1Migration } from '@cloudflare/vitest-pool-workers/config';

declare module 'cloudflare:test' {
  interface ProvidedEnv {
    DB: D1Database;
    TEST_MIGRATIONS: D1Migration[];
  }
}

// An interrupted run can leave the migration bookkeeping table behind while
// the schema itself was rolled back; clear the bookkeeping so it re-applies.
const schemaPresent = await env.DB.prepare(
  "SELECT 1 AS present FROM sqlite_master WHERE type = 'table' AND name = 'users'",
).first<{ present: number }>();
if (!schemaPresent) {
  await env.DB.prepare('DROP TABLE IF EXISTS d1_migrations').run();
}

await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
