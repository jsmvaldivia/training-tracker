export type PursuitType = 'certification' | 'training';
export type PursuitStatus = 'planned' | 'in_progress' | 'completed' | 'expired';
export type MilestoneState = 'pending' | 'achieved';

export interface Milestone {
  id: string;
  name: string;
  date: string; // ISO date string
  state: MilestoneState;
  achieved_at?: string; // ISO date string
}

export interface Pursuit {
  id: string;
  name: string;
  type: PursuitType;
  status: PursuitStatus;
  description?: string;
  target_date: string; // ISO date string
  started_at: string; // ISO date string
  completed_at?: string; // ISO date string
  expires_at?: string; // ISO date string (certs only)
  tags: string[];
  milestones: Milestone[];
}

export type Signal =
'ahead' |
'on_track' |
'behind' |
'completed' |
'not_started';

export interface PursuitDerivedState {
  timeProgress: number; // 0-100
  achievementProgress: number; // 0-100
  signal: Signal;
  isOverdue: boolean;
  daysRemaining: number;
}
