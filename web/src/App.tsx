import { useEffect, useState } from 'react';
import type { Pursuit } from './types';
import { usePursuits } from './hooks/usePursuits';
import { DashboardHeader } from './components/DashboardHeader';
import { PursuitCard } from './components/PursuitCard';
import { PursuitDetailPanel } from './components/PursuitDetailPanel';
import { TimelineView } from './components/TimelineView';

export function App() {
  // usePursuits owns the fetched list (read path, issue #3). The local mirror
  // below keeps the existing detail-panel mutation working until issue #4 moves
  // mutations into the hook; it is seeded from the hook's fetched data.
  const { pursuits: fetchedPursuits, loading, error } = usePursuits();
  const [pursuits, setPursuits] = useState<Pursuit[]>([]);
  const [view, setView] = useState<'dashboard' | 'timeline'>('dashboard');
  const [filterType, setFilterType] = useState<'all' | 'certification' | 'training'>('all');
  const [selectedPursuitId, setSelectedPursuitId] = useState<string | null>(null);

  useEffect(() => {
    setPursuits(fetchedPursuits);
  }, [fetchedPursuits]);

  const handleUpdatePursuit = (updated: Pursuit) => {
    setPursuits((prev) => prev.map((p) => (p.id === updated.id ? updated : p)));
  };

  const filteredPursuits = pursuits.filter((p) => {
    if (filterType !== 'all' && p.type !== filterType) return false;
    return true;
  });

  const selectedPursuit = pursuits.find((p) => p.id === selectedPursuitId) || null;

  return (
    <div className="min-h-screen bg-slate-50 font-sans text-slate-900 selection:bg-indigo-100 selection:text-indigo-900">
      <div className="max-w-6xl mx-auto px-4 py-8">
        <DashboardHeader
          pursuits={pursuits}
          view={view}
          onViewChange={setView}
          filterType={filterType}
          onFilterTypeChange={setFilterType}
        />

        <main>
          {loading ? (
            <div
              role="status"
              aria-live="polite"
              className="p-12 text-center text-slate-500"
            >
              Loading pursuits…
            </div>
          ) : error ? (
            <div
              role="alert"
              className="p-12 text-center text-rose-600 bg-white border border-rose-200 rounded-xl border-dashed"
            >
              Couldn't load pursuits: {error}
            </div>
          ) : view === 'dashboard' ? (
            <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
              {filteredPursuits.map((pursuit) => (
                <PursuitCard
                  key={pursuit.id}
                  pursuit={pursuit}
                  onClick={() => setSelectedPursuitId(pursuit.id)}
                />
              ))}
              {filteredPursuits.length === 0 && (
                <div className="col-span-full p-12 text-center text-slate-500 bg-white border border-slate-200 rounded-xl border-dashed">
                  No pursuits found matching your filters.
                </div>
              )}
            </div>
          ) : (
            <TimelineView pursuits={filteredPursuits} />
          )}
        </main>
      </div>

      <PursuitDetailPanel
        pursuit={selectedPursuit}
        onClose={() => setSelectedPursuitId(null)}
        onUpdatePursuit={handleUpdatePursuit}
      />
    </div>
  );
}
