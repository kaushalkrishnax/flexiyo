/**
 * Scenario definition and CLI parsing for the Flexiyo load test.
 *
 * One "user-day" is: open the app, seed the inbox, open the day's chats, send
 * messages (with typing indicators and delivery acks), and read them. All users
 * in a run perform their day at the same time, so the run's totals are the
 * daily totals for `--users` daily active users.
 */

export const DEFAULT_SCENARIO = {
  users: 50,
  concurrency: 10,
  chatsPerDay: 3,
  messagesPerDay: 20,
  heartbeatsPerDay: 4,
  /** typing_start + typing_stop for every message. */
  typingEventsPerMessage: 2,
  heartbeatsEnabled: true,
  requestTimeoutMs: 30_000,
  jitterMs: 20,
  /** Modeled wall-clock time a DO stays active per request (compute-duration estimate). */
  doActiveMs: 25,
  cronRuns: 24,
  sendCron: false,
  rowsReadLimit: 5_000_000,
  rowsWrittenLimit: 100_000,
  baseUrl: 'http://localhost:8787',
  reuse: false,
  allowRemote: false,
  resultsDir: null,
  stateFile: null,
  help: false,
};

export function usage() {
  return `Flexiyo load test — simulate N users' daily activity and project Cloudflare free-plan usage.

Usage:
  bun run loadtest [options]

Options:
  --users <n>            Daily active users to simulate (default ${DEFAULT_SCENARIO.users})
  --concurrency <n>      Users processed in parallel (default ${DEFAULT_SCENARIO.concurrency})
  --chats <n>            Conversations each user has and sends in per day (default ${DEFAULT_SCENARIO.chatsPerDay})
  --messages <n>         Messages each user sends per day (default ${DEFAULT_SCENARIO.messagesPerDay})
  --heartbeats <n>       Client ping/pong frames per user-day (default ${DEFAULT_SCENARIO.heartbeatsPerDay})
  --base-url <url>       Worker URL (default ${DEFAULT_SCENARIO.baseUrl})
  --reuse                Reuse the users/tokens from the previous run (no new signups)
  --cron                 Also invoke the scheduled handler (requires --test-scheduled)
  --cron-runs <n>        Scheduled invocations to fire (default ${DEFAULT_SCENARIO.cronRuns})
  --jitter-ms <n>        Random pause between messages (default ${DEFAULT_SCENARIO.jitterMs})
  --do-active-ms <n>     Modeled DO active wall time per request (default ${DEFAULT_SCENARIO.doActiveMs})
  --timeout-ms <n>       Per-request timeout (default ${DEFAULT_SCENARIO.requestTimeoutMs})
  --rows-read-limit <n>  D1 rows-read/day limit to project against (default ${DEFAULT_SCENARIO.rowsReadLimit})
  --rows-written-limit <n> D1 rows-written/day limit (default ${DEFAULT_SCENARIO.rowsWrittenLimit})
  --allow-remote         Permit seeding users against a non-localhost target
  --help                 Show this help

Local runs sign up synthetic users (lt_<run>_<n>) and seed devices/conversations.
Run \`bun run dev\` first. Use --reuse to repeat the measurement without new users.`;
}

function number(value, name) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    throw new Error(`${name} must be a positive integer`);
  }
  return parsed;
}

export function parseArgs(argv) {
  const options = { ...DEFAULT_SCENARIO };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const [flag, inline] = arg.split('=', 2);
    const value = () => {
      if (inline !== undefined) return inline;
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) throw new Error(`${flag} requires a value`);
      i += 1;
      return next;
    };

    switch (flag) {
      case '--users':
        options.users = number(value(), '--users');
        break;
      case '--concurrency':
        options.concurrency = number(value(), '--concurrency');
        break;
      case '--chats':
        options.chatsPerDay = number(value(), '--chats');
        break;
      case '--messages':
        options.messagesPerDay = number(value(), '--messages');
        break;
      case '--heartbeats':
        options.heartbeatsPerDay = Math.max(0, Number.parseInt(value(), 10) || 0);
        break;
      case '--base-url':
        options.baseUrl = value().replace(/\/$/, '');
        break;
      case '--reuse':
        options.reuse = true;
        break;
      case '--cron':
        options.sendCron = true;
        break;
      case '--cron-runs':
        options.cronRuns = number(value(), '--cron-runs');
        break;
      case '--jitter-ms':
        options.jitterMs = Math.max(0, Number.parseInt(value(), 10) || 0);
        break;
      case '--do-active-ms':
        options.doActiveMs = number(value(), '--do-active-ms');
        break;
      case '--timeout-ms':
        options.requestTimeoutMs = number(value(), '--timeout-ms');
        break;
      case '--rows-read-limit':
        options.rowsReadLimit = number(value(), '--rows-read-limit');
        break;
      case '--rows-written-limit':
        options.rowsWrittenLimit = number(value(), '--rows-written-limit');
        break;
      case '--allow-remote':
        options.allowRemote = true;
        break;
      case '--help':
      case '-h':
        options.help = true;
        break;
      default:
        throw new Error(`Unknown option: ${arg}`);
    }
  }

  if (options.users < 2) {
    throw new Error('--users must be at least 2 (a conversation needs two accounts)');
  }
  if (options.chatsPerDay > options.users - 1) {
    options.chatsPerDay = Math.max(1, options.users - 1);
  }
  return options;
}
