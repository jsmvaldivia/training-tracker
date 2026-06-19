import React from 'react';
import { LayoutGrid, List, Plus } from 'lucide-react';
import { Pursuit } from '../types';
import { calculateDerivedState, cn } from '../utils';
interface DashboardHeaderProps {
  pursuits: Pursuit[];
  view: 'dashboard' | 'timeline';
  onViewChange: (view: 'dashboard' | 'timeline') => void;
  filterType: 'all' | 'certification' | 'training';
  onFilterTypeChange: (type: 'all' | 'certification' | 'training') => void;
}
export function DashboardHeader({
  pursuits,
  view,
  onViewChange,
  filterType,
  onFilterTypeChange
}: DashboardHeaderProps) {
  const stats = pursuits.reduce(
    (acc, pursuit) => {
      const derived = calculateDerivedState(pursuit);
      acc.total++;
      if (pursuit.status === 'completed') acc.completed++;else
      if (derived.isOverdue) acc.overdue++;else
      if (derived.signal === 'behind') acc.atRisk++;
      return acc;
    },
    {
      total: 0,
      completed: 0,
      overdue: 0,
      atRisk: 0
    }
  );
  return (
    <div className="flex flex-col gap-6 mb-8">
      <div className="flex flex-col sm:flex-row sm:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-slate-900 tracking-tight">
            Training Tracker
          </h1>
          <p className="text-sm text-slate-500 mt-1">
            Manage your corporate certifications and trainings.
          </p>
        </div>

        <div className="flex items-center gap-3">
          {/* View Toggle */}
          <div className="flex items-center bg-white border border-slate-200 rounded-lg p-1 shadow-sm">
            <button
              onClick={() => onViewChange('dashboard')}
              className={cn(
                'flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium rounded-md transition-colors',
                view === 'dashboard' ?
                'bg-indigo-50 text-indigo-700' :
                'text-slate-600 hover:text-slate-900'
              )}>

              <LayoutGrid className="w-4 h-4" />
              Dashboard
            </button>
            <button
              onClick={() => onViewChange('timeline')}
              className={cn(
                'flex items-center gap-1.5 px-3 py-1.5 text-sm font-medium rounded-md transition-colors',
                view === 'timeline' ?
                'bg-indigo-50 text-indigo-700' :
                'text-slate-600 hover:text-slate-900'
              )}>

              <List className="w-4 h-4" />
              Timeline
            </button>
          </div>

          <select
            value={filterType}
            onChange={(e) => onFilterTypeChange(e.target.value as any)}
            className="h-9 px-3 text-sm font-medium bg-white border border-slate-200 rounded-lg text-slate-700 focus:outline-none focus:ring-2 focus:ring-indigo-500 shadow-sm">

            <option value="all">All Types</option>
            <option value="certification">Certifications</option>
            <option value="training">Trainings</option>
          </select>

          <button className="flex items-center gap-1.5 h-9 px-4 bg-indigo-600 hover:bg-indigo-700 text-white text-sm font-medium rounded-lg shadow-sm transition-colors">
            <Plus className="w-4 h-4" />
            Add Pursuit
          </button>
        </div>
      </div>

      {/* Summary Chips */}
      <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <div className="bg-white border border-slate-200 rounded-lg p-3 flex flex-col gap-1 shadow-sm">
          <span className="text-xs font-medium text-slate-500 uppercase tracking-wider">
            Total Pursuits
          </span>
          <span className="text-2xl font-bold text-slate-900">
            {stats.total}
          </span>
        </div>
        <div className="bg-white border border-amber-200 rounded-lg p-3 flex flex-col gap-1 shadow-sm">
          <span className="text-xs font-medium text-amber-600 uppercase tracking-wider">
            At Risk
          </span>
          <span className="text-2xl font-bold text-amber-700">
            {stats.atRisk}
          </span>
        </div>
        <div className="bg-white border border-red-200 rounded-lg p-3 flex flex-col gap-1 shadow-sm">
          <span className="text-xs font-medium text-red-600 uppercase tracking-wider">
            Overdue
          </span>
          <span className="text-2xl font-bold text-red-700">
            {stats.overdue}
          </span>
        </div>
        <div className="bg-white border border-emerald-200 rounded-lg p-3 flex flex-col gap-1 shadow-sm">
          <span className="text-xs font-medium text-emerald-600 uppercase tracking-wider">
            Completed
          </span>
          <span className="text-2xl font-bold text-emerald-700">
            {stats.completed}
          </span>
        </div>
      </div>
    </div>);

}
