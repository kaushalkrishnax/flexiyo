import { describe, expect, it } from 'vitest';
import { consumeWindowBudget } from '../src/utils/windowBudget.js';

describe('consumeWindowBudget', () => {
  it('allows the configured number of events and rejects the next one', () => {
    const budget = { count: 0, windowStart: 1_000 };
    expect(consumeWindowBudget(budget, 1_100, 2, 1_000)).toEqual({
      count: 1, windowStart: 1_000, allowed: true, retryAfterMs: 0,
    });
    const second = consumeWindowBudget(
      { count: 1, windowStart: 1_000 }, 1_200, 2, 1_000,
    );
    expect(second.allowed).toBe(true);
    const denied = consumeWindowBudget(
      { count: second.count, windowStart: second.windowStart }, 1_300, 2, 1_000,
    );
    expect(denied.allowed).toBe(false);
    expect(denied.retryAfterMs).toBe(700);
    expect(denied.count).toBe(2);
  });

  it('resets an expired window before counting the new event', () => {
    expect(consumeWindowBudget(
      { count: 10, windowStart: 1_000 }, 2_000, 3, 1_000,
    )).toEqual({ count: 1, windowStart: 2_000, allowed: true, retryAfterMs: 0 });
  });

  it('treats an uninitialized attachment counter as a fresh window', () => {
    expect(consumeWindowBudget(
      { count: 0, windowStart: 0 }, 5_000, 1, 10_000,
    )).toEqual({ count: 1, windowStart: 5_000, allowed: true, retryAfterMs: 0 });
  });
});
