import type { Milestone, Pursuit } from '../types';

// Pure, React-free state transforms behind the optimistic mutation flow in
// `usePursuits` (issue #4). Keeping them here makes the interesting logic —
// reconcile-merge and rollback ordering — unit-testable with `bun test` without
// a DOM or renderer (the project has no jsdom / React Testing Library, and the
// zero-new-dependency rule rules out adding them).

// --- Reconcilers: fold a server response back into the list ----------------

// `PATCH /pursuits/{id}` returns the full Pursuit — replace it in place.
export function reconcilePursuit(pursuits: Pursuit[], updated: Pursuit): Pursuit[] {
  return pursuits.map((p) => (p.id === updated.id ? updated : p));
}

// `PATCH /pursuits/{id}/milestones/{mid}` returns ONLY the Milestone — merge it
// into its parent pursuit's milestones array. We must not replace the pursuit.
export function reconcileMilestone(
  pursuits: Pursuit[],
  pursuitId: string,
  milestone: Milestone
): Pursuit[] {
  return pursuits.map((p) =>
    p.id === pursuitId
      ? { ...p, milestones: p.milestones.map((m) => (m.id === milestone.id ? milestone : m)) }
      : p
  );
}

// `POST /pursuits` returns the created Pursuit — append it. Not optimistic:
// there is nothing to show before the server assigns the id.
export function appendPursuit(pursuits: Pursuit[], created: Pursuit): Pursuit[] {
  return [...pursuits, created];
}

export function removePursuit(pursuits: Pursuit[], pursuitId: string): Pursuit[] {
  return pursuits.filter((p) => p.id !== pursuitId);
}

function mapMilestones(
  pursuits: Pursuit[],
  pursuitId: string,
  update: (milestones: Milestone[]) => Milestone[]
): Pursuit[] {
  return pursuits.map((p) => (p.id === pursuitId ? { ...p, milestones: update(p.milestones) } : p));
}

// Optimistic add: the placeholder (temporary id) shows at once; `replaceMilestone`
// swaps it for the server's milestone when `POST .../milestones` returns.
export function appendMilestone(pursuits: Pursuit[], pursuitId: string, milestone: Milestone): Pursuit[] {
  return mapMilestones(pursuits, pursuitId, (ms) => [...ms, milestone]);
}

export function replaceMilestone(
  pursuits: Pursuit[],
  pursuitId: string,
  placeholderId: string,
  milestone: Milestone
): Pursuit[] {
  return mapMilestones(pursuits, pursuitId, (ms) => ms.map((m) => (m.id === placeholderId ? milestone : m)));
}

export function removeMilestone(pursuits: Pursuit[], pursuitId: string, milestoneId: string): Pursuit[] {
  return mapMilestones(pursuits, pursuitId, (ms) => ms.filter((m) => m.id !== milestoneId));
}

// --- Optimistic appliers: the local guess shown before the server responds --

export function applyMilestonePatch(
  pursuits: Pursuit[],
  pursuitId: string,
  milestoneId: string,
  patch: Partial<Milestone>
): Pursuit[] {
  return pursuits.map((p) =>
    p.id === pursuitId
      ? {
          ...p,
          milestones: p.milestones.map((m) => (m.id === milestoneId ? { ...m, ...patch } : m)),
        }
      : p
  );
}

export function applyPursuitPatch(
  pursuits: Pursuit[],
  pursuitId: string,
  patch: Partial<Pursuit>
): Pursuit[] {
  return pursuits.map((p) => (p.id === pursuitId ? { ...p, ...patch } : p));
}

// --- Optimistic orchestration (UI-agnostic, dependency-injected) -----------

export interface OptimisticUpdate<T> {
  // List state immediately after the optimistic guess is applied.
  optimistic: Pursuit[];
  // List state to restore if the request fails.
  snapshot: Pursuit[];
  // The network mutation.
  call: () => Promise<T>;
  // Fold the authoritative server result onto the optimistic state.
  reconcile: (result: T) => Pursuit[];
}

// Show the optimistic guess, call the server, reconcile on success, and roll
// back to the snapshot + report on failure. `setPursuits` and `onError` are
// injected so this is testable without React.
export async function runOptimisticUpdate<T>(
  update: OptimisticUpdate<T>,
  setPursuits: (pursuits: Pursuit[]) => void,
  onError?: (message: string) => void
): Promise<void> {
  setPursuits(update.optimistic);
  try {
    const result = await update.call();
    setPursuits(update.reconcile(result));
  } catch (err) {
    setPursuits(update.snapshot);
    onError?.(err instanceof Error ? err.message : 'Update failed');
  }
}
