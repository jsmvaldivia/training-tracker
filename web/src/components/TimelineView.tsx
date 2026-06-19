import React from 'react';
import { format, parseISO, isBefore, isAfter, differenceInDays } from 'date-fns';
import { Pursuit } from '../types';
import { calculateDerivedState, cn } from '../utils';
interface TimelineViewProps {
  pursuits: Pursuit[];
}
export function TimelineView({ pursuits }: TimelineViewProps) {
  if (pursuits.length === 0)
  return (
    <div className="p-8 text-center text-slate-500">
        No pursuits to display.
      </div>);

  // Find min and max dates to establish the timeline scale
  const allDates = pursuits.flatMap((p) => [
  parseISO(p.started_at),
  parseISO(p.target_date),
  ...(p.completed_at ? [parseISO(p.completed_at)] : []),
  ...p.milestones.map((m) => parseISO(m.date))]
  );
  const minDate = new Date(Math.min(...allDates.map((d) => d.getTime())));
  const maxDate = new Date(
    Math.max(
      ...allDates.map((d) => d.getTime()),
      Date.now() + 30 * 24 * 60 * 60 * 1000
    )
  ); // Add a month buffer
  const totalDays = differenceInDays(maxDate, minDate) || 1;
  const getPercentage = (dateStr: string) => {
    const date = parseISO(dateStr);
    const days = differenceInDays(date, minDate);
    return Math.max(0, Math.min(days / totalDays * 100, 100));
  };
  const todayPercentage = getPercentage(new Date().toISOString());
  return (
    <div className="bg-white border border-slate-200 rounded-xl p-6 overflow-x-auto">
      <div className="min-w-[800px]">
        {/* Timeline Header / Axis */}
        <div className="relative h-8 border-b border-slate-200 mb-6">
          <div className="absolute left-0 text-xs font-medium text-slate-400 -bottom-2 bg-white px-1">
            {format(minDate, 'MMM yyyy')}
          </div>
          <div className="absolute right-0 text-xs font-medium text-slate-400 -bottom-2 bg-white px-1">
            {format(maxDate, 'MMM yyyy')}
          </div>

          {/* Today Marker */}
          <div
            className="absolute top-0 bottom-0 border-l-2 border-dashed border-indigo-300 z-0"
            style={{
              left: `${todayPercentage}%`
            }}>

            <div className="absolute -top-6 -left-3 text-[10px] font-bold text-indigo-500 bg-indigo-50 px-1.5 py-0.5 rounded">
              Today
            </div>
          </div>
        </div>

        {/* Pursuits */}
        <div className="flex flex-col gap-6 relative z-10">
          {pursuits.map((pursuit) => {
            const derived = calculateDerivedState(pursuit);
            const startPct = getPercentage(pursuit.started_at);
            const targetPct = getPercentage(pursuit.target_date);
            const endPct = pursuit.completed_at ?
            getPercentage(pursuit.completed_at) :
            targetPct;
            const isCompleted = pursuit.status === 'completed';
            const isOverdue = derived.isOverdue && !isCompleted;
            return (
              <div key={pursuit.id} className="flex items-center gap-4 group">
                <div className="w-48 flex-shrink-0 truncate text-sm font-medium text-slate-700 group-hover:text-indigo-600 transition-colors">
                  {pursuit.name}
                </div>

                <div className="flex-1 relative h-12 flex items-center">
                  {/* Background Track */}
                  <div className="absolute left-0 right-0 h-1 bg-slate-100 rounded-full" />

                  {/* Pursuit Span */}
                  <div
                    className={cn(
                      'absolute h-2.5 rounded-full opacity-80',
                      isCompleted ?
                      'bg-emerald-500' :
                      isOverdue ?
                      'bg-red-500' :
                      'bg-indigo-500'
                    )}
                    style={{
                      left: `${startPct}%`,
                      width: `${Math.max(endPct - startPct, 1)}%`
                    }} />


                  {/* Target Date Marker */}
                  {!isCompleted &&
                  <div
                    className={cn(
                      'absolute w-1 h-4 rounded-full -mt-0.5',
                      isOverdue ? 'bg-red-600' : 'bg-slate-400'
                    )}
                    style={{
                      left: `${targetPct}%`
                    }}
                    title={`Target: ${format(parseISO(pursuit.target_date), 'MMM d')}`} />

                  }

                  {/* Milestones */}
                  {pursuit.milestones.map((m) => {
                    const mPct = getPercentage(m.date);
                    const mAchieved = m.state === 'achieved';
                    return (
                      <div
                        key={m.id}
                        className={cn(
                          'absolute w-3 h-3 rounded-full border-2 bg-white -mt-0.5 transform -translate-x-1.5 cursor-help',
                          mAchieved ? 'border-emerald-500' : 'border-slate-400'
                        )}
                        style={{
                          left: `${mPct}%`
                        }}
                        title={`${m.name} (${format(parseISO(m.date), 'MMM d')})`} />);


                  })}
                </div>
              </div>);

          })}
        </div>
      </div>
    </div>);

}
