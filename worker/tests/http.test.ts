import { describe, expect, it } from 'vitest';
import { readJsonBody } from '../src/utils/http.js';

function jsonRequest(body: string, headers: Record<string, string> = {}): Request {
  return new Request('https://example.com/test', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', ...headers },
    body,
  });
}

describe('readJsonBody', () => {
  it('parses a normal JSON body', async () => {
    const result = await readJsonBody(jsonRequest(JSON.stringify({ hello: 'world' })));
    expect(result).toEqual({ ok: true, body: { hello: 'world' } });
  });

  it('rejects malformed JSON with 400', async () => {
    const result = await readJsonBody(jsonRequest('{"broken"'));
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.response.status).toBe(400);
      expect(await result.response.json()).toEqual({ error: 'Invalid JSON body' });
    }
  });

  it('rejects a body with no content', async () => {
    const result = await readJsonBody(new Request('https://example.com/test', { method: 'POST' }));
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.response.status).toBe(400);
  });

  it('rejects an oversized declared content-length without reading it', async () => {
    const result = await readJsonBody(
      jsonRequest('{}', { 'Content-Length': String(2 * 1024 * 1024) }),
    );
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.response.status).toBe(413);
      expect(await result.response.json()).toEqual({ error: 'Request body too large' });
    }
  });

  it('rejects a streamed body that grows past the cap', async () => {
    const result = await readJsonBody(jsonRequest('{"value":"0123456789abcdef"}'), 16);
    expect(result.ok).toBe(false);
    if (!result.ok) {
      expect(result.response.status).toBe(413);
      expect(await result.response.json()).toEqual({ error: 'Request body too large' });
    }
  });
});
