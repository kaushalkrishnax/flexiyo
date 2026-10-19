/**
 * Flexiyo load test entry point.
 *
 * Simulates one compressed day for N daily-active users against a locally
 * running Worker (`bun run dev`): sign up synthetic accounts, open inbox and
 * chat sockets, send/ack/read messages, then project the measured client
 * traffic plus the modeled server costs (costs.js) onto the Cloudflare
 * free-plan limits (limits.js).
 *
 * Usage: bun run loadtest [--users 50]   (see usage() in scenario.js)
 */

import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { HttpError, LoadClient, Metrics, isLocalTarget, sleep } from './client.js';
import { D1, DO_FANOUT } from './costs.js';
import { parseArgs, usage } from './scenario.js';
import { buildReport, measureLocalD1 } from './report.js';

const HERE = dirname(fileURLToPath(import.meta.url));
const STATE_FILE = join(HERE, '.state.json');
const RESULTS_DIR = join(HERE, 'results');
const WORKER_DIR = join(HERE, '..', '..', 'worker');

const PRE_KEYS_PER_DEVICE = 5;
/** Lets in-flight delivery acks land before the read pass. */
const SETTLE_MS = 400;
const CRON_EXPRESSION = '0 * * * *';
const SOCKET_OPEN = 1;

const randomBase64 = (length) =>
  Buffer.from(crypto.getRandomValues(new Uint8Array(length))).toString('base64');
const randomInt = (min, max) => min + Math.floor(Math.random() * (max - min + 1));
const jitter = (ms) => sleep(ms > 0 ? randomInt(0, ms) : 0);
const seconds = (started) => `${((performance.now() - started) / 1000).toFixed(1)}s`;

function errorReporter(limit = 5) {
  let shown = 0;
  return (error) => {
    shown += 1;
    if (shown <= limit) console.error(`  ! ${error?.message ?? error}`);
    if (shown === limit + 1) console.error('  ! … further errors suppressed');
  };
}

async function pool(items, concurrency, task, onError = () => {}) {
  const queue = [...items];
  const workers = Array.from(
    { length: Math.max(1, Math.min(concurrency, queue.length)) },
    async () => {
      for (let item = queue.shift(); item !== undefined; item = queue.shift()) {
        try {
          await task(item);
        } catch (error) {
          onError(error);
        }
      }
    },
  );
  await Promise.all(workers);
}

/** The Worker's auth rate limiter is per-IP per-isolate; unique IPs keep seeding fast. */
async function retry429(task, attempts = 30) {
  for (let attempt = 0; ; attempt += 1) {
    try {
      return await task();
    } catch (error) {
      const retryable = error instanceof HttpError && error.status === 429;
      if (!retryable || attempt >= attempts) throw error;
      await sleep(error.retryAfterMs ?? 1_500);
    }
  }
}

async function preflight(baseUrl, timeoutMs) {
  let response;
  try {
    response = await fetch(new URL('/health', baseUrl), { signal: AbortSignal.timeout(timeoutMs) });
  } catch (error) {
    throw new Error(`Cannot reach ${baseUrl} (${error?.message ?? error}). Start it with "bun run dev".`);
  }
  await response.text();
  if (!response.ok) {
    throw new Error(`${baseUrl}/health returned ${response.status}. Start the Worker with "bun run dev".`);
  }
}

// ---------------------------------------------------------------------------
// Account + conversation seeding (one-time cost, reported separately)
// ---------------------------------------------------------------------------

/**
 * Ring steps where every family is symmetric (`±d`), so both sides of every
 * conversation are open during the day and a message always lands on the peer's
 * socket. Each user ends up with `chats` partners (`chats + 1` for odd chat
 * counts on an odd user count, where an exact fit is arithmetically impossible).
 */
export function conversationSteps(users, chats) {
  const steps = [];
  let remaining = chats;
  if (users % 2 === 0 && chats % 2 === 1) {
    steps.push(users / 2);
    remaining -= 1;
  }
  for (let step = 1; remaining > 0 && step <= Math.floor(users / 2); step += 1) {
    if (step * 2 === users) continue;
    steps.push(step);
    remaining -= 2;
  }
  return steps;
}

export function conversationPairs(users, chats) {
  const pairs = [];
  const seen = new Set();
  const steps = conversationSteps(users, chats);
  for (let i = 0; i < users; i += 1) {
    for (const step of steps) {
      const j = (i + step) % users;
      if (j === i) continue;
      const key = i < j ? `${i}:${j}` : `${j}:${i}`;
      if (seen.has(key)) continue;
      seen.add(key);
      pairs.push({ a: i, b: j });
    }
  }
  return pairs;
}

function clientFor(args, metrics, user) {
  return new LoadClient({
    baseUrl: args.baseUrl,
    metrics,
    token: user.token ?? null,
    userId: user.userId ?? null,
    username: user.username ?? null,
    installationId: user.installationId ?? null,
    deviceId: user.deviceId ?? null,
    ip: user.ip,
    timeoutMs: args.requestTimeoutMs,
  });
}

async function seedUser(args, setup, user) {
  const client = clientFor(args, setup, user);
  const registration = await retry429(() =>
    client.http('POST', '/api/auth/register', {
      body: { username: user.username, password: user.password },
      op: 'setup.register',
    }),
  );
  D1.signup(setup);

  user.userId = registration.json.user.id;
  user.token = registration.json.token;
  client.token = user.token;
  client.userId = user.userId;
  client.username = user.username;

  const device = await retry429(() =>
    client.http('POST', '/api/devices/register', {
      op: 'setup.device',
      body: {
        installationId: user.username,
        identityKey: randomBase64(32),
        registrationId: randomInt(1, 16_380),
        signedPreKey: { keyId: 1, publicKey: randomBase64(32), signature: randomBase64(64) },
        preKeys: Array.from({ length: PRE_KEYS_PER_DEVICE }, (_, index) => ({
          keyId: index + 1,
          publicKey: randomBase64(32),
        })),
        activate: true,
      },
    }),
  );
  D1.authRequest(setup);
  D1.deviceRegister(setup, { preKeys: PRE_KEYS_PER_DEVICE });

  user.installationId = device.json.installationId;
  user.deviceId = device.json.deviceId;
  user.client = client;
}

async function seedConversations(args, setup, users) {
  const conversations = [];
  await pool(
    conversationPairs(args.users, args.chatsPerDay),
    args.concurrency,
    async ({ a, b }) => {
      const initiator = users[a];
      const responder = users[b];
      const created = await initiator.client.http('POST', '/api/conversations', {
        body: { participantId: responder.userId },
        op: 'setup.conversation',
      });
      D1.authRequest(setup);
      D1.conversationCreate(setup);
      setup.count('do.fanout', DO_FANOUT.conversationCreate);

      const conversation = { id: created.json.id, a, b };
      conversations.push(conversation);
      setup.count('conversations.created');

      if (created.json.requestStatus === 'pending') {
        await responder.client.http('PATCH', `/api/conversations/${conversation.id}/request`, {
          body: { action: 'accept' },
          op: 'setup.accept',
        });
        D1.authRequest(setup);
        D1.requestDecision(setup);
        setup.count('do.fanout', DO_FANOUT.requestDecision);
        setup.count('conversations.accepted');
      }
    },
    errorReporter(),
  );
  conversations.sort((left, right) => left.a - right.a || left.b - right.b);
  return conversations;
}

async function seed(args, setup) {
  const runId = randomBase64(4).replace(/[^a-z0-9]/gi, '').slice(0, 6).toLowerCase();
  const users = Array.from({ length: args.users }, (_, index) => ({
    index,
    username: `lt_${runId}_${index}`,
    password: `${runId}-lt-${index}-pw`,
    ip: `10.55.${(index >> 8) & 255}.${(index & 255) + 1}`,
  }));

  let started = performance.now();
  await pool(users, args.concurrency, (user) => seedUser(args, setup, user), errorReporter());
  console.log(`  accounts   ${users.filter((user) => user.token).length}/${args.users} in ${seconds(started)}`);

  started = performance.now();
  const conversations = await seedConversations(args, setup, users);
  console.log(`  chats      ${conversations.length} in ${seconds(started)}`);

  return { runId, createdAt: new Date().toISOString(), users, conversations };
}

// ---------------------------------------------------------------------------
// State file (--reuse)
// ---------------------------------------------------------------------------

function readState() {
  if (!existsSync(STATE_FILE)) return null;
  try {
    return JSON.parse(readFileSync(STATE_FILE, 'utf8'));
  } catch {
    return null;
  }
}

function saveState(state) {
  const users = state.users.map((user) => ({
    index: user.index,
    username: user.username,
    password: user.password,
    ip: user.ip,
    userId: user.userId,
    token: user.token,
    installationId: user.installationId,
    deviceId: user.deviceId,
  }));
  writeFileSync(
    STATE_FILE,
    JSON.stringify({ version: 1, runId: state.runId, createdAt: state.createdAt, users, conversations: state.conversations }, null, 2),
  );
}

function stateMatches(state, args) {
  if (!Array.isArray(state?.users) || !Array.isArray(state?.conversations)) return false;
  if (state.users.length < args.users) return false;
  const needed = Math.min(args.chatsPerDay, args.users - 1);
  for (let index = 0; index < args.users; index += 1) {
    const count = state.conversations.filter((c) => c.a === index || c.b === index).length;
    if (count < needed) return false;
  }
  return state.users.slice(0, args.users).every((user) => user.token && user.deviceId);
}

/** Per-user day context: socket set plus the peer each conversation is with. */
function buildDayContext(state, args, run) {
  const users = state.users.slice(0, args.users);
  return users.map((user, index) => {
    const conversations = state.conversations
      .filter((c) => (c.a === index || c.b === index) && c.a < users.length && c.b < users.length)
      .map((c) => ({
        conversation: c,
        peer: users[c.a === index ? c.b : c.a],
      }))
      .sort((left, right) => left.peer.index - right.peer.index)
      .slice(0, args.chatsPerDay)
      .map((entry) => ({ ...entry, socket: null, unread: 0, acked: new Set() }));

    return {
      user,
      client: clientFor(args, run, user),
      inbox: null,
      chats: conversations,
      me: user.userId,
    };
  });
}

// ---------------------------------------------------------------------------
// Day phases
// ---------------------------------------------------------------------------

async function openSockets(ctx, args, run) {
  const { client } = ctx;
  await client.http('GET', '/api/auth/me', { op: 'auth.me' });
  D1.authRequest(run);
  D1.authMe(run);

  const seed = await client.http('GET', '/api/conversations?scope=all', { op: 'conversations.seed' });
  D1.authRequest(run);
  const returned = (seed.json?.conversations?.length ?? 0) + (seed.json?.requests?.length ?? 0);
  D1.conversationsSeed(run, { returned });

  const token = encodeURIComponent(client.token);
  const inbox = client.connect(`/api/ws/inbox?token=${token}&deviceId=${client.deviceId}`, {
    op: 'ws.connect.inbox',
    onFrame: (frame) => {
      if (frame?.type !== 'connected') run.count('ws.inboxEvents');
    },
  });
  await inbox.ready;
  run.count('ws.connect.inbox');
  D1.wsConnect(run, { chat: false });
  ctx.inbox = inbox;

  for (const chat of ctx.chats) {
    const { conversation } = chat;
    const socket = client.connect(
      `/api/ws/${conversation.id}?token=${token}&deviceId=${client.deviceId}`,
      { op: 'ws.connect.chat', onFrame: (frame) => onChatFrame(frame, ctx, chat, run) },
    );
    await socket.ready;
    run.count('ws.connect.chat');
    D1.wsConnect(run, { chat: true });
    chat.socket = socket;

    const history = await client.http('GET', `/api/conversations/${conversation.id}/messages?limit=50`, {
      op: 'messages.list',
    });
    D1.authRequest(run);
    D1.messageList(run, { returned: Array.isArray(history.json) ? history.json.length : 0 });
  }
}

/** Recipient side: a peer's message lands here, so acknowledge it like the app does. */
function onChatFrame(frame, ctx, chat, run) {
  if (frame?.type !== 'new_message' || frame.senderId === ctx.me) return;
  run.count('messages.received');
  chat.unread += 1;
  if (chat.acked.has(frame.messageId)) return;
  chat.acked.add(frame.messageId);
  if (chat.socket?.send({ type: 'delivery_ack', messageId: frame.messageId })) {
    run.count('ws.delivery_ack');
    D1.deliveryAck(run);
  }
}

async function sendMessages(ctx, args, run) {
  const chats = ctx.chats.filter((chat) => chat.socket?.socket.readyState === SOCKET_OPEN);
  if (chats.length === 0) return;

  for (let index = 0; index < args.messagesPerDay; index += 1) {
    const chat = chats[index % chats.length];
    chat.socket.send({ type: 'typing_start' }, { op: 'ws.typing' });
    run.count('ws.typing');
    await jitter(args.jitterMs);

    const response = await chat.socket.request(
      {
        type: 'send_message',
        conversationId: chat.conversation.id,
        id: crypto.randomUUID(),
        recipientId: chat.peer.userId,
        payloads: [
          { deviceId: chat.peer.deviceId, ciphertext: randomBase64(128), messageType: 'signal' },
        ],
        messageType: 'signal',
      },
      { op: 'ws.send_message' },
    );

    if (response.ok === true) {
      run.count('messages.sent');
      D1.wsSendMessage(run);
      run.count('do.fanout', DO_FANOUT.sendMessage);
    } else {
      run.recordError('ws.send_message', `${response.type}/${response.code ?? 'unknown'}`);
    }

    chat.socket.send({ type: 'typing_stop' }, { op: 'ws.typing' });
    run.count('ws.typing');
    await jitter(args.jitterMs);
  }
}

async function readChats(ctx, run) {
  for (const chat of ctx.chats) {
    const response = await ctx.client.http('POST', `/api/conversations/${chat.conversation.id}/read`, {
      body: {},
      op: 'messages.read',
    });
    if (response.json?.read !== true) continue;
    D1.authRequest(run);
    D1.readReceipt(run, { unread: chat.unread });
    run.count('do.fanout', DO_FANOUT.readReceipt);
    chat.unread = 0;
  }
}

async function sendHeartbeats(ctx, args, run) {
  const chat = ctx.chats[0];
  if (!chat?.socket) return;
  for (let index = 0; index < args.heartbeatsPerDay; index += 1) {
    await chat.socket.ping();
    await jitter(args.jitterMs);
  }
}

function closeSockets(ctx) {
  for (const chat of ctx.chats) chat.socket?.close();
  ctx.inbox?.close();
}

async function fireCron(args, run) {
  for (let index = 0; index < args.cronRuns; index += 1) {
    const url = new URL('/__scheduled', args.baseUrl);
    url.searchParams.set('cron', CRON_EXPRESSION);
    let response;
    try {
      response = await fetch(url, { signal: AbortSignal.timeout(args.requestTimeoutMs) });
    } catch (error) {
      console.warn(`  ! cron trigger failed: ${error?.message ?? error}`);
      return;
    }
    await response.text();
    if (!response.ok) {
      console.warn(
        `  ! /__scheduled returned ${response.status}; run "bunx wrangler dev --test-scheduled" to enable it`,
      );
      return;
    }
    run.count('cron.runs');
    D1.cron(run);
  }
}

// ---------------------------------------------------------------------------

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    console.log(usage());
    return;
  }
  if (!isLocalTarget(args.baseUrl) && !args.allowRemote) {
    throw new Error(`Refusing to create accounts on ${args.baseUrl}; pass --allow-remote if intentional.`);
  }
  await preflight(args.baseUrl, args.requestTimeoutMs);

  const startedAt = new Date();
  const run = new Metrics();
  const setup = new Metrics();
  const d1Before = await measureLocalD1(WORKER_DIR);

  let state = args.reuse ? readState() : null;
  let reusedAccounts = false;
  if (state && stateMatches(state, args)) {
    reusedAccounts = true;
    console.log(`Reusing ${args.users} accounts from ${STATE_FILE}`);
  } else {
    if (args.reuse) console.warn('Saved accounts do not match this scenario; seeding fresh ones.');
    state = await seed(args, setup);
    saveState(state);
  }
  const d1AfterSetup = reusedAccounts ? d1Before : await measureLocalD1(WORKER_DIR);

  const contexts = buildDayContext(state, args, run);
  const dayStarted = performance.now();
  const onError = errorReporter();
  try {
    let started = performance.now();
    await pool(contexts, args.concurrency, (ctx) => openSockets(ctx, args, run), onError);
    console.log(`  sockets    ${contexts.filter((ctx) => ctx.inbox).length}/${args.users} inbox, ${contexts.reduce((sum, ctx) => sum + ctx.chats.filter((chat) => chat.socket).length, 0)} chat in ${seconds(started)}`);

    started = performance.now();
    await pool(contexts, args.concurrency, (ctx) => sendMessages(ctx, args, run), onError);
    console.log(`  messages   ${run.get('messages.sent')} sent, ${run.get('messages.received')} received in ${seconds(started)}`);

    await sleep(SETTLE_MS);

    started = performance.now();
    await pool(contexts, args.concurrency, (ctx) => readChats(ctx, run), onError);
    console.log(`  reads      ${run.get('messages.read')} in ${seconds(started)}`);

    started = performance.now();
    await pool(contexts, args.concurrency, (ctx) => sendHeartbeats(ctx, args, run), onError);
    console.log(`  heartbeats ${run.get('ws.ping')} in ${seconds(started)}`);

    if (args.sendCron) {
      started = performance.now();
      await fireCron(args, run);
      console.log(`  cron       ${run.get('cron.runs')}/${args.cronRuns} in ${seconds(started)}`);
    }
  } finally {
    for (const ctx of contexts) closeSockets(ctx);
  }

  const elapsedMs = performance.now() - dayStarted;
  const d1After = await measureLocalD1(WORKER_DIR);
  const stamp = startedAt.toISOString().replace(/[:.]/g, '-');
  const resultFile = join(RESULTS_DIR, `run-${stamp}.json`);
  const report = buildReport({
    args,
    run,
    setup,
    reusedAccounts,
    startedAt,
    elapsedMs,
    d1Before,
    d1AfterSetup,
    d1After,
    resultFile,
  });
  mkdirSync(RESULTS_DIR, { recursive: true });
  writeFileSync(resultFile, JSON.stringify(report.data, null, 2));
  console.log(report.text);
}

if (import.meta.main) await main();
