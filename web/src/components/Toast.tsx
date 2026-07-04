import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useRef,
  useState } from
'react';
import type { ReactNode } from 'react';
import { X } from 'lucide-react';

// Minimal in-house toast (issue #4) — no npm dependency. `usePursuits` reports
// rollback failures through the `onError` callback, which App wires to
// `useToast().error`. Toasts auto-dismiss and live in an aria-live region so the
// failure is announced to assistive tech (and assertable in E2E).

interface ToastItem {
  id: number;
  message: string;
}

interface ToastApi {
  error: (message: string) => void;
}

const ToastContext = createContext<ToastApi | null>(null);

const TOAST_TTL_MS = 5000;

export function useToast(): ToastApi {
  const ctx = useContext(ToastContext);
  if (!ctx) {
    throw new Error('useToast must be used within a ToastProvider');
  }
  return ctx;
}

export function ToastProvider({ children }: {children: ReactNode;}) {
  const [toasts, setToasts] = useState<ToastItem[]>([]);
  const nextId = useRef(0);

  const dismiss = useCallback((id: number) => {
    setToasts((prev) => prev.filter((t) => t.id !== id));
  }, []);

  const error = useCallback(
    (message: string) => {
      const id = nextId.current++;
      setToasts((prev) => [...prev, { id, message }]);
      setTimeout(() => dismiss(id), TOAST_TTL_MS);
    },
    [dismiss]
  );

  const apiValue = useMemo<ToastApi>(() => ({ error }), [error]);

  return (
    <ToastContext.Provider value={apiValue}>
      {children}
      <div
        className="fixed bottom-4 right-4 z-[60] flex flex-col gap-2"
        role="status"
        aria-live="polite">

        {toasts.map((toast) =>
        <div
          key={toast.id}
          className="flex items-start gap-3 max-w-sm rounded-lg border border-rose-200 bg-white px-4 py-3 text-sm text-rose-700 shadow-lg">

            <span className="flex-1 leading-snug">{toast.message}</span>
            <button
            onClick={() => dismiss(toast.id)}
            className="flex-shrink-0 text-rose-400 hover:text-rose-600"
            aria-label="Dismiss notification">

              <X className="w-4 h-4" />
            </button>
          </div>
        )}
      </div>
    </ToastContext.Provider>);

}
