import type { Env } from '../types.js';

/**
 * Firebase Cloud Messaging (HTTP v1) delivery for offline notifications.
 *
 * Configuration comes from the `FCM_SERVICE_ACCOUNT` secret: the JSON key
 * generated in Firebase console → Project settings → Service accounts →
 * Generate new private key (project `flexiyo-app`). Without the secret,
 * pushes are skipped so messaging keeps working.
 *
 * The OAuth access token is cached per isolate (1-hour lifetime).
 *
 * Diagnostics never include secrets (tokens, private keys, JWTs, access
 * tokens); tokens are identified by their position in the delivery batch.
 */

interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

export interface PushNotification {
  title: string;
  body: string;
  data?: Record<string, string>;
}

/** Subset of the FCM HTTP v1 error envelope used for classification. */
interface FcmErrorBody {
  error?: {
    status?: string;
    message?: string;
    details?: Array<{ errorCode?: string }>;
  };
}

/**
 * `pruned` and `auth_error` are both permanent for the request but differ in
 * cause: a pruned token is deleted, an auth error is a configuration problem
 * that must never delete tokens.
 */
type FcmOutcome = 'accepted' | 'pruned' | 'auth_error' | 'transient' | 'rejected';

interface FcmAttempt {
  outcome: FcmOutcome;
  status?: number;
  errorCode?: string;
  detail?: string;
}

let cachedAccessToken: { key: string; value: string; expiresAt: number } | null = null;
let warnedMissingConfig = false;

function base64UrlEncode(input: ArrayBuffer | Uint8Array | string): string {
  const bytes =
    typeof input === 'string'
      ? new TextEncoder().encode(input)
      : input instanceof Uint8Array
        ? input
        : new Uint8Array(input);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function privateKeyToArrayBuffer(pem: string): ArrayBuffer {
  const base64 = pem
    .replace('-----BEGIN PRIVATE KEY-----', '')
    .replace('-----END PRIVATE KEY-----', '')
    .replace(/\s+/g, '');
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

function truncate(value: string, max = 200): string {
  return value.length <= max ? value : `${value.slice(0, max)}…`;
}

function parseServiceAccount(secret: string | undefined): ServiceAccount | null {
  if (!secret) {
    // Config absence is an intentional deployment state, not a per-message
    // fault: warn once so it is discoverable without spamming the logs.
    if (!warnedMissingConfig) {
      warnedMissingConfig = true;
      console.warn('FCM_SERVICE_ACCOUNT is not configured; push notifications are disabled');
    }
    return null;
  }

  let parsed: Partial<ServiceAccount>;
  try {
    parsed = JSON.parse(secret) as Partial<ServiceAccount>;
  } catch {
    console.error('FCM_SERVICE_ACCOUNT is not valid JSON; push notifications are disabled');
    return null;
  }

  if (!parsed.project_id || !parsed.client_email || !parsed.private_key) {
    console.error(
      'FCM_SERVICE_ACCOUNT is missing project_id, client_email or private_key; push notifications are disabled',
    );
    return null;
  }

  return {
    project_id: parsed.project_id,
    client_email: parsed.client_email,
    private_key: parsed.private_key,
  };
}

async function readOAuthError(response: Response): Promise<string> {
  const text = await response.text().catch(() => '');
  try {
    const parsed = JSON.parse(text) as {
      error?: unknown;
      error_description?: unknown;
    };
    const parts = [parsed.error, parsed.error_description].filter(
      (value): value is string => typeof value === 'string' && value.length > 0,
    );
    return parts.length > 0 ? truncate(parts.join(': ')) : '';
  } catch {
    // Never echo an arbitrary body: it could contain the assertion.
    return '';
  }
}

async function getAccessToken(account: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (
    cachedAccessToken &&
    cachedAccessToken.key === account.client_email &&
    cachedAccessToken.expiresAt - 60 > now
  ) {
    return cachedAccessToken.value;
  }

  const header = base64UrlEncode(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = base64UrlEncode(
    JSON.stringify({
      iss: account.client_email,
      scope: 'https://www.googleapis.com/auth/firebase.messaging',
      aud: 'https://oauth2.googleapis.com/token',
      iat: now,
      exp: now + 3600,
    }),
  );
  const signingInput = `${header}.${claims}`;

  const key = await crypto.subtle.importKey(
    'pkcs8',
    privateKeyToArrayBuffer(account.private_key),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    key,
    new TextEncoder().encode(signingInput),
  );
  const assertion = `${signingInput}.${base64UrlEncode(signature)}`;

  const tokenResponse = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: `grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=${assertion}`,
  });
  if (!tokenResponse.ok) {
    // Only Google's standard error fields are surfaced; the raw body is not
    // logged because a request could echo the signed assertion.
    const detail = await readOAuthError(tokenResponse);
    throw new Error(
      `FCM OAuth token exchange failed (${tokenResponse.status})${detail ? `: ${detail}` : ''}`,
    );
  }
  const tokenData = (await tokenResponse.json()) as {
    access_token: string;
    expires_in?: number;
  };
  cachedAccessToken = {
    key: account.client_email,
    value: tokenData.access_token,
    expiresAt: now + (tokenData.expires_in ?? 3600),
  };
  return cachedAccessToken.value;
}

async function readFcmError(response: Response): Promise<FcmErrorBody | null> {
  try {
    const text = await response.text();
    if (!text) return null;
    return JSON.parse(text) as FcmErrorBody;
  } catch {
    return null;
  }
}

/**
 * FCM returns `UNREGISTERED` (404) for tokens that are no longer installed or
 * have expired, and `INVALID_ARGUMENT` (400) when the registration token is
 * malformed. Both are permanent for this token. Everything else — auth,
 * quota, 5xx, network — must keep the token for a later retry.
 */
function isPermanentTokenFailure(
  status: number,
  errorCode: string | undefined,
  message: string,
): boolean {
  if (status === 404) return true;
  if (errorCode === 'UNREGISTERED') return true;
  if (status === 400 && errorCode === 'INVALID_ARGUMENT') return true;
  if (status === 400 && /registration token|invalid.*token/i.test(message)) return true;
  return false;
}

async function sendToToken(
  env: Env,
  account: ServiceAccount,
  accessToken: string,
  token: string,
  notification: PushNotification,
): Promise<FcmAttempt> {
  let response: Response;
  try {
    response = await fetch(
      `https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${accessToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          message: {
            token,
            notification: {
              title: notification.title,
              body: notification.body,
            },
            data: notification.data,
            android: { priority: 'high' },
          },
        }),
      },
    );
  } catch (error) {
    return {
      outcome: 'transient',
      detail: error instanceof Error ? error.message : 'network error',
    };
  }

  if (response.ok) return { outcome: 'accepted', status: response.status };

  const body = await readFcmError(response);
  const errorCode =
    body?.error?.details?.find((detail) => detail?.errorCode)?.errorCode ??
    body?.error?.status;
  const message = body?.error?.message ?? '';

  if (response.status === 401 || response.status === 403) {
    return { outcome: 'auth_error', status: response.status, errorCode, detail: message };
  }

  if (isPermanentTokenFailure(response.status, errorCode, message)) {
    // Only permanent token failures reach here, so pruning cannot drop a
    // valid token because of a transient outage or a configuration mistake.
    await env.DB.prepare('DELETE FROM push_tokens WHERE token = ?').bind(token).run();
    return { outcome: 'pruned', status: response.status, errorCode, detail: message };
  }

  if (response.status === 429 || response.status >= 500) {
    return { outcome: 'transient', status: response.status, errorCode, detail: message };
  }

  return { outcome: 'rejected', status: response.status, errorCode, detail: message };
}

/**
 * Sends a push notification to every device registered for `userId`.
 * Never throws: notification delivery must not affect message sending.
 */
export async function sendPushToUser(
  env: Env,
  userId: string,
  notification: PushNotification,
): Promise<void> {
  const account = parseServiceAccount(env.FCM_SERVICE_ACCOUNT);
  if (!account) return;

  try {
    const { results } = await env.DB.prepare(
      'SELECT token FROM push_tokens WHERE user_id = ?',
    )
      .bind(userId)
      .all<{ token: string }>();
    const tokens = (results ?? []).map((row) => row.token);
    if (tokens.length === 0) {
      console.log(`FCM push skipped user=${userId}: no registered tokens`);
      return;
    }

    let accessToken: string;
    try {
      accessToken = await getAccessToken(account);
    } catch (error) {
      console.error('FCM authentication failed', error);
      return;
    }

    // Each token is attempted independently; one device's failure never
    // prevents delivery to the account's other devices.
    const settlements = await Promise.allSettled(
      tokens.map((token) => sendToToken(env, account, accessToken, token, notification)),
    );

    let accepted = 0;
    let failed = 0;
    let pruned = 0;
    let authError = 0;

    settlements.forEach((settlement, index) => {
      // Tokens are identified by position so no token value reaches the logs.
      const label = `device #${index + 1}`;
      if (settlement.status === 'rejected') {
        failed += 1;
        console.error(
          `FCM push attempt threw for ${label}:`,
          settlement.reason instanceof Error ? settlement.reason.message : settlement.reason,
        );
        return;
      }

      const attempt = settlement.value;
      switch (attempt.outcome) {
        case 'accepted':
          accepted += 1;
          break;
        case 'pruned':
          pruned += 1;
          console.warn(
            `FCM token removed for ${label}: permanently invalid` +
              ` (status ${attempt.status ?? 'n/a'}${attempt.errorCode ? `, ${attempt.errorCode}` : ''})`,
          );
          break;
        case 'auth_error':
          authError += 1;
          console.error(
            `FCM rejected push for ${label}: authorization failed` +
              ` (status ${attempt.status ?? 'n/a'}${attempt.errorCode ? `, ${attempt.errorCode}` : ''})` +
              ' — verify FCM_SERVICE_ACCOUNT project and Firebase Messaging permissions',
          );
          break;
        case 'transient':
          failed += 1;
          console.warn(
            `FCM push temporarily failed for ${label}` +
              ` (status ${attempt.status ?? 'n/a'}${attempt.errorCode ? `, ${attempt.errorCode}` : ''})` +
              `${attempt.detail ? `: ${attempt.detail}` : ''}`,
          );
          break;
        default:
          failed += 1;
          console.error(
            `FCM rejected push for ${label}` +
              ` (status ${attempt.status ?? 'n/a'}${attempt.errorCode ? `, ${attempt.errorCode}` : ''})` +
              `${attempt.detail ? `: ${attempt.detail}` : ''}`,
          );
      }
    });

    console.log(
      `FCM push user=${userId} tokens=${tokens.length} accepted=${accepted} failed=${failed} pruned=${pruned} authErrors=${authError}`,
    );
  } catch (error) {
    console.error('push delivery failed', error);
  }
}

/**
 * Notification policy for a persisted 1:1 message, shared by the HTTP and
 * WebSocket send paths so both transports behave identically.
 *
 * - Never notifies the sender (callers pass the recipient only).
 * - Skips the push when the inbox event already reached the recipient's
 *   active socket, avoiding a redundant notification.
 * - Keeps the preview neutral because the server cannot decrypt E2EE bodies.
 * - Never throws; push failure must not fail the message send.
 */
export async function sendMessagePush(
  env: Env,
  params: {
    senderId: string;
    recipientId: string;
    conversationId: string;
    recipientHasActiveSocket: boolean;
  },
): Promise<void> {
  if (params.recipientHasActiveSocket) {
    console.log(
      `FCM push skipped user=${params.recipientId}: recipient has an active socket`,
    );
    return;
  }
  try {
    const sender = await env.DB.prepare('SELECT username FROM users WHERE id = ?')
      .bind(params.senderId)
      .first<{ username: string }>();
    await sendPushToUser(env, params.recipientId, {
      title: sender?.username ?? 'New message',
      body: 'Sent you a message',
      data: { type: 'message', conversationId: params.conversationId },
    });
  } catch (error) {
    console.error('Message push dispatch failed', error);
  }
}
