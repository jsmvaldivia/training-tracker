import React from 'react';
import { cn } from '../utils';
interface ProgressBarsProps {
  timeProgress: number;
  achievementProgress: number;
  isOverdue?: boolean;
  className?: string;
}
export function ProgressBars({
  timeProgress,
  achievementProgress,
  isOverdue,
  className
}: ProgressBarsProps) {
  return (
    <div className={cn('flex flex-col gap-2', className)}>
      <div className="flex items-center gap-2">
        <div className="w-8 text-[10px] font-medium text-slate-500 uppercase tracking-wider">
          Time
        </div>
        <div className="flex-1 h-2 bg-slate-100 rounded-full overflow-hidden">
          <div
            className={cn(
              'h-full rounded-full transition-all duration-500',
              isOverdue ? 'bg-red-500' : 'bg-slate-500'
            )}
            style={{
              width: `${timeProgress}%`
            }} />

        </div>
      </div>
      <div className="flex items-center gap-2">
        <div className="w-8 text-[10px] font-medium text-indigo-500 uppercase tracking-wider">
          Achv
        </div>
        <div className="flex-1 h-2 bg-slate-100 rounded-full overflow-hidden">
          <div
            className="h-full bg-indigo-500 rounded-full transition-all duration-500"
            style={{
              width: `${achievementProgress}%`
            }} />

        </div>
      </div>
    </div>);

}
