/**
 * Minimal load-test client for the Flexiyo Worker: authenticated HTTP calls,
 * WebSocket sockets with request/ack tracking, and a metrics collector.
 *
 * Everything the client can observe is measured here; server-internal fan-out
 * (Worker -> Durable Object subrequests, D1 rows) is modeled in costs.js.
 */

export const LOCAL_HOSTS = new Set(['localhost', '127.0.0.1', '::1', '0.0.0.0']);

export function isLocalTarget(baseUrl) {
  try {
    return LOCAL_HOSTS.has(new URL(baseUrl).hostname);
  } catch {
    return false;
  }
}

export function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

const byteLength = (text) => new TextEncoder().encode(text).length;

export class HttpError extends Error {
  constructor(method, path, status, statusText, body, retryAfterMs) {
    super(`${method} ${path.split('?')[0]} → ${status} ${statusText} ${body.slice(0, 160)}`);
    this.name = 'HttpError';
    this.status = status;
    this.retryAfterMs = retryAfterMs;
  }
}

export class Metrics {
  constructor() {
    this.counts = new Map();
    this.samples = new Map();
    this.errors = [];
  }

  count(name, by = 1) {
    this.counts.set(name, (this.counts.get(name) ?? 0) + by);
  }

  observe(name, ms) {
    const samples = this.samples.get(name) ?? [];
    samples.push(ms);
    this.samples.set(name, samples);
  }

  recordError(op, message) {
    this.count('errors');
    if (this.errors.length < 20) this.errors.push({ op, message });
  }

  get(name) {
    return this.counts.get(name) ?? 0;
  }

  stat(name) {
    const samples = this.samples.get(name);
    if (!samples || samples.length === 0) return null;
    const sorted = [...samples].sort((a, b) => a - b);
    const at = (q) => sorted[Math.min(sorted.length - 1, Math.floor(q * (sorted.length - 1)))];
    return {
      count: samples.length,
      avg: sorted.reduce((sum, value) => sum + value, 0) / sorted.length,
      p50: at(0.5),
      p95: at(0.95),
      max: sorted[sorted.length - 1],
    };
  }
}

export class LoadClient {
  constructor({ baseUrl, metrics, token = null, userId = null, username = null, installationId = null, deviceId = null, ip = null, timeoutMs = 30_000 }) {
    this.baseUrl = baseUrl.replace(/\/$/, '');
    this.metrics = metrics;
    this.token = token;
    this.userId = userId;
    this.username = username;
    this.installationId = installationId;
    this.deviceId = deviceId;
    this.ip = ip;
    this.timeoutMs = timeoutMs;
  }

  clone() {
    return new LoadClient({
      baseUrl: this.baseUrl,
      metrics: this.metrics,
      token: this.token,
      userId: this.userId,
      username: this.username,
      installationId: this.installationId,
      deviceId: this.deviceId,
      ip: this.ip,
      timeoutMs: this.timeoutMs,
    });
  }

  headers(extra = {}) {
    const headers = { ...extra };
    if (this.token) headers.Authorization = `Bearer ${this.token}`;
    if (this.installationId) headers['X-Installation-Id'] = this.installationId;
    // Local dev worker only: keeps the isolate-local, IP-keyed rate limiter
    // from funnelling every simulated user into one bucket.
    if (this.ip) headers['CF-Connecting-IP'] = this.ip;
    return headers;
  }

  async http(method, path, { body, op, tolerate = [] } = {}) {
    const name = op ?? `${method} ${path.split('?')[0]}`;
    const started = performance.now();
    let response;
    let text;
    try {
      response = await fetch(new URL(path, this.baseUrl), {
        method,
        headers: this.headers(body === undefined ? {} : { 'Content-Type': 'application/json' }),
        body: body === undefined ? undefined : JSON.stringify(body),
        signal: AbortSignal.timeout(this.timeoutMs),
      });
      text = await response.text();
    } catch (error) {
      this.metrics.recordError(name, String(error?.message ?? error));
      throw error;
    } finally {
      this.metrics.count('worker.requests');
    }
    this.metrics.observe(name, performance.now() - started);
    this.metrics.count(name);

    if (!response.ok && !tolerate.includes(response.status)) {
      const retryAfter = Number(response.headers.get('Retry-After') ?? 0) * 1000 || null;
      const error = new HttpError(method, path, response.status, response.statusText, text, retryAfter);
      this.metrics.recordError(name, error.message);
      throw error;
    }

    let json = null;
    try {
      json = JSON.parse(text);
    } catch {
      // Non-JSON responses are fine for this client.
    }
    return { status: response.status, json, text };
  }

  wsUrl(path) {
    const url = new URL(path, this.baseUrl);
    url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
    return url.toString();
  }

  connect(path, { op, onFrame, connectTimeoutMs = 15_000 } = {}) {
    return new Socket(this.wsUrl(path), {
      metrics: this.metrics,
      op: op ?? `ws.connect ${path.split('?')[0]}`,
      onFrame,
      connectTimeoutMs,
    });
  }
}

const OPEN = 1;

export class Socket {
  constructor(url, { metrics, op, onFrame = null, connectTimeoutMs = 15_000, frameTimeoutMs = 20_000 }) {
    this.metrics = metrics;
    this.op = op;
    this.onFrame = onFrame;
    this.frameTimeoutMs = frameTimeoutMs;
    this.waiters = [];
    this.recent = [];
    this.closed = false;
    this.connected = false;

    const socket = new WebSocket(url);
    this.socket = socket;

    this.ready = new Promise((resolve, reject) => {
      const started = performance.now();
      const timer = setTimeout(() => reject(new Error(`${op}: connect timed out`)), connectTimeoutMs);
      socket.onerror = () => {
        clearTimeout(timer);
        reject(new Error(`${op}: connection error`));
      };
      socket.onclose = () => {
        this.closed = true;
      };
      socket.onmessage = (event) => {
        const text = typeof event.data === 'string' ? event.data : '';
        this.metrics.count('ws.framesReceived');
        this.metrics.count('ws.bytesReceived', byteLength(text));
        this.metrics.observe('ws.frameBytesReceived', byteLength(text));
        let frame;
        try {
          frame = JSON.parse(text);
        } catch {
          this.metrics.recordError(op, 'non-JSON frame');
          return;
        }
        this.recent.push(frame);
        if (this.recent.length > 100) this.recent.shift();

        if (!this.connected && frame?.type === 'connected') {
          this.connected = true;
          clearTimeout(timer);
          this.metrics.observe(op, performance.now() - started);
          this.metrics.count('worker.requests');
          this.metrics.count('do.connections');
          resolve(this);
          return;
        }
        this.dispatch(frame);
      };
    });
  }

  dispatch(frame) {
    for (const waiter of [...this.waiters]) {
      let matched = false;
      try {
        matched = waiter.predicate(frame);
      } catch {
        matched = false;
      }
      if (matched) {
        this.waiters.splice(this.waiters.indexOf(waiter), 1);
        clearTimeout(waiter.timer);
        waiter.resolve(frame);
      }
    }
    if (this.onFrame) {
      try {
        this.onFrame(frame);
      } catch (error) {
        this.metrics.recordError(this.op, String(error?.message ?? error));
      }
    }
  }

  send(frame, { op = 'ws.send', billed = true } = {}) {
    const payload = JSON.stringify(frame);
    if (this.socket.readyState !== OPEN) {
      this.metrics.recordError(op, 'socket not open');
      return false;
    }
    this.socket.send(payload);
    this.metrics.count('ws.framesSent');
    this.metrics.count('ws.bytesSent', byteLength(payload));
    this.metrics.observe('ws.frameBytesSent', byteLength(payload));
    if (billed) this.metrics.count('do.wsMessagesIn');
    return true;
  }

  async waitFor(predicate, { timeoutMs = this.frameTimeoutMs, op = this.op } = {}) {
    const existing = this.recent.find(predicate);
    if (existing) return existing;
    return new Promise((resolve, reject) => {
      const waiter = { predicate, resolve: null, timer: null };
      waiter.timer = setTimeout(() => {
        const index = this.waiters.indexOf(waiter);
        if (index >= 0) this.waiters.splice(index, 1);
        this.metrics.recordError(op, `timeout waiting for frame`);
        reject(new Error(`${op}: timed out waiting for frame`));
      }, timeoutMs);
      waiter.resolve = resolve;
      this.waiters.push(waiter);
    });
  }

  async request(frame, { op = 'ws.request', timeoutMs = this.frameTimeoutMs } = {}) {
    const requestId = crypto.randomUUID();
    const started = performance.now();
    const pending = this.waitFor((candidate) => candidate?.requestId === requestId, { timeoutMs, op });
    this.send({ ...frame, requestId }, { op });
    const response = await pending;
    this.metrics.observe(op, performance.now() - started);
    this.metrics.count(op);
    return response;
  }

  /**
   * Application-level heartbeat. The runtime answers it from
   * setWebSocketAutoResponse() without waking the object, so it is not a
   * billable DO request.
   */
  async ping({ timeoutMs = 5_000 } = {}) {
    const started = performance.now();
    const pong = this.waitFor((frame) => frame?.type === 'pong', { timeoutMs, op: 'ws.ping' });
    this.socket.send('{"type":"ping"}');
    this.metrics.count('ws.framesSent');
    this.metrics.count('ws.heartbeats.autoResponse');
    this.metrics.count('ws.ping');
    await pong;
    this.metrics.observe('ws.ping', performance.now() - started);
  }

  close() {
    try {
      this.socket.close(1000, 'load test finished');
    } catch {
      // Already closed.
    }
  }
}
