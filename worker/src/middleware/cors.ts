import type { Env } from '../types.js';

const ALLOWED_ORIGINS = [
  'https://flexiyo.pages.dev',
  'http://localhost:3000',
  'http://localhost:8080',
];

export function corsHeaders(env: Env, request?: Request): Record<string, string> {
  const origin = request?.headers.get('Origin');
  let allowedOrigin = env.CORS_ORIGIN || 'https://flexiyo.pages.dev';

  if (origin) {
    if (
      ALLOWED_ORIGINS.includes(origin) ||
      origin.endsWith('.flexiyo.pages.dev') ||
      origin.startsWith('http://localhost:') ||
      origin.startsWith('http://127.0.0.1:') ||
      origin === env.CORS_ORIGIN
    ) {
      allowedOrigin = origin;
    }
  }

  return {
    'Access-Control-Allow-Origin': allowedOrigin,
    'Access-Control-Allow-Methods': 'GET, POST, PATCH, DELETE, OPTIONS',
    'Access-Control-Allow-Headers': 'Authorization, Content-Type, Accept, Origin, X-Requested-With',
    'Access-Control-Allow-Credentials': 'true',
    'Access-Control-Max-Age': '86400',
  };
}

export function withCors(response: Response, env: Env, request?: Request): Response {
  const headers = new Headers(response.headers);
  for (const [key, value] of Object.entries(corsHeaders(env, request))) {
    headers.set(key, value);
  }
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

export function handlePreflight(env: Env, request?: Request): Response {
  return new Response(null, {
    status: 204,
    headers: corsHeaders(env, request),
  });
}
