import type { Env } from '../types.js';

/**
 * Inbox fan-out: pushes lightweight "chat list changed" events to each user's
 * persistent inbox Durable Object (`inbox:<userId>`). Clients keep exactly one
 * inbox WebSocket open and stay in sync purely from these events — no polling.
 */

export type InboxEvent =
  | {
      type: 'inbox_message';
      conversationId: string;
      senderId: string;
      preview: string;
      lastMessageAt: number;
      isIncoming?: boolean;
    }
  | {
      /** Full upsert row for the chats list (creation, status flips, settings). */
      type: 'conversation_upsert';
      conversation: Record<string, unknown>;
    }
  | {
      type: 'conversation_removed';
      conversationId: string;
    }
  | {
      type: 'unread_reset';
      conversationId: string;
    }
  | {
      type: 'message_unsent';
      conversationId: string;
      messageId: string;
    };

/**
 * Fire-and-forget fan-out. Failures are swallowed on purpose — the chats list
 * stays repairable via the REST seed (pull-to-refresh / app-resume resync),
 * so a dropped inbox event must never fail the original request.
 */
export async function notifyInboxes(
  env: Env,
  userIds: string[],
  /** Called per recipient so events can be personalised (e.g. isIncoming). */
  buildEvents: (userId: string) => InboxEvent[],
): Promise<void> {
  const userEvents: Array<{ userId: string; events: InboxEvent[] }> = userIds
    .map((userId) => ({ userId, events: buildEvents(userId) }));

  await Promise.allSettled(
    userEvents.flatMap(({ userId, events }) =>
      events.map((event) => {
        const stub = env.CHAT_ROOM.get(env.CHAT_ROOM.idFromName(`inbox:${userId}`));
        return stub.fetch(new Request('https://internal/broadcast', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(event),
        }));
      }),
    ),
  );
}
