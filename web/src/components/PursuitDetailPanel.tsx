import React from 'react';
import {
  X,
  Calendar,
  Tag,
  CheckCircle2,
  Circle,
  Award,
  BookOpen } from
'lucide-react';
import { Pursuit, PursuitStatus } from '../types';
import { calculateDerivedState, cn } from '../utils';
import { ProgressBars } from './ProgressBars';
import { Badge } from './Badge';
import { format, parseISO } from 'date-fns';
interface PursuitDetailPanelProps {
  pursuit: Pursuit | null;
  onClose: () => void;
  // Presentational: the panel only signals intent. The owner (App + usePursuits)
  // performs the optimistic update, server call, reconcile, and rollback. The
  // panel does not stamp achieved_at / completed_at — the server does.
  onToggleMilestone: (milestoneId: string) => void;
  onStatusChange: (status: PursuitStatus) => void;
}
export function PursuitDetailPanel({
  pursuit,
  onClose,
  onToggleMilestone,
  onStatusChange
}: PursuitDetailPanelProps) {
  if (!pursuit) return null;
  const derived = calculateDerivedState(pursuit);
  const isOverdue = derived.isOverdue && pursuit.status !== 'completed';
  const handleStatusChange = (e: React.ChangeEvent<HTMLSelectElement>) => {
    onStatusChange(e.target.value as PursuitStatus);
  };
  return (
    <>
      {/* Backdrop */}
      <div
        className="fixed inset-0 bg-slate-900/20 backdrop-blur-sm z-40 transition-opacity"
        onClick={onClose} />


      {/* Panel */}
      <div className="fixed inset-y-0 right-0 w-full max-w-md bg-white shadow-2xl z-50 flex flex-col border-l border-slate-200 transform transition-transform duration-300 ease-in-out">
        <div className="flex items-center justify-between p-4 border-b border-slate-100">
          <div className="flex items-center gap-2 text-slate-500">
            {pursuit.type === 'certification' ?
            <Award className="w-4 h-4" /> :

            <BookOpen className="w-4 h-4" />
            }
            <span className="text-sm font-medium capitalize">
              {pursuit.type}
            </span>
          </div>
          <button
            onClick={onClose}
            className="p-1.5 text-slate-400 hover:text-slate-600 hover:bg-slate-100 rounded-md transition-colors">

            <X className="w-5 h-5" />
          </button>
        </div>

        <div className="flex-1 overflow-y-auto p-6 flex flex-col gap-8">
          {/* Header Section */}
          <div className="flex flex-col gap-4">
            <h2 className="text-2xl font-bold text-slate-900 leading-tight">
              {pursuit.name}
            </h2>

            <div className="flex flex-wrap items-center gap-3">
              <select
                value={pursuit.status}
                onChange={handleStatusChange}
                className="text-sm font-medium bg-slate-50 border border-slate-200 rounded-md px-2 py-1 text-slate-700 focus:outline-none focus:ring-2 focus:ring-indigo-500">

                <option value="planned">Planned</option>
                <option value="in_progress">In Progress</option>
                <option value="completed">Completed</option>
                <option value="expired">Expired</option>
              </select>

              {isOverdue && <Badge variant="danger">Overdue</Badge>}
              {derived.signal === 'ahead' &&
              <Badge variant="success">Ahead of Schedule</Badge>
              }
              {derived.signal === 'behind' &&
              <Badge variant="warning">Behind Schedule</Badge>
              }
            </div>
          </div>

          {/* Progress Section */}
          <div className="flex flex-col gap-3">
            <h3 className="text-sm font-semibold text-slate-900">Progress</h3>
            <ProgressBars
              timeProgress={derived.timeProgress}
              achievementProgress={derived.achievementProgress}
              isOverdue={isOverdue} />

          </div>

          {/* Dates Section */}
          <div className="flex flex-col gap-3">
            <h3 className="text-sm font-semibold text-slate-900">Timeline</h3>
            <div className="grid grid-cols-2 gap-4">
              <div className="flex flex-col gap-1">
                <span className="text-xs text-slate-500 flex items-center gap-1">
                  <Calendar className="w-3 h-3" /> Started
                </span>
                <span className="text-sm font-medium text-slate-900">
                  {format(parseISO(pursuit.started_at), 'MMM d, yyyy')}
                </span>
              </div>
              <div className="flex flex-col gap-1">
                <span className="text-xs text-slate-500 flex items-center gap-1">
                  <Calendar className="w-3 h-3" /> Target
                </span>
                <span
                  className={cn(
                    'text-sm font-medium',
                    isOverdue ? 'text-red-600' : 'text-slate-900'
                  )}>

                  {format(parseISO(pursuit.target_date), 'MMM d, yyyy')}
                </span>
              </div>
              {pursuit.completed_at &&
              <div className="flex flex-col gap-1">
                  <span className="text-xs text-slate-500 flex items-center gap-1">
                    <CheckCircle2 className="w-3 h-3" /> Completed
                  </span>
                  <span className="text-sm font-medium text-emerald-600">
                    {format(parseISO(pursuit.completed_at), 'MMM d, yyyy')}
                  </span>
                </div>
              }
            </div>
          </div>

          {/* Milestones Section */}
          <div className="flex flex-col gap-3">
            <div className="flex items-center justify-between">
              <h3 className="text-sm font-semibold text-slate-900">
                Milestones
              </h3>
              <span className="text-xs text-slate-500">
                {
                pursuit.milestones.filter((m) => m.state === 'achieved').
                length
                }{' '}
                / {pursuit.milestones.length}
              </span>
            </div>

            {pursuit.milestones.length > 0 ?
            <div className="flex flex-col gap-2">
                {pursuit.milestones.map((milestone) => {
                const isAchieved = milestone.state === 'achieved';
                return (
                  <div
                    key={milestone.id}
                    onClick={() => onToggleMilestone(milestone.id)}
                    className={cn(
                      'flex items-start gap-3 p-3 rounded-lg border cursor-pointer transition-colors',
                      isAchieved ?
                      'bg-slate-50 border-slate-200' :
                      'bg-white border-slate-200 hover:border-indigo-300'
                    )}>

                      <button className="mt-0.5 flex-shrink-0 text-indigo-600">
                        {isAchieved ?
                      <CheckCircle2 className="w-5 h-5" /> :

                      <Circle className="w-5 h-5 text-slate-300" />
                      }
                      </button>
                      <div className="flex flex-col">
                        <span
                        className={cn(
                          'text-sm font-medium',
                          isAchieved ?
                          'text-slate-500 line-through' :
                          'text-slate-900'
                        )}>

                          {milestone.name}
                        </span>
                        <span className="text-xs text-slate-500">
                          {format(parseISO(milestone.date), 'MMM d')}
                        </span>
                      </div>
                    </div>);

              })}
              </div> :

            <div className="p-4 border border-dashed border-slate-300 rounded-lg text-center text-sm text-slate-500">
                No milestones defined.
              </div>
            }
          </div>

          {/* Tags & Notes */}
          <div className="flex flex-col gap-6">
            {pursuit.tags.length > 0 &&
            <div className="flex flex-col gap-2">
                <h3 className="text-sm font-semibold text-slate-900 flex items-center gap-1">
                  <Tag className="w-4 h-4 text-slate-400" /> Tags
                </h3>
                <div className="flex flex-wrap gap-2">
                  {pursuit.tags.map((tag) =>
                <span
                  key={tag}
                  className="px-2.5 py-1 bg-slate-100 text-slate-700 text-xs font-medium rounded-md">

                      {tag}
                    </span>
                )}
                </div>
              </div>
            }

            {pursuit.description &&
            <div className="flex flex-col gap-2">
                <h3 className="text-sm font-semibold text-slate-900">Notes</h3>
                <p className="text-sm text-slate-600 leading-relaxed bg-slate-50 p-3 rounded-lg border border-slate-100">
                  {pursuit.description}
                </p>
              </div>
            }
          </div>
        </div>
      </div>
    </>);

}
