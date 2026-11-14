import { drizzle as drizzleD1 } from 'drizzle-orm/d1';
import { drizzle as drizzleLibsql } from 'drizzle-orm/libsql/web';
import type { BaseSQLiteDatabase } from 'drizzle-orm/sqlite-core';
import type { Env } from '../types.js';
import { createTursoClient } from './turso.js';

export type Db = BaseSQLiteDatabase<'async', unknown, Record<string, never>>;

export const getDb = (env: Env): Db => {
  if (env.TURSO_DB_URL && env.TURSO_DB_TOKEN) {
    return drizzleLibsql(createTursoClient(env)) as unknown as Db;
  }
  return drizzleD1(env.DB) as unknown as Db;
};
