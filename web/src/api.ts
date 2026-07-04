import { Pursuit, PursuitType, MilestoneState } from './types';

// API client for Training Tracker backend (proxied via /api/* → http://127.0.0.1:8080)
// All endpoints match the OpenAPI contract at api/openapi.yaml

const API_BASE = '/api';

interface PursuitsListResponse {
  data: Pursuit[];
  total: number;
  limit: number;
  offset: number;
}

interface PursuitCreate {
  name: string;
  type: PursuitType;
  status?: 'planned' | 'in_progress' | 'completed' | 'expired';
  description?: string;
  target_date: string;
  started_at: string;
  expires_at?: string;
  tags?: string[];
  milestones?: Array<{
    name: string;
    date: string;
    state?: MilestoneState;
  }>;
}

export interface PursuitUpdate {
  name?: string;
  type?: PursuitType;
  status?: 'planned' | 'in_progress' | 'completed' | 'expired';
  description?: string;
  target_date?: string;
  started_at?: string;
  expires_at?: string;
  tags?: string[];
}

interface MilestoneCreate {
  name: string;
  date: string;
  state?: MilestoneState;
}

export interface MilestoneUpdate {
  name?: string;
  date?: string;
  state?: MilestoneState;
}

async function fetchJSON<T>(url: string, options?: RequestInit): Promise<T> {
  const response = await fetch(url, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...options?.headers,
    },
  });

  if (!response.ok) {
    const error = await response.json().catch(() => ({ message: response.statusText }));
    throw new Error(error.message || `HTTP ${response.status}`);
  }

  return response.json();
}

export const api = {
  // Health check
  async health(): Promise<{ status: string }> {
    return fetchJSON(`${API_BASE}/health`);
  },

  // List pursuits (with optional filtering and pagination)
  async listPursuits(params?: {
    type?: PursuitType;
    limit?: number;
    offset?: number;
  }): Promise<PursuitsListResponse> {
    const query = new URLSearchParams();
    if (params?.type) query.set('type', params.type);
    if (params?.limit) query.set('limit', params.limit.toString());
    if (params?.offset) query.set('offset', params.offset.toString());

    const url = `${API_BASE}/pursuits${query.toString() ? `?${query}` : ''}`;
    return fetchJSON(url);
  },

  // Get single pursuit by ID
  async getPursuit(id: string): Promise<Pursuit> {
    return fetchJSON(`${API_BASE}/pursuits/${id}`);
  },

  // Create new pursuit
  async createPursuit(data: PursuitCreate): Promise<Pursuit> {
    return fetchJSON(`${API_BASE}/pursuits`, {
      method: 'POST',
      body: JSON.stringify(data),
    });
  },

  // Update pursuit
  async updatePursuit(id: string, data: PursuitUpdate): Promise<Pursuit> {
    return fetchJSON(`${API_BASE}/pursuits/${id}`, {
      method: 'PATCH',
      body: JSON.stringify(data),
    });
  },

  // Delete pursuit
  async deletePursuit(id: string): Promise<void> {
    await fetch(`${API_BASE}/pursuits/${id}`, { method: 'DELETE' });
  },

  // Create milestone
  async createMilestone(pursuitId: string, data: MilestoneCreate): Promise<Pursuit['milestones'][0]> {
    return fetchJSON(`${API_BASE}/pursuits/${pursuitId}/milestones`, {
      method: 'POST',
      body: JSON.stringify(data),
    });
  },

  // Update milestone
  async updateMilestone(
    pursuitId: string,
    milestoneId: string,
    data: MilestoneUpdate
  ): Promise<Pursuit['milestones'][0]> {
    return fetchJSON(`${API_BASE}/pursuits/${pursuitId}/milestones/${milestoneId}`, {
      method: 'PATCH',
      body: JSON.stringify(data),
    });
  },

  // Delete milestone
  async deleteMilestone(pursuitId: string, milestoneId: string): Promise<void> {
    await fetch(`${API_BASE}/pursuits/${pursuitId}/milestones/${milestoneId}`, {
      method: 'DELETE',
    });
  },
};
