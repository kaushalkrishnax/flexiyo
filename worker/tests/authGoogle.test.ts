import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest';

const origFetch = global.fetch;

describe('google token validation', () => {
  beforeEach(() => {
    global.fetch = vi.fn();
  });

  afterEach(() => {
    global.fetch = origFetch;
    vi.restoreAllMocks();
  });

  it('rejects missing idToken', async () => {
    const { handleGoogleOAuth } = await import('../src/routes/auth.js');
    const request = new Request('https://example.com/api/auth/google', {
      method: 'POST',
      body: JSON.stringify({}),
    });
    const env = {
      GOOGLE_OAUTH_CLIENT_ID: 'test-client-id',
      DB: {} as any,
    } as any;
    const res = await handleGoogleOAuth(request, env);
    const body = await res.json();
    expect(res.status).toBe(400);
    expect(body.error).toBe('Validation failed');
  });

  it('rejects when GOOGLE_OAUTH_CLIENT_ID is not configured', async () => {
    const { handleGoogleOAuth } = await import('../src/routes/auth.js');
    const request = new Request('https://example.com/api/auth/google', {
      method: 'POST',
      body: JSON.stringify({ idToken: 'some-token' }),
    });
    const env = {
      GOOGLE_OAUTH_CLIENT_ID: undefined,
      DB: {} as any,
    } as any;
    const res = await handleGoogleOAuth(request, env);
    const body = await res.json();
    expect(res.status).toBe(503);
    expect(body.error).toBe('Google sign-in is not configured');
  });

  it('rejects invalid token from Google', async () => {
    global.fetch = vi.fn().mockResolvedValue(
      new Response(JSON.stringify({ error: 'invalid_token' }), { status: 400 }),
    );
    const { handleGoogleOAuth } = await import('../src/routes/auth.js');
    const request = new Request('https://example.com/api/auth/google', {
      method: 'POST',
      body: JSON.stringify({ idToken: 'bad-token' }),
    });
    const env = {
      GOOGLE_OAUTH_CLIENT_ID: 'test-client-id',
      DB: {} as any,
    } as any;
    const res = await handleGoogleOAuth(request, env);
    const body = await res.json();
    expect(res.status).toBe(401);
    expect(body.error).toBe('Invalid Google ID token');
  });

  it('rejects token with wrong audience', async () => {
    global.fetch = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          aud: 'wrong-client-id',
          iss: 'accounts.google.com',
          email: 'user@example.com',
          sub: '1234567890',
          email_verified: true,
          name: 'Test User',
        }),
        { status: 200 },
      ),
    );
    const { handleGoogleOAuth } = await import('../src/routes/auth.js');
    const request = new Request('https://example.com/api/auth/google', {
      method: 'POST',
      body: JSON.stringify({ idToken: 'some-token' }),
    });
    const env = {
      GOOGLE_OAUTH_CLIENT_ID: 'test-client-id',
      DB: {} as any,
    } as any;
    const res = await handleGoogleOAuth(request, env);
    const body = await res.json();
    expect(res.status).toBe(401);
    expect(body.error).toBe('Invalid Google ID token');
  });

  it('rejects token with unverified email', async () => {
    global.fetch = vi.fn().mockResolvedValue(
      new Response(
        JSON.stringify({
          aud: 'test-client-id',
          iss: 'accounts.google.com',
          email: 'user@example.com',
          sub: '1234567890',
          email_verified: false,
          name: 'Test User',
        }),
        { status: 200 },
      ),
    );
    const { handleGoogleOAuth } = await import('../src/routes/auth.js');
    const request = new Request('https://example.com/api/auth/google', {
      method: 'POST',
      body: JSON.stringify({ idToken: 'some-token' }),
    });
    const env = {
      GOOGLE_OAUTH_CLIENT_ID: 'test-client-id',
      DB: {} as any,
    } as any;
    const res = await handleGoogleOAuth(request, env);
    const body = await res.json();
    expect(res.status).toBe(401);
    expect(body.error).toBe('Invalid Google ID token');
  });
});
