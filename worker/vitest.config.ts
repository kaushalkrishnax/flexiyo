import {
  defineWorkersConfig,
  readD1Migrations,
} from '@cloudflare/vitest-pool-workers/config';

// Real schema for the integration tests: migrations are applied once per test
// runtime (see tests/apply-migrations.ts) instead of hand-rolled table fakes.
export default defineWorkersConfig(async () => ({
  test: {
    setupFiles: ['./tests/apply-migrations.ts'],
    poolOptions: {
      workers: {
        wrangler: { configPath: './wrangler.toml' },
        // Hibernatable WebSockets keep storage handles open, which per-file
        // storage isolation cannot snapshot; tests reset state explicitly.
        // A single sequential worker also avoids racing the migration setup.
        isolatedStorage: false,
        singleWorker: true,
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: await readD1Migrations('./migrations'),
            // Fixed secrets so tests never depend on a local .dev.vars file.
            JWT_SECRET: 'test-secret-at-least-32-characters-long',
            CORS_ORIGIN: 'http://localhost',
          },
        },
      },
    },
  },
}));
