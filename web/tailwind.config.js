/** @type {import('tailwindcss').Config} */
export default {
  content: [
    "./index.html",
    "./src/**/*.{js,ts,jsx,tsx}",
  ],
  theme: {
    extend: {
      fontFamily: {
        sans: ['Inter', 'sans-serif'],
      },
      colors: {
        slate: {
          50: '#f8fafc',
          100: '#f1f5f9',
          200: '#e2e8f0',
          300: '#cbd5e1',
          400: '#94a3b8',
          500: '#64748b',
          600: '#475569',
          700: '#334155',
          800: '#1e293b',
          900: '#0f172a',
        },
        indigo: {
          50: '#eef2ff',
          100: '#e0e7ff',
          500: '#6366f1',
          600: '#4f46e5',
        },
        emerald: {
          50: '#ecfdf5',
          100: '#d1fae5',
          500: '#10b981',
        },
        amber: {
          50: '#fffbeb',
          100: '#fef3c7',
          500: '#f59e0b',
        },
        red: {
          50: '#fef2f2',
          100: '#fee2e2',
          500: '#ef4444',
        }
      }
    },
  },
  plugins: [],
}
