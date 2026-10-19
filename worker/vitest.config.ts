import {
  defineWorkersConfig,
  readD1Migrations,
} from '@cloudflare/vitest-pool-workers/config';
import { generateKeyPairSync } from 'node:crypto';

// A throwaway service account lets push tests sign OAuth assertions without
// any real credentials. Tests mock the OAuth/FCM endpoints.
function testServiceAccount(): string {
  const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
  const pem = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
  return JSON.stringify({
    project_id: 'test-project',
    client_email: 'test-svc@test.iam.gserviceaccount.com',
    private_key: pem,
  });
}

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
            FCM_SERVICE_ACCOUNT: testServiceAccount(),
          },
        },
      },
    },
  },
}));
