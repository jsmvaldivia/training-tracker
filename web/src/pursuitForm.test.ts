import { describe, expect, it } from 'bun:test';
import type { Pursuit } from './types';
import { formValuesFor, parseTags, toCreateBody, toDateInput, toIsoDate, toUpdatePatch } from './pursuitForm';

function pursuit(over: Partial<Pursuit> = {}): Pursuit {
  return {
    id: 'p1',
    name: 'Pursuit',
    type: 'training',
    status: 'in_progress',
    target_date: '2026-12-31T00:00:00Z',
    started_at: '2026-06-01T00:00:00Z',
    tags: [],
    milestones: [],
    ...over,
  };
}

describe('date mapping', () => {
  it('turns a date input into a UTC midnight timestamp the contract accepts', () => {
    expect(toIsoDate('2026-06-01')).toBe('2026-06-01T00:00:00Z');
  });

  it('turns an ISO timestamp back into the date input value', () => {
    expect(toDateInput('2026-06-01T14:30:00Z')).toBe('2026-06-01');
    expect(toDateInput(undefined)).toBe('');
  });
});

describe('parseTags', () => {
  it('splits on commas, trims, and drops blanks and duplicates', () => {
    expect(parseTags(' cloud, aws ,,aws, ')).toEqual(['cloud', 'aws']);
    expect(parseTags('')).toEqual([]);
  });
});

describe('formValuesFor', () => {
  it('starts empty for a new pursuit', () => {
    expect(formValuesFor()).toEqual({
      name: '',
      type: 'training',
      started_at: '',
      target_date: '',
      expires_at: '',
      tags: '',
      description: '',
    });
  });

  it('prefills from an existing pursuit', () => {
    const values = formValuesFor(
      pursuit({ type: 'certification', expires_at: '2028-01-01T00:00:00Z', tags: ['a', 'b'], description: 'x' })
    );
    expect(values).toEqual({
      name: 'Pursuit',
      type: 'certification',
      started_at: '2026-06-01',
      target_date: '2026-12-31',
      expires_at: '2028-01-01',
      tags: 'a, b',
      description: 'x',
    });
  });
});

describe('toCreateBody', () => {
  it('maps every field and omits blank optionals', () => {
    expect(
      toCreateBody({
        name: 'X',
        type: 'certification',
        started_at: '2026-06-01',
        target_date: '2026-12-31',
        expires_at: '',
        tags: '',
        description: '',
      })
    ).toEqual({
      name: 'X',
      type: 'certification',
      started_at: '2026-06-01T00:00:00Z',
      target_date: '2026-12-31T00:00:00Z',
      tags: [],
    });
  });

  it('includes optionals when given', () => {
    const body = toCreateBody({
      name: 'X',
      type: 'training',
      started_at: '2026-06-01',
      target_date: '2026-12-31',
      expires_at: '2028-01-01',
      tags: 'a, b',
      description: 'notes',
    });
    expect(body.expires_at).toBe('2028-01-01T00:00:00Z');
    expect(body.tags).toEqual(['a', 'b']);
    expect(body.description).toBe('notes');
  });
});

describe('toUpdatePatch', () => {
  const original = pursuit({ tags: ['a', 'b'], description: 'notes', expires_at: '2028-01-01T00:00:00Z' });

  it('is empty when nothing changed', () => {
    expect(toUpdatePatch(formValuesFor(original), original)).toEqual({});
  });

  it('contains only the fields that changed, mapped to the contract', () => {
    const values = { ...formValuesFor(original), name: ' Renamed ', tags: 'b, c', target_date: '2027-01-31' };
    expect(toUpdatePatch(values, original)).toEqual({
      name: 'Renamed',
      tags: ['b', 'c'],
      target_date: '2027-01-31T00:00:00Z',
    });
  });

  it('sends an empty description when the notes are cleared', () => {
    const values = { ...formValuesFor(original), description: '' };
    expect(toUpdatePatch(values, original)).toEqual({ description: '' });
  });

  it('leaves expires_at alone when the input is cleared (the API cannot unset it)', () => {
    const values = { ...formValuesFor(original), expires_at: '' };
    expect(toUpdatePatch(values, original)).toEqual({});
  });
});
