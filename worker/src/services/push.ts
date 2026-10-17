import type { Env } from '../types.js';

/**
 * Firebase Cloud Messaging (HTTP v1) delivery for offline notifications.
 *
 * Configuration comes from the `FCM_SERVICE_ACCOUNT` secret: the JSON key
 * generated in Firebase console → Project settings → Service accounts →
 * Generate new private key (project `flexiyo-app`). Without the secret,
 * pushes are silently skipped so messaging keeps working.
 *
 * The OAuth access token is cached per isolate (1-hour lifetime).
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

let cachedAccessToken: { value: string; expiresAt: number } | null = null;

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

async function getAccessToken(account: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedAccessToken && cachedAccessToken.expiresAt - 60 > now) {
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
    throw new Error(`FCM OAuth exchange failed (${tokenResponse.status})`);
  }
  const tokenData = (await tokenResponse.json()) as {
    access_token: string;
    expires_in?: number;
  };
  cachedAccessToken = {
    value: tokenData.access_token,
    expiresAt: now + (tokenData.expires_in ?? 3600),
  };
  return cachedAccessToken.value;
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
  try {
    const secret = env.FCM_SERVICE_ACCOUNT;
    if (!secret) return;

    const account = JSON.parse(secret) as ServiceAccount;
    if (!account.project_id || !account.client_email || !account.private_key) {
      return;
    }

    const { results } = await env.DB.prepare(
      'SELECT token FROM push_tokens WHERE user_id = ?',
    )
      .bind(userId)
      .all<{ token: string }>();
    const tokens = (results ?? []).map((row) => row.token);
    if (tokens.length === 0) return;

    const accessToken = await getAccessToken(account);

    await Promise.allSettled(
      tokens.map(async (token) => {
        const response = await fetch(
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

        // Stale/expired tokens are pruned so they are not retried forever.
        if (response.status === 404) {
          await env.DB.prepare('DELETE FROM push_tokens WHERE token = ?')
            .bind(token)
            .run();
        }
      }),
    );
  } catch (error) {
    console.error('push delivery failed', error);
  }
}
