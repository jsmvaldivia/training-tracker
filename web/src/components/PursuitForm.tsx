import { useEffect, useState } from 'react';
import type { ChangeEvent, FormEvent } from 'react';
import { X } from 'lucide-react';
import type { Pursuit } from '../types';
import { formValuesFor } from '../pursuitForm';
import type { PursuitFormValues } from '../pursuitForm';

// Modal form for creating (issue #20) or editing (issue #23) a pursuit. The
// form only collects values; the owner maps them onto the API and performs the
// mutation. It closes on success and stays open on failure so the user can
// retry — the failure itself is reported through the toast by usePursuits.

interface PursuitFormProps {
  // Existing pursuit to edit; omit to create a new one.
  pursuit?: Pursuit;
  // Resolves true when the mutation succeeded.
  onSubmit: (values: PursuitFormValues) => Promise<boolean>;
  onClose: () => void;
}

const inputClass =
  'w-full rounded-md border border-slate-200 bg-white px-3 py-2 text-sm text-slate-900 focus:outline-none focus:ring-2 focus:ring-indigo-500';
const labelClass = 'text-xs font-medium text-slate-600';

export function PursuitForm({ pursuit, onSubmit, onClose }: PursuitFormProps) {
  const [values, setValues] = useState<PursuitFormValues>(() => formValuesFor(pursuit));
  const [saving, setSaving] = useState(false);
  const isEdit = pursuit !== undefined;
  const title = isEdit ? 'Edit pursuit' : 'New pursuit';

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      if (event.key === 'Escape') onClose();
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [onClose]);

  const field =
    (name: keyof PursuitFormValues) =>
    (event: ChangeEvent<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>) =>
      setValues((current) => ({ ...current, [name]: event.target.value }));

  const handleSubmit = async (event: FormEvent) => {
    event.preventDefault();
    setSaving(true);
    try {
      if (await onSubmit(values)) onClose();
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="fixed inset-0 z-[70] flex items-center justify-center p-4">
      <div className="absolute inset-0 bg-slate-900/40 backdrop-blur-sm" onClick={onClose} />
      <form
        role="dialog"
        aria-modal="true"
        aria-labelledby="pursuit-form-title"
        onSubmit={handleSubmit}
        className="relative w-full max-w-lg max-h-full overflow-y-auto rounded-xl bg-white shadow-2xl border border-slate-200 flex flex-col">

        <div className="flex items-center justify-between p-4 border-b border-slate-100">
          <h2 id="pursuit-form-title" className="text-lg font-semibold text-slate-900">
            {title}
          </h2>
          <button
            type="button"
            onClick={onClose}
            aria-label="Close"
            className="p-1.5 text-slate-400 hover:text-slate-600 hover:bg-slate-100 rounded-md transition-colors">
            <X className="w-5 h-5" />
          </button>
        </div>

        <div className="p-6 grid grid-cols-1 sm:grid-cols-2 gap-4">
          <div className="sm:col-span-2 flex flex-col gap-1">
            <label htmlFor="pursuit-name" className={labelClass}>Name</label>
            <input
              id="pursuit-name"
              type="text"
              required
              maxLength={200}
              autoFocus
              value={values.name}
              onChange={field('name')}
              className={inputClass} />
          </div>

          <div className="flex flex-col gap-1">
            <label htmlFor="pursuit-type" className={labelClass}>Type</label>
            <select id="pursuit-type" value={values.type} onChange={field('type')} className={inputClass}>
              <option value="training">Training</option>
              <option value="certification">Certification</option>
            </select>
          </div>

          <div className="flex flex-col gap-1">
            <label htmlFor="pursuit-expires" className={labelClass}>Expires</label>
            <input
              id="pursuit-expires"
              type="date"
              value={values.expires_at}
              onChange={field('expires_at')}
              className={inputClass} />
          </div>

          <div className="flex flex-col gap-1">
            <label htmlFor="pursuit-started" className={labelClass}>Started</label>
            <input
              id="pursuit-started"
              type="date"
              required
              value={values.started_at}
              onChange={field('started_at')}
              className={inputClass} />
          </div>

          <div className="flex flex-col gap-1">
            <label htmlFor="pursuit-target" className={labelClass}>Target date</label>
            <input
              id="pursuit-target"
              type="date"
              required
              value={values.target_date}
              onChange={field('target_date')}
              className={inputClass} />
          </div>

          <div className="sm:col-span-2 flex flex-col gap-1">
            <label htmlFor="pursuit-tags" className={labelClass}>Tags</label>
            <input
              id="pursuit-tags"
              type="text"
              placeholder="cloud, aws, architecture"
              value={values.tags}
              onChange={field('tags')}
              className={inputClass} />
          </div>

          <div className="sm:col-span-2 flex flex-col gap-1">
            <label htmlFor="pursuit-description" className={labelClass}>Notes</label>
            <textarea
              id="pursuit-description"
              rows={3}
              maxLength={2000}
              value={values.description}
              onChange={field('description')}
              className={inputClass} />
          </div>
        </div>

        <div className="flex items-center justify-end gap-2 p-4 border-t border-slate-100">
          <button
            type="button"
            onClick={onClose}
            className="h-9 px-4 text-sm font-medium text-slate-700 bg-white border border-slate-200 rounded-lg hover:bg-slate-50 transition-colors">
            Cancel
          </button>
          <button
            type="submit"
            disabled={saving}
            className="h-9 px-4 text-sm font-medium text-white bg-indigo-600 hover:bg-indigo-700 rounded-lg shadow-sm transition-colors disabled:opacity-60">
            {isEdit ? 'Save changes' : 'Create pursuit'}
          </button>
        </div>
      </form>
    </div>);

}
