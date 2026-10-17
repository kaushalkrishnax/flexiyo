import { afterEach, describe, expect, it, vi } from 'vitest';
import { sendPushToUser } from '../src/services/push.js';
import type { Env } from '../src/types.js';

type Execution = { sql: string; args: unknown[] };

function dbStub(tokens: string[], executions: Execution[] = []) {
  return {
    prepare(sql: string) {
      return {
        bind(...args: unknown[]) {
          return {
            all: async () => ({ results: tokens.map((token) => ({ token })) }),
            run: async () => {
              executions.push({ sql, args });
              return {};
            },
          };
        },
      };
    },
  };
}

function makeEnv(tokens: string[], secret?: string, executions: Execution[] = []): Env {
  return {
    DB: dbStub(tokens, executions),
    FCM_SERVICE_ACCOUNT: secret,
  } as unknown as Env;
}

async function makeServiceAccount(): Promise<string> {
  const { subtle } = globalThis.crypto;
  const keyPair = await subtle.generateKey(
    {
      name: 'RSASSA-PKCS1-v1_5',
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: 'SHA-256',
    },
    true,
    ['sign', 'verify'],
  );
  const pkcs8 = await subtle.exportKey('pkcs8', keyPair.privateKey);
  const base64 = Buffer.from(pkcs8).toString('base64');
  const pem = `-----BEGIN PRIVATE KEY-----\n${(base64.match(/.{1,64}/g) ?? []).join('\n')}\n-----END PRIVATE KEY-----`;
  return JSON.stringify({
    project_id: 'test-project',
    client_email: 'svc@test.iam.gserviceaccount.com',
    private_key: pem,
  });
}

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('push delivery', () => {
  it('skips silently when no service account is configured', async () => {
    const fetchSpy = vi.fn();
    vi.stubGlobal('fetch', fetchSpy);

    await sendPushToUser(makeEnv(['tok']), 'user-1', {
      title: 'a',
      body: 'b',
    });

    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('skips silently when the service account JSON is incomplete', async () => {
    const fetchSpy = vi.fn();
    vi.stubGlobal('fetch', fetchSpy);

    await sendPushToUser(
      makeEnv(['tok'], JSON.stringify({ project_id: 'p' })),
      'user-1',
      { title: 'a', body: 'b' },
    );

    expect(fetchSpy).not.toHaveBeenCalled();
  });

  it('sends to every registered token through FCM HTTP v1', async () => {
    const account = await makeServiceAccount();
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = input.toString();
      if (url.startsWith('https://oauth2.googleapis.com/token')) {
        return new Response(
          JSON.stringify({ access_token: 'access-token', expires_in: 3600 }),
          { status: 200 },
        );
      }
      return new Response(JSON.stringify({ name: 'projects/test/messages/1' }), {
        status: 200,
      });
    });
    vi.stubGlobal('fetch', fetchMock);

    await sendPushToUser(makeEnv(['tok-a', 'tok-b'], account), 'user-1', {
      title: 'alice',
      body: 'Sent you a message',
      data: { type: 'message' },
    });

    const fcmCalls = fetchMock.mock.calls.filter((call) =>
      call[0].toString().includes('/v1/projects/test-project/messages:send'),
    );
    expect(fcmCalls).toHaveLength(2);

    const bodies = fcmCalls.map(
      (call) => JSON.parse((call[1] as RequestInit).body as string) as {
        message: { token: string; notification: unknown; data: unknown };
      },
    );
    expect(bodies.map((b) => b.message.token).sort()).toEqual(['tok-a', 'tok-b']);
    expect(bodies[0].message.notification).toEqual({
      title: 'alice',
      body: 'Sent you a message',
    });
    expect(bodies[0].message.data).toEqual({ type: 'message' });
  });

  it('prunes tokens that FCM reports as gone', async () => {
    const account = await makeServiceAccount();
    const executions: Execution[] = [];
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = input.toString();
      if (url.startsWith('https://oauth2.googleapis.com/token')) {
        return new Response(JSON.stringify({ access_token: 'access-token' }), {
          status: 200,
        });
      }
      return new Response(JSON.stringify({ error: 'UNREGISTERED' }), {
        status: 404,
      });
    });
    vi.stubGlobal('fetch', fetchMock);

    await sendPushToUser(makeEnv(['stale-token'], account, executions), 'user-1', {
      title: 'a',
      body: 'b',
    });

    expect(executions).toHaveLength(1);
    expect(executions[0].sql).toContain('DELETE FROM push_tokens');
    expect(executions[0].args).toEqual(['stale-token']);
  });
});
