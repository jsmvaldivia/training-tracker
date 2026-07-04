import { useState } from 'react';
import { usePursuits } from './hooks/usePursuits';
import { ToastProvider, useToast } from './components/Toast';
import { DashboardHeader } from './components/DashboardHeader';
import { PursuitCard } from './components/PursuitCard';
import { PursuitDetailPanel } from './components/PursuitDetailPanel';
import { TimelineView } from './components/TimelineView';

export function App() {
  // usePursuits calls useToast(), so App must render inside the provider.
  return (
    <ToastProvider>
      <AppContent />
    </ToastProvider>
  );
}

function AppContent() {
  const toast = useToast();
  const { pursuits, loading, error, updateMilestone, updatePursuit } = usePursuits({
    onError: toast.error,
  });
  const [view, setView] = useState<'dashboard' | 'timeline'>('dashboard');
  const [filterType, setFilterType] = useState<'all' | 'certification' | 'training'>('all');
  const [selectedPursuitId, setSelectedPursuitId] = useState<string | null>(null);

  const filteredPursuits = pursuits.filter((p) => {
    if (filterType !== 'all' && p.type !== filterType) return false;
    return true;
  });

  const selectedPursuit = pursuits.find((p) => p.id === selectedPursuitId) || null;

  const handleToggleMilestone = (milestoneId: string) => {
    if (!selectedPursuit) return;
    const milestone = selectedPursuit.milestones.find((m) => m.id === milestoneId);
    if (!milestone) return;
    const nextState = milestone.state === 'achieved' ? 'pending' : 'achieved';
    void updateMilestone(selectedPursuit.id, milestoneId, { state: nextState });
  };

  const handleStatusChange = (status: (typeof pursuits)[number]['status']) => {
    if (!selectedPursuit) return;
    void updatePursuit(selectedPursuit.id, { status });
  };

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
        onToggleMilestone={handleToggleMilestone}
        onStatusChange={handleStatusChange}
      />
    </div>
  );
}
