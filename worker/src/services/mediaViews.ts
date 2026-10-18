import type { ViewPolicy } from '../types.js';

/** Allowed recipient views per limited policy. */
const VIEW_LIMITS: Record<'once' | 'twice', number> = { once: 1, twice: 2 };

export interface ViewDecision {
  /** False once the recipient has already used every allowed view. */
  allowed: boolean;
  /** True when this response is the recipient's last allowed view. */
  final: boolean;
  /** Views left after this one, or null for unlimited media. */
  remaining: number | null;
}

/**
 * Evaluates a recipient fetch against the media's policy. [priorViews] is the
 * count already consumed by this user, before the current request.
 */
export function decideView(policy: ViewPolicy, priorViews: number): ViewDecision {
  if (policy === 'unlimited') {
    return { allowed: true, final: false, remaining: null };
  }
  const limit = VIEW_LIMITS[policy];
  if (priorViews >= limit) {
    return { allowed: false, final: true, remaining: 0 };
  }
  const remaining = limit - (priorViews + 1);
  return { allowed: true, final: remaining === 0, remaining };
}
