import { clsx, type ClassValue } from 'clsx';
import { twMerge } from 'tailwind-merge';
import { differenceInDays, isPast, isBefore, parseISO } from 'date-fns';
import { Pursuit, PursuitDerivedState } from './types';

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs));
}

export function calculateDerivedState(
pursuit: Pursuit,
now: Date = new Date())
: PursuitDerivedState {
  const startedAt = parseISO(pursuit.started_at);
  const targetDate = parseISO(pursuit.target_date);

  let timeProgress = 0;
  let isOverdue = false;
  let daysRemaining = differenceInDays(targetDate, now);

  if (pursuit.completed_at) {
    timeProgress = 100;
  } else if (isBefore(now, startedAt)) {
    timeProgress = 0;
  } else if (isPast(targetDate)) {
    timeProgress = 100;
    isOverdue = true;
  } else {
    const totalDuration = targetDate.getTime() - startedAt.getTime();
    const elapsed = now.getTime() - startedAt.getTime();
    timeProgress = Math.min(Math.max(elapsed / totalDuration * 100, 0), 100);
  }

  let achievementProgress = 0;
  if (pursuit.milestones.length === 0) {
    achievementProgress = pursuit.completed_at ? 100 : 0;
  } else {
    const achieved = pursuit.milestones.filter(
      (m) => m.state === 'achieved'
    ).length;
    achievementProgress = achieved / pursuit.milestones.length * 100;
  }

  let signal: PursuitDerivedState['signal'] = 'not_started';

  if (pursuit.status === 'completed') {
    signal = 'completed';
  } else if (pursuit.status === 'planned' || isBefore(now, startedAt)) {
    signal = 'not_started';
  } else {
    const gap = timeProgress - achievementProgress;
    if (gap > 15) {
      signal = 'behind';
    } else if (gap < -15) {
      signal = 'ahead';
    } else {
      signal = 'on_track';
    }
  }

  return {
    timeProgress,
    achievementProgress,
    signal,
    isOverdue,
    daysRemaining
  };
}

export function generateId() {
  return Math.random().toString(36).substring(2, 9);
}
