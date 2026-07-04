import { describe, expect, it, mock } from 'bun:test';
import type { Milestone, Pursuit } from '../types';
import {
  applyMilestonePatch,
  applyPursuitPatch,
  reconcileMilestone,
  reconcilePursuit,
  runOptimisticUpdate,
} from './pursuitState';

function milestone(id: string, state: Milestone['state'] = 'pending'): Milestone {
  return { id, name: `Milestone ${id}`, date: '2026-01-01T00:00:00Z', state };
}

function pursuit(id: string, milestones: Milestone[] = []): Pursuit {
  return {
    id,
    name: `Pursuit ${id}`,
    type: 'training',
    status: 'in_progress',
    target_date: '2026-12-31T00:00:00Z',
    started_at: '2026-01-01T00:00:00Z',
    tags: [],
    milestones,
  };
}

describe('reconcileMilestone', () => {
  it('merges the server milestone into its parent pursuit only', () => {
    const pursuits = [pursuit('p1', [milestone('m1'), milestone('m2')]), pursuit('p2', [milestone('m3')])];
    const server: Milestone = { ...milestone('m2', 'achieved'), achieved_at: '2026-06-21T10:00:00Z' };

    const next = reconcileMilestone(pursuits, 'p1', server);

    expect(next[0].milestones[1]).toEqual(server);
    expect(next[0].milestones[0]).toBe(pursuits[0].milestones[0]); // untouched sibling
    expect(next[1]).toBe(pursuits[1]); // untouched pursuit
  });

  it('does not replace the pursuit, only the one milestone', () => {
    const pursuits = [pursuit('p1', [milestone('m1')])];
    const next = reconcileMilestone(pursuits, 'p1', milestone('m1', 'achieved'));
    expect(next[0].name).toBe('Pursuit p1');
    expect(next[0].milestones[0].state).toBe('achieved');
  });
});

describe('reconcilePursuit', () => {
  it('replaces the whole pursuit by id', () => {
    const pursuits = [pursuit('p1'), pursuit('p2')];
    const updated = { ...pursuit('p1'), status: 'completed' as const, completed_at: '2026-06-21T10:00:00Z' };
    const next = reconcilePursuit(pursuits, updated);
    expect(next[0]).toEqual(updated);
    expect(next[1]).toBe(pursuits[1]);
  });
});

describe('applyMilestonePatch', () => {
  it('optimistically flips the milestone state without stamping achieved_at', () => {
    const pursuits = [pursuit('p1', [milestone('m1', 'pending')])];
    const next = applyMilestonePatch(pursuits, 'p1', 'm1', { state: 'achieved' });
    expect(next[0].milestones[0].state).toBe('achieved');
    expect(next[0].milestones[0].achieved_at).toBeUndefined(); // server stamps it, not us
  });
});

describe('applyPursuitPatch', () => {
  it('optimistically merges fields into the target pursuit', () => {
    const pursuits = [pursuit('p1')];
    const next = applyPursuitPatch(pursuits, 'p1', { status: 'completed' });
    expect(next[0].status).toBe('completed');
  });
});

describe('runOptimisticUpdate', () => {
  const base = [pursuit('p1', [milestone('m1', 'pending')])];
  const optimistic = applyMilestonePatch(base, 'p1', 'm1', { state: 'achieved' });

  it('applies optimistic state, then reconciles the server result on success', async () => {
    const states: Pursuit[][] = [];
    const setPursuits = (p: Pursuit[]) => states.push(p);
    const server: Milestone = { ...milestone('m1', 'achieved'), achieved_at: '2026-06-21T10:00:00Z' };

    await runOptimisticUpdate(
      {
        optimistic,
        snapshot: base,
        call: () => Promise.resolve(server),
        reconcile: (m) => reconcileMilestone(optimistic, 'p1', m),
      },
      setPursuits
    );

    expect(states).toHaveLength(2);
    expect(states[0]).toBe(optimistic); // optimistic shown first
    expect(states[1][0].milestones[0].achieved_at).toBe('2026-06-21T10:00:00Z'); // reconciled
  });

  it('rolls back to the snapshot and reports the error message on failure', async () => {
    const states: Pursuit[][] = [];
    const setPursuits = (p: Pursuit[]) => states.push(p);
    const onError = mock((_message: string) => {});

    await runOptimisticUpdate(
      {
        optimistic,
        snapshot: base,
        call: () => Promise.reject(new Error('Failed to persist change')),
        reconcile: () => optimistic,
      },
      setPursuits,
      onError
    );

    expect(states).toHaveLength(2);
    expect(states[0]).toBe(optimistic); // showed the guess
    expect(states[1]).toBe(base); // rolled back to snapshot
    expect(onError).toHaveBeenCalledWith('Failed to persist change');
  });

  it('falls back to a generic message when the rejection is not an Error', async () => {
    const onError = mock((_message: string) => {});
    await runOptimisticUpdate(
      { optimistic, snapshot: base, call: () => Promise.reject('boom'), reconcile: () => optimistic },
      () => {},
      onError
    );
    expect(onError).toHaveBeenCalledWith('Update failed');
  });
});
