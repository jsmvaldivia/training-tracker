import { useEffect, useState } from "react";

type HealthState = "checking…" | "ok" | "unreachable" | string;

export function App() {
  const [health, setHealth] = useState<HealthState>("checking…");

  useEffect(() => {
    fetch("/api/health")
      .then((res) => res.json())
      .then((data: { status?: string }) => setHealth(data.status ?? "unknown"))
      .catch(() => setHealth("unreachable"));
  }, []);

  return (
    <main style={{ fontFamily: "system-ui, sans-serif", padding: "2rem" }}>
      <h1>Training Tracker</h1>
      <p>
        Backend health: <strong>{health}</strong>
      </p>
    </main>
  );
}
