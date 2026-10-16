import { describe, expect, it } from 'vitest';
import {
  conversationListQuery,
  parseScope,
} from '../src/services/conversationList.js';

const placeholderCount = (sql: string) => (sql.match(/\?/g) || []).length;

describe('conversation list query', () => {
  it('binds one value per placeholder for the inbox scope', () => {
    const { sql, binds } = conversationListQuery('user-1', 'inbox');
    expect(binds).toHaveLength(placeholderCount(sql));
  });

  it('binds one value per placeholder for the requests scope', () => {
    const { sql, binds } = conversationListQuery('user-1', 'requests');
    expect(binds).toHaveLength(placeholderCount(sql));
  });

  it('defaults unknown scopes to the inbox', () => {
    expect(parseScope(new URL('https://x.test/api/conversations'))).toBe('inbox');
    expect(
      parseScope(new URL('https://x.test/api/conversations?scope=requests')),
    ).toBe('requests');
    expect(
      parseScope(new URL('https://x.test/api/conversations?scope=bogus')),
    ).toBe('inbox');
  });
});
