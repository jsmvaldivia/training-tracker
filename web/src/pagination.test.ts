import { describe, expect, it } from 'bun:test';
import { collectAllPages, PAGE_LIMIT } from './pagination';
import type { PageFetcher } from './pagination';

// A fake list endpoint over `items`: slices like the server and records what
// was asked for. `total` can lie, to test the guards.
function fakeList(items: number[], total = items.length) {
  const calls: Array<{ limit: number; offset: number }> = [];
  const fetchPage: PageFetcher<number> = async ({ limit, offset }) => {
    calls.push({ limit, offset });
    return { data: items.slice(offset, offset + limit), total, limit, offset };
  };
  return { fetchPage, calls };
}

const range = (n: number) => Array.from({ length: n }, (_, i) => i + 1);

describe('collectAllPages', () => {
  it('asks for the largest page the contract allows', async () => {
    const { fetchPage, calls } = fakeList(range(3));
    await collectAllPages(fetchPage);
    expect(PAGE_LIMIT).toBe(100);
    expect(calls).toEqual([{ limit: 100, offset: 0 }]);
  });

  it('returns an empty list from an empty first page', async () => {
    const { fetchPage, calls } = fakeList([]);
    expect(await collectAllPages(fetchPage)).toEqual([]);
    expect(calls).toHaveLength(1);
  });

  it('takes a short first page as the whole list', async () => {
    const { fetchPage, calls } = fakeList(range(4));
    expect(await collectAllPages(fetchPage)).toEqual([1, 2, 3, 4]);
    expect(calls).toHaveLength(1);
  });

  it('stops after one full page that completes the total', async () => {
    const { fetchPage, calls } = fakeList(range(100));
    expect(await collectAllPages(fetchPage)).toEqual(range(100));
    expect(calls).toHaveLength(1);
  });

  it('walks every page in order until the total is reached', async () => {
    const { fetchPage, calls } = fakeList(range(250));
    expect(await collectAllPages(fetchPage)).toEqual(range(250));
    expect(calls).toEqual([
      { limit: 100, offset: 0 },
      { limit: 100, offset: 100 },
      { limit: 100, offset: 200 },
    ]);
  });

  it('ends on an empty page even when total claims more', async () => {
    const { fetchPage, calls } = fakeList(range(100), 500);
    expect(await collectAllPages(fetchPage)).toEqual(range(100));
    expect(calls).toHaveLength(2);
  });
});
