// Bun dev/prod server for the Training Tracker frontend.
//
// Serves the bundled React app and proxies `/api/*` to the Zig backend, so the
// browser only ever makes same-origin requests (the backend sets no CORS
// headers). In dev, Bun bundles `index.html` + its imports with HMR.

import index from "./index.html";

const PORT = Number(process.env.PORT ?? 3000);
const BACKEND_URL = process.env.BACKEND_URL ?? "http://127.0.0.1:8080";

const server = Bun.serve({
  port: PORT,
  development: { hmr: true },
  routes: {
    "/": index,

    // Strip the `/api` prefix and forward to the backend.
    "/api/*": (req) => {
      const url = new URL(req.url);
      const target = BACKEND_URL + url.pathname.replace(/^\/api/, "") + url.search;
      return fetch(target, {
        method: req.method,
        headers: req.headers,
        body: req.method === "GET" || req.method === "HEAD" ? undefined : req.body,
      });
    },
  },
});

console.log(`web server on ${server.url} (proxying /api -> ${BACKEND_URL})`);
