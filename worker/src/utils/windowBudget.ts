export interface WindowBudget {
  count: number;
  windowStart: number;
}

export interface WindowBudgetResult extends WindowBudget {
  allowed: boolean;
  retryAfterMs: number;
}

/** Pure fixed-window counter used by hibernation-safe socket attachments. */
export function consumeWindowBudget(
  current: WindowBudget,
  now: number,
  limit: number,
  windowMs: number,
): WindowBudgetResult {
  let count = current.count;
  let windowStart = current.windowStart;
  if (windowStart <= 0 || now - windowStart >= windowMs) {
    windowStart = now;
    count = 0;
  }
  if (count >= limit) {
    return {
      count,
      windowStart,
      allowed: false,
      retryAfterMs: Math.max(1, windowMs - (now - windowStart)),
    };
  }
  return { count: count + 1, windowStart, allowed: true, retryAfterMs: 0 };
}
