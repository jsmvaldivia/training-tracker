import { useCallback, useEffect, useRef, useState } from 'react';
import { api } from '../api';
import type { MilestoneUpdate, PursuitUpdate } from '../api';
import type { Pursuit } from '../types';
import {
  applyMilestonePatch,
  applyPursuitPatch,
  reconcileMilestone,
  reconcilePursuit,
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

  return { pursuits, loading, error, updateMilestone, updatePursuit };
}
