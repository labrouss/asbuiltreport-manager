/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,jsx}'],
  theme: {
    extend: {
      fontFamily: {
        mono: ['"JetBrains Mono"', 'Fira Code', 'monospace'],
        sans: ['"Geist"', '"Inter"', 'system-ui', 'sans-serif'],
      },
      colors: {
        abr: {
          bg:      '#09090b',
          surface: '#111113',
          border:  '#1f1f23',
          muted:   '#2a2a30',
          accent:  '#3b82f6',
          success: '#22c55e',
          warn:    '#f59e0b',
          danger:  '#ef4444',
          text:    '#e4e4e7',
          sub:     '#71717a',
        }
      },
      animation: {
        'fade-in':    'fadeIn .25s ease',
        'slide-up':   'slideUp .3s ease',
        'pulse-dot':  'pulseDot 1.5s ease-in-out infinite',
        'scan':       'scan 2s linear infinite',
      },
      keyframes: {
        fadeIn:   { from: { opacity: 0 }, to: { opacity: 1 } },
        slideUp:  { from: { opacity: 0, transform: 'translateY(12px)' }, to: { opacity: 1, transform: 'translateY(0)' } },
        pulseDot: { '0%,100%': { opacity: 1 }, '50%': { opacity: 0.3 } },
        scan:     { from: { backgroundPosition: '0 0' }, to: { backgroundPosition: '0 100%' } },
      }
    }
  },
  plugins: []
}
