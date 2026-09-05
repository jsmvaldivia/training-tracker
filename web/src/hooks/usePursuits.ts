import { useCallback, useEffect, useRef, useState } from 'react';
import { api } from '../api';
import type { MilestoneUpdate, PursuitCreate, PursuitUpdate } from '../api';
import type { Pursuit } from '../types';
import {
  appendPursuit,
  applyMilestonePatch,
  applyPursuitPatch,
  reconcileMilestone,
  reconcilePursuit,
  removePursuit,
  runOptimisticUpdate,
} from './pursuitState';

// usePursuits owns the pursuit list state end-to-end: it fetches the list on
// mount (read path, issue #3) and exposes optimistic mutators (issue #4). Each
// mutator applies the change locally, calls the API, reconciles the authoritative
// server response, and rolls back + reports via `onError` on failure — so all
// mutation/rollback logic lives in one place and components stay presentational.

export interface UsePursuitsOptions {
  // Called with a human-readable message when a mutation fails and is rolled
  // back. The list-fetch failure is surfaced via `error` instead.
  onError?: (message: string) => void;
}

export interface UsePursuitsResult {
  pursuits: Pursuit[];
  loading: boolean;
  error: string | null;
  updateMilestone: (
    pursuitId: string,
    milestoneId: string,
    patch: MilestoneUpdate
  ) => Promise<void>;
  updatePursuit: (pursuitId: string, patch: PursuitUpdate) => Promise<void>;
  // Resolves to the created pursuit, or null after a failure was reported.
  createPursuit: (data: PursuitCreate) => Promise<Pursuit | null>;
  deletePursuit: (pursuitId: string) => Promise<void>;
}

export function usePursuits(options: UsePursuitsOptions = {}): UsePursuitsResult {
  const { onError } = options;
  const [pursuits, setPursuits] = useState<Pursuit[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Latest list, read synchronously when building a mutation's snapshot so
  // optimistic updates start from current state rather than a stale closure.
  const pursuitsRef = useRef<Pursuit[]>(pursuits);
  pursuitsRef.current = pursuits;

  useEffect(() => {
    let cancelled = false;

    setLoading(true);
    setError(null);

    api
      .listPursuits()
      .then((response) => {
        if (cancelled) return;
        setPursuits(response.data);
      })
      .catch((err: unknown) => {
        if (cancelled) return;
        setError(err instanceof Error ? err.message : 'Failed to load pursuits');
      })
      .finally(() => {
        if (cancelled) return;
        setLoading(false);
      });

    return () => {
      cancelled = true;
    };
  }, []);

  const updateMilestone = useCallback(
    async (pursuitId: string, milestoneId: string, patch: MilestoneUpdate) => {
      const snapshot = pursuitsRef.current;
      const optimistic = applyMilestonePatch(snapshot, pursuitId, milestoneId, patch);
      await runOptimisticUpdate(
        {
          optimistic,
          snapshot,
          call: () => api.updateMilestone(pursuitId, milestoneId, patch),
          reconcile: (milestone) => reconcileMilestone(optimistic, pursuitId, milestone),
        },
        setPursuits,
        onError
      );
    },
    [onError]
  );

  const updatePursuit = useCallback(
    async (pursuitId: string, patch: PursuitUpdate) => {
      const snapshot = pursuitsRef.current;
      const optimistic = applyPursuitPatch(snapshot, pursuitId, patch);
      await runOptimisticUpdate(
        {
          optimistic,
          snapshot,
          call: () => api.updatePursuit(pursuitId, patch),
          reconcile: (updated) => reconcilePursuit(optimistic, updated),
        },
        setPursuits,
        onError
      );
    },
    [onError]
  );

  const createPursuit = useCallback(
    async (data: PursuitCreate): Promise<Pursuit | null> => {
      try {
        const created = await api.createPursuit(data);
        setPursuits((current) => appendPursuit(current, created));
        return created;
      } catch (err) {
        onError?.(err instanceof Error ? err.message : 'Create failed');
        return null;
      }
    },
    [onError]
  );

  // Optimistic removal: the card disappears at once and comes back on failure.
  const deletePursuit = useCallback(
    async (pursuitId: string) => {
      const snapshot = pursuitsRef.current;
      const optimistic = removePursuit(snapshot, pursuitId);
      await runOptimisticUpdate(
        {
          optimistic,
          snapshot,
          call: () => api.deletePursuit(pursuitId),
          reconcile: () => optimistic,
        },
        setPursuits,
        onError
      );
    },
    [onError]
  );

  return { pursuits, loading, error, updateMilestone, updatePursuit, createPursuit, deletePursuit };
}
