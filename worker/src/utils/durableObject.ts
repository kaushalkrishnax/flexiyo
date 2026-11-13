import type { Env } from '../types.js';

function isRetryableDoError(error: unknown): boolean {
  if (typeof error !== 'object' || error === null) return false;
  const record = error as { durableObjectReset?: unknown; retryable?: unknown };
  return record.durableObjectReset === true || record.retryable === true;
}

export async function postChatRoomJson(
  env: Env,
  roomName: string,
  path: string,
  payload: unknown,
): Promise<Response> {
  const body = JSON.stringify(payload);
  const url = `https://internal${path}`;
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const stub = env.CHAT_ROOM.get(env.CHAT_ROOM.idFromName(roomName));
    try {
      return await stub.fetch(
        new Request(url, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body,
        }),
      );
    } catch (error) {
      if (attempt === 0 && isRetryableDoError(error)) continue;
      throw error;
    }
  }
  throw new Error('Unreachable DO fetch retry state');
}
