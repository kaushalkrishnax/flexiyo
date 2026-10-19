/**
 * Turns measured client traffic + modeled server costs into a free-plan
 * projection report. Also measures the local D1 SQLite file so storage growth
 * is a real number rather than an estimate.
 */
import { readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { LIMITS, LIMIT_NOTES } from './limits.js';

const integer = new Intl.NumberFormat('en-US');

const num = (value) => integer.format(Math.round(value));

function bytes(value) {
  if (value < 1024) return `${num(value)} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KB`;
  if (value < 1024 * 1024 * 1024) return `${(value / (1024 * 1024)).toFixed(1)} MB`;
  return `${(value / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

const gbs = (value) => (value >= 100 ? num(value) : value.toFixed(1));
const percent = (value) => (value > 0 && value < 0.001 ? '<0.1%' : `${(value * 100).toFixed(1)}%`);
const usersText = (value) => (Number.isFinite(value) ? `~${num(value)} users/day` : '—');

function table(headers, rows) {
  const cells = rows.map((row) => row.map((cell) => String(cell)));
  const widths = headers.map((header, index) =>
    Math.max(header.length, ...cells.map((row) => row[index]?.length ?? 0)),
  );
  const line = (row, header = false) =>
    row
      .map((cell, index) => {
        const text = String(cell);
        if (index === 0) return text.padEnd(widths[index]);
        return text.padStart(widths[index]);
      })
      .join('  ')
      .trimEnd();
  return [line(headers, true), widths.map((width) => '─'.repeat(width)).join('  '), ...cells.map((row) => line(row))].join('\n');
}

function findSqliteFile(directory) {
  let best = null;
  let bestSize = -1;
  const walk = (dir) => {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full);
      } else if (entry.name.endsWith('.sqlite') && entry.name !== 'metadata.sqlite') {
        const size = statSync(full).size;
        if (size > bestSize) {
          best = full;
          bestSize = size;
        }
      }
    }
  };
  walk(directory);
  return best;
}

const D1_TABLES = [
  'users',
  'devices',
  'pre_keys',
  'conversations',
  'messages',
  'message_deliveries',
  'local_deletions',
  'message_reactions',
  'media',
  'media_views',
  'daily_usage',
  'worker_meta',
];

export async function measureLocalD1(workerDir) {
  if (typeof Bun === 'undefined') return null;
  let Database;
  try {
    ({ Database } = await import('bun:sqlite'));
  } catch {
    return null;
  }
  const file = findSqliteFile(join(workerDir, '.wrangler', 'state', 'v3', 'd1'));
  if (!file) return null;

  // Fold the write-ahead log back into the main file first: otherwise the byte
  // delta reports WAL churn instead of stored data.
  try {
    const db = new Database(file);
    try {
      db.run('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      db.close();
    }
  } catch {
    // Locked or read-only; measure whatever is on disk.
  }

  const size = (path) => {
    try {
      return statSync(path).size;
    } catch {
      return 0;
    }
  };
  const bytesOnDisk = size(file) + size(`${file}-wal`);
  let db;
  try {
    db = new Database(file, { readonly: true });
    const rows = {};
    for (const tableName of D1_TABLES) {
      try {
        rows[tableName] = db.query(`SELECT COUNT(*) AS n FROM ${tableName}`).get().n;
      } catch {
        // Table missing in this schema version.
      }
    }
    return { file, bytes: bytesOnDisk, rows };
  } catch {
    return null;
  } finally {
    try {
      db?.close();
    } catch {
      // ignore
    }
  }
}

export function buildReport(context) {
  const { args, run, setup, reusedAccounts = false, startedAt, elapsedMs, d1Before, d1AfterSetup, d1After, resultFile } = context;
  const users = args.users;

  const doConnections = run.get('do.connections');
  const doWsMessages = run.get('do.wsMessagesIn');
  const doFanout = run.get('do.fanout');
  const doHeartbeats = run.get('ws.heartbeats.autoResponse');
  const doRaw = doConnections + doWsMessages + doFanout;
  const doAdjusted =
    doConnections + Math.ceil(doWsMessages / LIMITS.durableObjects.wsMessageBillingRatio) + doFanout;
  const computeGbSeconds = doRaw * (args.doActiveMs / 1000) * 0.125;

  const workerRequests = run.get('worker.requests');
  const d1Read = run.get('d1.rowsRead');
  const d1Written = run.get('d1.rowsWritten');

  const storageBytes = d1After && d1AfterSetup ? Math.max(0, d1After.bytes - d1AfterSetup.bytes) : 0;
  /** Days at this user volume until the 5 GB free D1 storage is full. */
  const storageDaysToCap = storageBytes > 0 ? users / (storageBytes / (LIMITS.d1.storageGb * 1e9)) : Infinity;
  const storagePerUserDay = storageBytes / users;
  const messagesSent = run.get('messages.sent');
  const messagesReceived = run.get('messages.received');
  const messagesAcked = run.get('ws.delivery_ack');
  const frameBytesOut = run.get('ws.bytesSent');
  const frameBytesIn = run.get('ws.bytesReceived');
  const frameStatOut = run.stat('ws.frameBytesSent');
  const frameStatIn = run.stat('ws.frameBytesReceived');

  const perUserDay = {
    workerRequests: workerRequests / users,
    doConnections: doConnections / users,
    doWsMessages: doWsMessages / users,
    doFanout: doFanout / users,
    doTotalRaw: doRaw / users,
    doTotalAdjusted: doAdjusted / users,
    messagesSent: messagesSent / users,
    messagesReceived: messagesReceived / users,
    d1RowsRead: d1Read / users,
    d1RowsWritten: d1Written / users,
    d1StorageBytes: storagePerUserDay,
  };

  const hitsAt = (perUserValue, cap) =>
    perUserValue > 0 ? cap / perUserValue : Infinity;

  const opRows = [
    ['auth.me (session check)', run.get('auth.me'), 'measured'],
    ['conversations.seed (scope=all)', run.get('conversations.seed'), 'measured'],
    ['messages.list (history)', run.get('messages.list'), 'measured'],
    ['messages.read (receipts)', run.get('messages.read'), 'measured'],
    ['ws.connect (inbox)', run.get('ws.connect.inbox'), 'measured'],
    ['ws.connect (chat)', run.get('ws.connect.chat'), 'measured'],
    ['ws.send_message', run.get('ws.send_message'), 'measured'],
    ['ws.typing_start + typing_stop', run.get('ws.typing'), 'measured'],
    ['ws.delivery_ack', run.get('ws.delivery_ack'), 'measured'],
    ['ws.heartbeat (auto-response)', run.get('ws.heartbeats.autoResponse'), 'not billed'],
  ].map(([label, count, source]) => [label, (count / users).toFixed(2), source]);

  const doRows = [
    ['WS connection requests', (doConnections / users).toFixed(2), 'measured'],
    ['Incoming WS messages', (doWsMessages / users).toFixed(2), 'measured'],
    ['DO fan-out fetches (Worker → DO)', (doFanout / users).toFixed(2), 'modeled'],
    ['Heartbeats (runtime auto-response)', (doHeartbeats / users).toFixed(2), 'not billed'],
  ];

  const latencyRows = [...run.samples.entries()]
    .filter(([name]) => !name.startsWith('ws.frameBytes'))
    .map(([name, samples]) => ({ name, stat: run.stat(name), samples: samples.length }))
    .sort((a, b) => b.samples - a.samples)
    .slice(0, 14)
    .map(({ name, stat }) => [
      name,
      stat.p50.toFixed(1),
      stat.p95.toFixed(1),
      stat.max.toFixed(1),
      num(stat.count),
    ]);

  const limitRows = [
    {
      label: 'DO requests — raw',
      used: doRaw,
      cap: LIMITS.durableObjects.requestsPerDay,
      unit: '',
      reaches: usersText(hitsAt(doRaw / users, LIMITS.durableObjects.requestsPerDay)),
      atUsers: hitsAt(doRaw / users, LIMITS.durableObjects.requestsPerDay),
      note: 'connections + incoming WS messages + fan-out',
    },
    {
      label: 'DO requests — WS ÷ 20',
      used: doAdjusted,
      cap: LIMITS.durableObjects.requestsPerDay,
      unit: '',
      reaches: usersText(hitsAt(doAdjusted / users, LIMITS.durableObjects.requestsPerDay)),
      atUsers: hitsAt(doAdjusted / users, LIMITS.durableObjects.requestsPerDay),
      note: 'if the free cap applies the 20:1 WS ratio',
    },
    {
      label: 'DO compute duration',
      used: computeGbSeconds,
      cap: LIMITS.durableObjects.computeGbSecondsPerDay,
      unit: ' GB-s',
      reaches: usersText(
        hitsAt(computeGbSeconds / users, LIMITS.durableObjects.computeGbSecondsPerDay),
      ),
      atUsers: hitsAt(computeGbSeconds / users, LIMITS.durableObjects.computeGbSecondsPerDay),
      note: `modeled at ${args.doActiveMs} ms active/request`,
    },
    {
      label: 'DO SQL rows read',
      used: 0,
      cap: LIMITS.d1.rowsReadPerDay,
      unit: '',
      reaches: 'never (unused)',
      atUsers: Infinity,
      note: 'ChatRoom keeps no SQLite state',
    },
    {
      label: 'DO SQL rows written',
      used: 0,
      cap: LIMITS.d1.rowsWrittenPerDay,
      unit: '',
      reaches: 'never (unused)',
      atUsers: Infinity,
      note: 'ChatRoom keeps no SQLite state',
    },
    {
      label: 'DO SQL storage',
      used: 0,
      cap: LIMITS.durableObjects.storageGbPerAccount * 1e9,
      unit: '',
      bytes: true,
      reaches: 'never (unused)',
      atUsers: Infinity,
      note: 'WS attachments are not stored SQL data',
    },
    {
      label: 'DO classes',
      used: 1,
      cap: LIMITS.durableObjects.classes,
      unit: '',
      reaches: '—',
      atUsers: Infinity,
      note: 'ChatRoom only',
    },
    {
      label: 'Worker requests',
      used: workerRequests,
      cap: LIMITS.workers.requestsPerDay,
      unit: '',
      reaches: usersText(hitsAt(workerRequests / users, LIMITS.workers.requestsPerDay)),
      atUsers: hitsAt(workerRequests / users, LIMITS.workers.requestsPerDay),
      note: 'Worker/Pages free tier',
    },
    {
      label: 'D1 rows read',
      used: d1Read,
      cap: args.rowsReadLimit,
      unit: '',
      reaches: usersText(hitsAt(d1Read / users, args.rowsReadLimit)),
      atUsers: hitsAt(d1Read / users, args.rowsReadLimit),
      note: 'modeled from route SQL',
    },
    {
      label: 'D1 rows written',
      used: d1Written,
      cap: args.rowsWrittenLimit,
      unit: '',
      reaches: usersText(hitsAt(d1Written / users, args.rowsWrittenLimit)),
      atUsers: hitsAt(d1Written / users, args.rowsWrittenLimit),
      note: 'modeled from route SQL',
    },
    {
      label: 'D1 storage growth',
      used: storageBytes,
      cap: LIMITS.d1.storageGb * 1e9,
      unit: '',
      bytes: true,
      reaches:
        storageDaysToCap === Infinity ? '—' : `~${num(storageDaysToCap)} days at ${users} users/day`,
      atUsers: Infinity,
      note: 'measured from local D1 file',
    },
  ];

  const limitTable = table(
    ['free-plan limit', `used at ${users} users/day`, 'cap', 'used', 'reaches cap at'],
    limitRows.map((row) => [
      row.label,
      `${row.bytes ? bytes(row.used) : row.unit === ' GB-s' ? gbs(row.used) : num(row.used)}${row.bytes ? '' : row.unit}`,
      row.bytes ? '5 GB' : `${row.unit === ' GB-s' ? gbs(row.cap) : num(row.cap)}${row.unit}`,
      percent(row.cap ? row.used / row.cap : 0),
      row.reaches,
    ]),
  );

  const scoped = limitRows
    .filter((row) => Number.isFinite(row.atUsers) && row.atUsers > 0)
    .sort((a, b) => a.atUsers - b.atUsers);
  const firstLimit = scoped[0];
  const secondLimit = scoped[1];

  const fanoutShare = doRaw > 0 ? doFanout / doRaw : 0;
  const perMessageDo = messagesSent > 0 ? (doWsMessages + doFanout) / messagesSent : 0;

  const setupWorkerRequests = setup.get('worker.requests');
  const setupDo = setup.get('do.connections') + setup.get('do.wsMessagesIn') + setup.get('do.fanout');
  const setupConversations = setup.get('conversations.created');

  const verdict = [
    firstLimit
      ? `The first ceiling is ${firstLimit.label} at about ${num(firstLimit.atUsers)} daily active users ` +
        `(${percent(firstLimit.used / firstLimit.cap)} consumed by ${users} users/day).`
      : 'No free-tier ceiling is reachable with this activity model.',
    secondLimit ? `Next: ${secondLimit.label} at about ${num(secondLimit.atUsers)} users/day.` : '',
    `Each sent message costs ~${perMessageDo.toFixed(1)} DO requests, and inbox fan-out is ` +
      `${percent(fanoutShare)} of all DO requests at this mix — the first knob to turn if you approach the cap.`,
    storageBytes > 0
      ? `D1 grows by ${bytes(storagePerUserDay)} per user-day; at ${users} users/day the 5 GB free storage lasts ~${num(storageDaysToCap)} days.`
      : 'No measurable D1 storage growth during this run.',
  ]
    .filter(Boolean)
    .join('\n');

  const lines = [];
  lines.push('');
  lines.push(`Flexiyo load test — ${users} simulated user-days`);
  lines.push(`target      ${args.baseUrl}`);
  lines.push(`started     ${startedAt.toISOString()}`);
  lines.push(`wall time   ${(elapsedMs / 1000).toFixed(1)} s (concurrency ${args.concurrency})`);
  lines.push(`errors      ${run.get('errors')}`);
  lines.push('');
  lines.push('Measured client traffic');
  lines.push(
    table(
      ['metric', 'total', 'per user-day'],
      [
        ['Worker requests', num(workerRequests), (workerRequests / users).toFixed(2)],
        ['WS connections created', num(doConnections), (doConnections / users).toFixed(2)],
        ['WS frames sent → server', num(run.get('ws.framesSent')), (run.get('ws.framesSent') / users).toFixed(2)],
        ['WS frames received ← server', num(run.get('ws.framesReceived')), (run.get('ws.framesReceived') / users).toFixed(2)],
        ['Messages sent (send_message)', num(messagesSent), (messagesSent / users).toFixed(2)],
        ['Pushed to an open peer chat socket', num(messagesReceived), (messagesReceived / users).toFixed(2)],
        ['Inbox frames received', num(run.get('ws.inboxEvents')), (run.get('ws.inboxEvents') / users).toFixed(2)],
        ['Delivery acks sent', num(messagesAcked), (messagesAcked / users).toFixed(2)],
        ['Cron invocations', num(run.get('cron.runs')), (run.get('cron.runs') / users).toFixed(2)],
        ['Frame bytes sent / received', `${bytes(frameBytesOut)} / ${bytes(frameBytesIn)}`, '—'],
        [
          'Largest frame sent / received',
          `${bytes(frameStatOut?.max ?? 0)} / ${bytes(frameStatIn?.max ?? 0)}`,
          `platform cap ${LIMITS.durableObjects.wsMessageMiB} MiB`,
        ],
      ],
    ),
  );
  lines.push('');
  lines.push('Client operations per user-day');
  lines.push(table(['operation', 'count', 'source'], opRows));
  lines.push('');
  lines.push('Durable Object request sources per user-day');
  lines.push(table(['source', 'count', 'source'], doRows));
  lines.push('');
  if (latencyRows.length > 0) {
    lines.push('Wall-clock latency (ms; local dev, compressed day)');
    lines.push(table(['operation', 'p50', 'p95', 'max', 'n'], latencyRows));
    lines.push('');
  }
  lines.push(`Free-plan projection at ${users} users/day`);
  lines.push(limitTable);
  lines.push('');
  lines.push('What this means');
  lines.push(verdict);
  lines.push('');
  if (reusedAccounts) {
    lines.push(`Accounts reused from ${'.state.json'} (no seeding traffic in this run).`);
  } else {
    lines.push('One-time seeding (excluded from the daily projection)');
    lines.push(
      `  ${num(setupWorkerRequests)} Worker requests · ${num(setupDo)} DO requests · ` +
        `${num(setupConversations)} conversations for ${users} accounts`,
    );
    lines.push(
      `  If every one of the ${users} users/day is a brand-new account, add these setup costs to the daily totals.`,
    );
  }
  lines.push('');
  if (run.errors.length > 0) {
    lines.push('First errors');
    for (const error of run.errors.slice(0, 8)) {
      lines.push(`  [${error.op}] ${error.message}`);
    }
    lines.push('');
  }
  lines.push('Notes');
  for (const note of LIMIT_NOTES) lines.push(`  • ${note}`);
  lines.push('');
  lines.push(`Sources: ${LIMITS.durableObjects.source} · ${LIMITS.d1.source}`);
  if (resultFile) lines.push(`JSON results: ${resultFile}`);
  lines.push('');

  const data = {
    generatedAt: new Date().toISOString(),
    baseUrl: args.baseUrl,
    scenario: args,
    elapsedMs,
    counts: Object.fromEntries(run.counts),
    setupCounts: Object.fromEntries(setup.counts),
    perUserDay,
    latency: Object.fromEntries(
      [...run.samples.keys()].map((name) => [name, run.stat(name)]),
    ),
    projections: limitRows.map(({ label, used, cap, reaches, note }) => ({
      label,
      used,
      cap,
      reaches,
      note,
    })),
    d1: {
      before: d1Before,
      afterSetup: d1AfterSetup,
      after: d1After,
      growthBytes: storageBytes,
    },
    errors: run.errors,
  };

  return { text: lines.join('\n'), data };
}
