import { afterEach, describe, expect, it, vi } from 'vitest';
import { sendMessagePush, sendPushToUser } from '../src/services/push.js';
import type { Env } from '../src/types.js';

type Execution = { sql: string; args: unknown[] };

function dbStub(tokens: string[], executions: Execution[] = []) {
  return {
    prepare(sql: string) {
      return {
        bind(...args: unknown[]) {
          return {
            all: async () => ({ results: tokens.map((token) => ({ token })) }),
            first: async () => ({ username: 'sender-name' }),
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
    client_email: `svc-${crypto.randomUUID()}@test.iam.gserviceaccount.com`,
    private_key: pem,
  });
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
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

  it('logs an authorization failure without pruning the token', async () => {
    const account = await makeServiceAccount();
    const executions: Execution[] = [];
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = input.toString();
      if (url.startsWith('https://oauth2.googleapis.com/token')) {
        return new Response(JSON.stringify({ access_token: 'access-token' }), { status: 200 });
      }
      return new Response(
        JSON.stringify({
          error: {
            status: 'PERMISSION_DENIED',
            details: [{ errorCode: 'SENDER_ID_MISMATCH' }],
          },
        }),
        { status: 403 },
      );
    });
    vi.stubGlobal('fetch', fetchMock);

    await sendPushToUser(makeEnv(['tok'], account, executions), 'user-1', {
      title: 'a',
      body: 'b',
    });

    expect(executions).toHaveLength(0);
    expect(errorSpy.mock.calls.flat().join(' ')).toContain('authorization failed');
  });

  it('prunes a token FCM reports as invalid', async () => {
    const account = await makeServiceAccount();
    const executions: Execution[] = [];
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = input.toString();
      if (url.startsWith('https://oauth2.googleapis.com/token')) {
        return new Response(JSON.stringify({ access_token: 'access-token' }), { status: 200 });
      }
      return new Response(
        JSON.stringify({
          error: {
            status: 'INVALID_ARGUMENT',
            message: 'The registration token is not a valid FCM registration token',
            details: [{ errorCode: 'INVALID_ARGUMENT' }],
          },
        }),
        { status: 400 },
      );
    });
    vi.stubGlobal('fetch', fetchMock);

    await sendPushToUser(makeEnv(['bad-token'], account, executions), 'user-1', {
      title: 'a',
      body: 'b',
    });

    expect(executions).toHaveLength(1);
    expect(executions[0].args).toEqual(['bad-token']);
  });

  it('keeps valid tokens on transient failures', async () => {
    const account = await makeServiceAccount();
    const executions: Execution[] = [];
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = input.toString();
      if (url.startsWith('https://oauth2.googleapis.com/token')) {
        return new Response(JSON.stringify({ access_token: 'access-token' }), { status: 200 });
      }
      return new Response(JSON.stringify({ error: { status: 'UNAVAILABLE' } }), { status: 503 });
    });
    vi.stubGlobal('fetch', fetchMock);

    await sendPushToUser(makeEnv(['tok'], account, executions), 'user-1', {
      title: 'a',
      body: 'b',
    });

    expect(executions).toHaveLength(0);
    expect(warnSpy.mock.calls.flat().join(' ')).toContain('temporarily failed');
  });

  it('attempts every token independently when one fails', async () => {
    const account = await makeServiceAccount();
    const executions: Execution[] = [];
    const fetchMock = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = input.toString();
      if (url.startsWith('https://oauth2.googleapis.com/token')) {
        return new Response(JSON.stringify({ access_token: 'access-token' }), { status: 200 });
      }
      const body = JSON.parse(String(init?.body ?? '{}')) as { message?: { token?: string } };
      if (body.message?.token === 'tok-a') {
        return new Response(JSON.stringify({ error: { status: 'INTERNAL' } }), { status: 500 });
      }
      return new Response(JSON.stringify({ name: 'projects/test/messages/1' }), { status: 200 });
    });
    vi.stubGlobal('fetch', fetchMock);

    await sendPushToUser(makeEnv(['tok-a', 'tok-b'], account, executions), 'user-1', {
      title: 'a',
      body: 'b',
    });

    const fcmCalls = fetchMock.mock.calls.filter((call) =>
      call[0].toString().includes('messages:send'),
    );
    expect(fcmCalls).toHaveLength(2);
    expect(executions).toHaveLength(0);
  });

  it('never throws when the FCM request itself fails', async () => {
    const account = await makeServiceAccount();
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {});
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = input.toString();
      if (url.startsWith('https://oauth2.googleapis.com/token')) {
        return new Response(JSON.stringify({ access_token: 'access-token' }), { status: 200 });
      }
      throw new Error('network down');
    });
    vi.stubGlobal('fetch', fetchMock);

    await expect(
      sendPushToUser(makeEnv(['tok'], account), 'user-1', { title: 'a', body: 'b' }),
    ).resolves.toBeUndefined();
    expect(warnSpy.mock.calls.flat().join(' ')).toContain('temporarily failed');
  });

  it('surfaces OAuth exchange failures without attempting delivery', async () => {
    const account = await makeServiceAccount();
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = input.toString();
      if (url.startsWith('https://oauth2.googleapis.com/token')) {
        return new Response(JSON.stringify({ error: 'invalid_grant' }), { status: 400 });
      }
      return new Response('{}', { status: 200 });
    });
    vi.stubGlobal('fetch', fetchMock);

    await sendPushToUser(makeEnv(['tok'], account), 'user-1', { title: 'a', body: 'b' });

    expect(errorSpy.mock.calls.flat().join(' ')).toContain('FCM authentication failed');
    expect(
      fetchMock.mock.calls.some((call) => call[0].toString().includes('messages:send')),
    ).toBe(false);
  });

  it('reports missing tokens distinctly from invalid tokens', async () => {
    const account = await makeServiceAccount();
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
    const fetchSpy = vi.fn();
    vi.stubGlobal('fetch', fetchSpy);

    await sendPushToUser(makeEnv([], account), 'user-1', { title: 'a', body: 'b' });

    expect(logSpy.mock.calls.flat().join(' ')).toContain('no registered tokens');
    expect(fetchSpy).not.toHaveBeenCalled();
  });
});

describe('sendMessagePush policy', () => {
  it('skips delivery when the recipient has an active socket', async () => {
    const account = await makeServiceAccount();
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {});
    const fetchSpy = vi.fn();
    vi.stubGlobal('fetch', fetchSpy);

    await sendMessagePush(makeEnv(['tok'], account), {
      senderId: 'user-1',
      recipientId: 'user-2',
      conversationId: 'conv',
      recipientHasActiveSocket: true,
    });

    expect(fetchSpy).not.toHaveBeenCalled();
    expect(logSpy.mock.calls.flat().join(' ')).toContain('recipient has an active socket');
  });

  it('sends a neutral preview to the offline recipient', async () => {
    const account = await makeServiceAccount();
    const fetchMock = vi.fn(async (input: RequestInfo | URL) => {
      const url = input.toString();
      if (url.startsWith('https://oauth2.googleapis.com/token')) {
        return new Response(JSON.stringify({ access_token: 'access-token' }), { status: 200 });
      }
      return new Response(JSON.stringify({ name: 'projects/test/messages/1' }), { status: 200 });
    });
    vi.stubGlobal('fetch', fetchMock);

    await sendMessagePush(makeEnv(['tok'], account), {
      senderId: 'user-1',
      recipientId: 'user-2',
      conversationId: 'conv',
      recipientHasActiveSocket: false,
    });

    const fcmCall = fetchMock.mock.calls.find((call) =>
      call[0].toString().includes('messages:send'),
    );
    expect(fcmCall).toBeTruthy();
    const body = JSON.parse(String((fcmCall![1] as RequestInit).body)) as {
      message: { notification: { title: string; body: string }; data: Record<string, string> };
    };
    expect(body.message.notification).toEqual({
      title: 'sender-name',
      body: 'Sent you a message',
    });
    expect(body.message.data).toEqual({ type: 'message', conversationId: 'conv' });
  });

  it('never throws when the underlying lookup fails', async () => {
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {});
    const brokenEnv = {
      DB: {
        prepare() {
          throw new Error('db unavailable');
        },
      },
    } as unknown as Env;

    await expect(
      sendMessagePush(brokenEnv, {
        senderId: 'user-1',
        recipientId: 'user-2',
        conversationId: 'conv',
        recipientHasActiveSocket: false,
      }),
    ).resolves.toBeUndefined();
    expect(errorSpy).toHaveBeenCalled();
  });
});
