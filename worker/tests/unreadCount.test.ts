import { SELF } from 'cloudflare:test';
import { beforeEach, describe, expect, it } from 'vitest';
import {
  db,
  resetDatabase,
  seedConversation,
  seedDevice,
  seedMessage,
  seedUser,
  tokenFor,
} from './support.js';

const ALICE = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const BOB = 'bbbbbbbb-bbbb-4bbb-9bbb-bbbbbbbbbbbb';
const CONVERSATION = 'ffffffff-ffff-4fff-8fff-ffffffffffff';
const MESSAGE = '11111111-1111-4111-8111-111111111111';

let aliceDeviceA = 0;
let aliceDeviceB = 0;
let bobDevice = 0;

async function addDelivery(id: string, deviceId: number): Promise<void> {
  await db
    .prepare(
      `INSERT INTO message_deliveries
         (id, message_id, recipient_device_id, payload, message_type, created_at)
       VALUES (?, ?, ?, 'ct', 'signal', 0)`,
    )
    .bind(id, MESSAGE, deviceId)
    .run();
}

async function get(path: string): Promise<Response> {
  return SELF.fetch(
    new Request(`https://example.com${path}`, {
      headers: { Authorization: `Bearer ${await tokenFor(ALICE)}` },
    }),
  );
}

beforeEach(async () => {
  await resetDatabase();
  await seedUser(ALICE);
  await seedUser(BOB);
  aliceDeviceA = await seedDevice(ALICE, 'install-alice-a');
  aliceDeviceB = await seedDevice(ALICE, 'install-alice-b');
  bobDevice = await seedDevice(BOB, 'install-bob');
  await seedConversation(CONVERSATION, ALICE, BOB);
  // Bob's message is delivered to both of Alice's devices.
  await seedMessage(MESSAGE, CONVERSATION, BOB, { senderDeviceId: bobDevice });
});

describe('unread counts', () => {
  it('counts a message once even when several recipient devices have a delivery', async () => {
    await addDelivery('delivery-a', aliceDeviceA);
    await addDelivery('delivery-b', aliceDeviceB);

    const detail = await get(`/api/conversations/${CONVERSATION}`);
    expect(detail.status).toBe(200);
    expect(await detail.json()).toMatchObject({ unreadCount: 1 });

    const list = await get('/api/conversations');
    expect(list.status).toBe(200);
    const rows = (await list.json()) as Array<{ id: string; unreadCount: number }>;
    expect(rows.find((row) => row.id === CONVERSATION)?.unreadCount).toBe(1);
  });

  it('drops to zero only when every recipient delivery is read', async () => {
    await addDelivery('delivery-a', aliceDeviceA);
    await addDelivery('delivery-b', aliceDeviceB);

    await db
      .prepare("UPDATE message_deliveries SET read_at = 1 WHERE id = 'delivery-a'")
      .run();
    const partial = await get(`/api/conversations/${CONVERSATION}`);
    expect(await partial.json()).toMatchObject({ unreadCount: 1 });

    await db
      .prepare("UPDATE message_deliveries SET read_at = 1 WHERE id = 'delivery-b'")
      .run();
    const done = await get(`/api/conversations/${CONVERSATION}`);
    expect(await done.json()).toMatchObject({ unreadCount: 0 });
  });
});
