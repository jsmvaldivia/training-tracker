import React from 'react';
import { cn } from '../utils';
interface BadgeProps extends React.HTMLAttributes<HTMLDivElement> {
  variant?: 'default' | 'success' | 'warning' | 'danger' | 'info' | 'outline';
  children: React.ReactNode;
}
export function Badge({
  variant = 'default',
  className,
  children,
  ...props
}: BadgeProps) {
  const variants = {
    default: 'bg-slate-100 text-slate-800 border-slate-200',
    success: 'bg-emerald-50 text-emerald-700 border-emerald-200',
    warning: 'bg-amber-50 text-amber-700 border-amber-200',
    danger: 'bg-red-50 text-red-700 border-red-200',
    info: 'bg-indigo-50 text-indigo-700 border-indigo-200',
    outline: 'bg-transparent text-slate-600 border-slate-200'
  };
  return (
    <div
      className={cn(
        'inline-flex items-center px-2 py-0.5 rounded-full text-xs font-medium border',
        variants[variant],
        className
      )}
      {...props}>

      {children}
    </div>);

}
