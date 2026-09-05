import type { PursuitCreate } from './api';
import type { Pursuit, PursuitType } from './types';

// Pure mapping between the pursuit form (issues #20, #23) and the contract's
// request bodies. Kept React-free so `bun test` covers it without a DOM.
//
// Dates: the form uses <input type="date"> (YYYY-MM-DD); the API wants ISO
// 8601 UTC timestamps. A picked day maps to UTC midnight, matching the seed.

export interface PursuitFormValues {
  name: string;
  type: PursuitType;
  started_at: string; // YYYY-MM-DD
  target_date: string; // YYYY-MM-DD
  expires_at: string; // YYYY-MM-DD or ''
  tags: string; // comma-separated
  description: string;
}

export function toIsoDate(dateInput: string): string {
  return `${dateInput}T00:00:00Z`;
}

export function toDateInput(iso: string | undefined): string {
  return iso ? iso.slice(0, 10) : '';
}

export function parseTags(text: string): string[] {
  const tags: string[] = [];
  for (const raw of text.split(',')) {
    const tag = raw.trim();
    if (tag && !tags.includes(tag)) tags.push(tag);
  }
  return tags;
}

export function formValuesFor(pursuit?: Pursuit): PursuitFormValues {
  return {
    name: pursuit?.name ?? '',
    type: pursuit?.type ?? 'training',
    started_at: toDateInput(pursuit?.started_at),
    target_date: toDateInput(pursuit?.target_date),
    expires_at: toDateInput(pursuit?.expires_at),
    tags: pursuit?.tags.join(', ') ?? '',
    description: pursuit?.description ?? '',
  };
}

// PursuitCreate body: required fields always, optionals only when filled so
// the server applies its defaults and stores nothing empty.
export function toCreateBody(values: PursuitFormValues): PursuitCreate {
  const body: PursuitCreate = {
    name: values.name.trim(),
    type: values.type,
    started_at: toIsoDate(values.started_at),
    target_date: toIsoDate(values.target_date),
    tags: parseTags(values.tags),
  };
  if (values.expires_at) body.expires_at = toIsoDate(values.expires_at);
  const description = values.description.trim();
  if (description) body.description = description;
  return body;
}
