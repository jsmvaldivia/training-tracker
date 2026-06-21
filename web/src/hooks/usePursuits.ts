import { useEffect, useState } from 'react';
import { api } from '../api';
import type { Pursuit } from '../types';

// usePursuits owns the pursuit list state. This is the READ half of the hook
// (issue #3): it fetches the list on mount and exposes loading / error / empty
// (empty array) states. The mutation half (updateMilestone / updatePursuit,
// optimistic apply + reconcile + rollback, and the `onError` option) lands in
// issue #4 and will hang off this same state — the surface below is shaped to
// grow without breaking existing callers.

export interface UsePursuitsResult {
  pursuits: Pursuit[];
  loading: boolean;
  error: string | null;
}

export function usePursuits(): UsePursuitsResult {
  const [pursuits, setPursuits] = useState<Pursuit[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

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

  return { pursuits, loading, error };
}
