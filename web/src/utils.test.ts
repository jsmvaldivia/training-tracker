import { describe, expect, it } from 'bun:test';
import type { Milestone, Pursuit } from './types';
import { calculateDerivedState, cn, isMilestoneOverdue } from './utils';

const NOW = new Date('2026-06-15T12:00:00Z');
const days = (n: number) => new Date(NOW.getTime() + n * 24 * 60 * 60 * 1000).toISOString();

function milestone(over: Partial<Milestone> = {}): Milestone {
  return { id: 'm1', name: 'Milestone', date: days(1), state: 'pending', ...over };
}

function pursuit(over: Partial<Pursuit> = {}): Pursuit {
  return {
    id: 'p1',
    name: 'Pursuit',
    type: 'training',
    status: 'in_progress',
    target_date: days(10),
    started_at: days(-10),
    tags: [],
    milestones: [],
    ...over,
  };
}

describe('isMilestoneOverdue', () => {
  it('is true for a pending milestone past its date', () => {
    expect(isMilestoneOverdue(milestone({ date: days(-1) }), NOW)).toBe(true);
  });

  it('is false once the milestone is achieved, however late', () => {
    expect(isMilestoneOverdue(milestone({ date: days(-30), state: 'achieved' }), NOW)).toBe(false);
  });

  it('is false while the date is still ahead', () => {
    expect(isMilestoneOverdue(milestone({ date: days(1) }), NOW)).toBe(false);
  });
});

describe('calculateDerivedState', () => {
  it('reports a completed pursuit as 100% time and completed', () => {
    const d = calculateDerivedState(pursuit({ status: 'completed', completed_at: days(-1) }), NOW);
    expect(d.timeProgress).toBe(100);
    expect(d.achievementProgress).toBe(100); // no milestones + completed_at
    expect(d.signal).toBe('completed');
    expect(d.isOverdue).toBe(false);
  });

  it('is not started before started_at', () => {
    const d = calculateDerivedState(pursuit({ started_at: days(5), target_date: days(20) }), NOW);
    expect(d.timeProgress).toBe(0);
    expect(d.signal).toBe('not_started');
  });

  it('clamps time at 100% and flags overdue past target_date', () => {
    const d = calculateDerivedState(pursuit({ target_date: days(-2) }), NOW);
    expect(d.timeProgress).toBe(100);
    expect(d.isOverdue).toBe(true);
    expect(d.daysRemaining).toBe(-2);
  });

  it('measures achievement as the share of achieved milestones', () => {
    const d = calculateDerivedState(
      pursuit({ milestones: [milestone({ id: 'a', state: 'achieved' }), milestone({ id: 'b' })] }),
      NOW
    );
    expect(d.achievementProgress).toBe(50);
  });

  it('signals behind when time outruns achievement by more than 15 points', () => {
    // 50% of the runway gone, nothing achieved.
    const d = calculateDerivedState(pursuit({ milestones: [milestone()] }), NOW);
    expect(d.timeProgress).toBe(50);
    expect(d.signal).toBe('behind');
  });

  it('signals ahead when achievement outruns time', () => {
    const d = calculateDerivedState(
      pursuit({ started_at: days(-1), target_date: days(9), milestones: [milestone({ state: 'achieved' })] }),
      NOW
    );
    expect(d.signal).toBe('ahead');
  });

  it('signals on track inside the 15-point band', () => {
    const d = calculateDerivedState(
      pursuit({ milestones: [milestone({ id: 'a', state: 'achieved' }), milestone({ id: 'b' })] }),
      NOW
    );
    expect(d.signal).toBe('on_track');
  });

  it('keeps a planned pursuit as not started even after started_at', () => {
    const d = calculateDerivedState(pursuit({ status: 'planned' }), NOW);
    expect(d.signal).toBe('not_started');
  });
});

describe('cn', () => {
  it('merges conditional classes and lets the later Tailwind utility win', () => {
    expect(cn('p-2', false && 'hidden', 'p-4')).toBe('p-4');
  });
});
