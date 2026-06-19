import React from 'react';
import { Award, BookOpen, Clock, AlertCircle, CheckCircle2 } from 'lucide-react';
import { Pursuit, PursuitDerivedState } from '../types';
import { calculateDerivedState, cn } from '../utils';
import { Badge } from './Badge';
import { ProgressBars } from './ProgressBars';
import { format, parseISO } from 'date-fns';
interface PursuitCardProps {
  pursuit: Pursuit;
  onClick: () => void;
}
export function PursuitCard({ pursuit, onClick }: PursuitCardProps) {
  const derived = calculateDerivedState(pursuit);
  const isOverdue = derived.isOverdue && pursuit.status !== 'completed';
  const getSignalBadge = (signal: PursuitDerivedState['signal']) => {
    switch (signal) {
      case 'ahead':
        return <Badge variant="success">Ahead</Badge>;
      case 'behind':
        return <Badge variant="warning">Behind</Badge>;
      case 'on_track':
        return <Badge variant="info">On Track</Badge>;
      case 'completed':
        return <Badge variant="success">Done</Badge>;
      case 'not_started':
        return <Badge variant="outline">Not Started</Badge>;
    }
  };
  const getStatusDisplay = () => {
    switch (pursuit.status) {
      case 'planned':
        return {
          label: 'Planned',
          color: 'text-slate-500'
        };
      case 'in_progress':
        return {
          label: 'In Progress',
          color: 'text-indigo-600'
        };
      case 'completed':
        return {
          label: 'Completed',
          color: 'text-emerald-600'
        };
      case 'expired':
        return {
          label: 'Expired',
          color: 'text-red-600'
        };
    }
  };
  const statusDisplay = getStatusDisplay();
  return (
    <div
      onClick={onClick}
      className={cn(
        'flex flex-col gap-4 p-4 bg-white border rounded-xl cursor-pointer transition-all hover:shadow-md hover:border-slate-300',
        isOverdue ?
        'border-l-4 border-l-red-500 border-y-red-200 border-r-red-200' :
        'border-slate-200'
      )}>

      <div className="flex justify-between items-start gap-4">
        <div className="flex-1">
          <div className="flex items-center gap-2 mb-1">
            {pursuit.type === 'certification' ?
            <Award className="w-4 h-4 text-indigo-500" /> :

            <BookOpen className="w-4 h-4 text-indigo-500" />
            }
            <span
              className={cn(
                'text-xs font-semibold uppercase tracking-wider',
                statusDisplay.color
              )}>

              {statusDisplay.label}
            </span>
          </div>
          <h3 className="font-semibold text-slate-900 leading-tight">
            {pursuit.name}
          </h3>
        </div>
        <div>{getSignalBadge(derived.signal)}</div>
      </div>

      <div className="flex items-center gap-1.5 text-xs text-slate-500">
        {pursuit.status === 'completed' ?
        <>
            <CheckCircle2 className="w-3.5 h-3.5 text-emerald-500" />
            <span>
              Completed{' '}
              {pursuit.completed_at ?
            format(parseISO(pursuit.completed_at), 'MMM d, yyyy') :
            ''}
            </span>
          </> :
        isOverdue ?
        <>
            <AlertCircle className="w-3.5 h-3.5 text-red-500" />
            <span className="text-red-600 font-medium">
              {Math.abs(derived.daysRemaining)} days overdue
            </span>
          </> :

        <>
            <Clock className="w-3.5 h-3.5" />
            <span>
              Target: {format(parseISO(pursuit.target_date), 'MMM d, yyyy')}
              {derived.daysRemaining > 0 &&
            ` (${derived.daysRemaining} days left)`}
            </span>
          </>
        }
      </div>

      <ProgressBars
        timeProgress={derived.timeProgress}
        achievementProgress={derived.achievementProgress}
        isOverdue={isOverdue} />


      {pursuit.tags.length > 0 &&
      <div className="flex flex-wrap gap-1.5 mt-1">
          {pursuit.tags.map((tag) =>
        <span
          key={tag}
          className="px-2 py-0.5 bg-slate-100 text-slate-600 text-[10px] font-medium rounded-md">

              {tag}
            </span>
        )}
        </div>
      }
    </div>);

}
