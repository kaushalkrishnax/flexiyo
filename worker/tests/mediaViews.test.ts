import { describe, expect, it } from 'vitest';
import { decideView } from '../src/services/mediaViews.js';

describe('media view decisions', () => {
  it('serves view-once exactly once and marks it final', () => {
    expect(decideView('once', 0)).toEqual({
      allowed: true,
      final: true,
      remaining: 0,
    });
  });

  it('denies view-once media after the single view', () => {
    expect(decideView('once', 1)).toEqual({
      allowed: false,
      final: true,
      remaining: 0,
    });
  });

  it('reports one view left on the first of two views', () => {
    expect(decideView('twice', 0)).toEqual({
      allowed: true,
      final: false,
      remaining: 1,
    });
  });

  it('marks the second view final and denies the third', () => {
    expect(decideView('twice', 1)).toEqual({
      allowed: true,
      final: true,
      remaining: 0,
    });
    expect(decideView('twice', 2).allowed).toBe(false);
  });

  it('never limits unlimited media', () => {
    expect(decideView('unlimited', 500)).toEqual({
      allowed: true,
      final: false,
      remaining: null,
    });
  });
});
