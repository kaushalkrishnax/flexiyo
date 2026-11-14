import { createClient, type Client, type InArgs, type ResultSet } from '@libsql/client/web';
import type { Env } from '../types.js';

export interface SqlStatement {
  bind(...values: unknown[]): SqlStatement;
  first<T = Record<string, unknown>>(column?: string): Promise<T | null>;
  all<T = Record<string, unknown>>(): Promise<{
    results: T[];
    success: boolean;
    meta: { changes: number; last_row_id: number | null; rows_read: number };
  }>;
  run(): Promise<{
    success: boolean;
    meta: { changes: number; last_row_id: number | null };
  }>;
  raw<T = unknown[]>(): Promise<T[]>;
}

export interface SqlDatabase {
  client?: Client;
  prepare(sql: string): SqlStatement;
  batch<T = Record<string, unknown>>(
    statements: SqlStatement[],
  ): Promise<
    Array<{
      results: T[];
      success: boolean;
      meta: { changes: number; last_row_id: number | null; rows_read: number };
    }>
  >;
  exec(sql: string): Promise<void>;
}

interface BoundQuery {
  sql: string;
  args: InArgs;
}

class LibsqlStatement implements SqlStatement {
  private readonly client: Client;
  private readonly sql: string;
  private args: InArgs = [];

  constructor(client: Client, sql: string) {
    this.client = client;
    this.sql = sql;
  }

  bind(...values: unknown[]): SqlStatement {
    this.args = values.map((v) => (v === undefined ? null : v)) as InArgs;
    return this;
  }

  toQuery(): BoundQuery {
    return { sql: this.sql, args: this.args };
  }

  async first<T = Record<string, unknown>>(column?: string): Promise<T | null> {
    const rs: ResultSet = await this.client.execute({ sql: this.sql, args: this.args });
    if (rs.rows.length === 0) return null;
    const row = rs.rows[0] as Record<string, unknown>;
    if (column) {
      return (row[column] as T) ?? null;
    }
    return row as T;
  }

  async all<T = Record<string, unknown>>() {
    const rs: ResultSet = await this.client.execute({ sql: this.sql, args: this.args });
    return {
      results: rs.rows as unknown as T[],
      success: true,
      meta: {
        changes: rs.rowsAffected,
        last_row_id: rs.lastInsertRowid !== undefined ? Number(rs.lastInsertRowid) : null,
        rows_read: rs.rows.length,
      },
    };
  }

  async run() {
    const rs: ResultSet = await this.client.execute({ sql: this.sql, args: this.args });
    return {
      success: true,
      meta: {
        changes: rs.rowsAffected,
        last_row_id: rs.lastInsertRowid !== undefined ? Number(rs.lastInsertRowid) : null,
      },
    };
  }

  async raw<T = unknown[]>(): Promise<T[]> {
    const rs: ResultSet = await this.client.execute({ sql: this.sql, args: this.args });
    return rs.rows.map((row) => Object.values(row)) as T[];
  }
}

class LibsqlDatabaseAdapter implements SqlDatabase {
  readonly client: Client;

  constructor(client: Client) {
    this.client = client;
  }

  prepare(sql: string): SqlStatement {
    return new LibsqlStatement(this.client, sql);
  }

  async batch<T = Record<string, unknown>>(statements: SqlStatement[]) {
    if (statements.length === 0) return [];
    const queries = statements.map((stmt) => (stmt as LibsqlStatement).toQuery());
    const results = await this.client.batch(queries, 'write');
    return results.map((rs) => ({
      results: rs.rows as unknown as T[],
      success: true,
      meta: {
        changes: rs.rowsAffected,
        last_row_id: rs.lastInsertRowid !== undefined ? Number(rs.lastInsertRowid) : null,
        rows_read: rs.rows.length,
      },
    }));
  }

  async exec(sql: string): Promise<void> {
    await this.client.executeMultiple(sql);
  }
}

const requestDbCache = new WeakMap<object, SqlDatabase>();

export function normalizeTursoUrl(rawUrl: string): string {
  if (rawUrl.startsWith('libsql://')) {
    return `https://${rawUrl.slice('libsql://'.length)}`;
  }
  if (rawUrl.startsWith('turso://')) {
    return `https://${rawUrl.slice('turso://'.length)}`;
  }
  return rawUrl;
}

export function createTursoClient(env: Pick<Env, 'TURSO_DB_URL' | 'TURSO_DB_TOKEN'>): Client {
  if (!env.TURSO_DB_URL || !env.TURSO_DB_TOKEN) {
    throw new Error('Missing TURSO_DB_URL or TURSO_DB_TOKEN binding');
  }
  return createClient({
    url: normalizeTursoUrl(env.TURSO_DB_URL),
    authToken: env.TURSO_DB_TOKEN,
  });
}

export function getSqlDb(env: Env, scopeKey?: object): SqlDatabase {
  if (scopeKey) {
    const cached = requestDbCache.get(scopeKey);
    if (cached) return cached;
  }

  const db: SqlDatabase =
    env.TURSO_DB_URL && env.TURSO_DB_TOKEN
      ? new LibsqlDatabaseAdapter(createTursoClient(env))
      : (env.DB as unknown as SqlDatabase);

  if (scopeKey) {
    requestDbCache.set(scopeKey, db);
  }
  return db;
}
