import { drizzle } from 'drizzle-orm/d1';
import type { Env } from '../types.js';

export const getDb = (env: Env) => drizzle(env.DB);
export type Db = ReturnType<typeof getDb>;
