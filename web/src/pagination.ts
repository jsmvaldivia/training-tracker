// Loading the whole pursuit list (issue #24). The contract pages GET /pursuits
// (`limit` 1..100, default 50), while the UI loads everything once on start and
// filters in memory (AGENTS.md, architecture decisions). So the client walks
// the pages. Pure and fetcher-injected, like `hooks/pursuitState.ts`, so
// `bun test` covers it without a DOM.

export interface ListPage<T> {
  data: T[];
  total: number;
  limit: number;
  offset: number;
}

export type PageFetcher<T> = (params: { limit: number; offset: number }) => Promise<ListPage<T>>;

// The largest page the contract allows (api/openapi.yaml, GET /pursuits).
export const PAGE_LIMIT = 100;

// Fetch pages of PAGE_LIMIT from offset 0 until `total` is reached. An empty
// page also ends the walk, so a `total` larger than what the server hands out
// (the list shrank while it was being read) cannot loop forever.
export async function collectAllPages<T>(fetchPage: PageFetcher<T>): Promise<T[]> {
  const all: T[] = [];
  let offset = 0;
  for (;;) {
    const page = await fetchPage({ limit: PAGE_LIMIT, offset });
    all.push(...page.data);
    offset += page.data.length;
    if (page.data.length === 0 || offset >= page.total) return all;
  }
}
