/** JSON request bodies are small; media has its own binary upload limit. */
export const MAX_JSON_BODY_BYTES = 1024 * 1024;

export type JsonBodyResult =
  | { ok: true; body: unknown }
  | { ok: false; response: Response };

function errorResponse(error: string, status: number): Response {
  return new Response(JSON.stringify({ error }), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

/**
 * Reads and parses a JSON body without trusting `Content-Length`.
 * Streaming the body keeps a chunked request from bypassing the cap.
 */
export async function readJsonBody(
  request: Request,
  maxBytes = MAX_JSON_BODY_BYTES,
): Promise<JsonBodyResult> {
  const declared = request.headers.get('content-length');
  if (declared != null) {
    const length = Number(declared);
    if (Number.isFinite(length) && length > maxBytes) {
      return { ok: false, response: errorResponse('Request body too large', 413) };
    }
  }

  if (!request.body) {
    return { ok: false, response: errorResponse('Invalid JSON body', 400) };
  }

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;

  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel().catch(() => {});
        return { ok: false, response: errorResponse('Request body too large', 413) };
      }
      chunks.push(value);
    }
  } catch {
    return { ok: false, response: errorResponse('Invalid JSON body', 400) };
  } finally {
    reader.releaseLock();
  }

  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }

  try {
    return { ok: true, body: JSON.parse(new TextDecoder().decode(bytes)) };
  } catch {
    return { ok: false, response: errorResponse('Invalid JSON body', 400) };
  }
}
