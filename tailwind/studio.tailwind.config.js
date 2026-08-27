// Shared Tailwind config for all Studio apps
// Apps spread from this in their own tailwind.config.js

module.exports = {
  darkMode: 'class',
  theme: {
    fontFamily: {
      sans: ['Montserrat', 'system-ui', 'sans-serif'],
      mono: ['ui-monospace', 'SFMono-Regular', 'monospace'],
    },
    extend: {
      // Sub-xs type scale for dense UI (badges, meta rows, tick labels).
      // Bare sizes (no line-height tuple) so text-2xs / text-3xs are drop-in
      // replacements for the text-[11px] / text-[10px] arbitrary values that
      // dominate the consumer apps.
      fontSize: {
        '2xs': '0.6875rem', // 11px
        '3xs': '0.625rem',  // 10px
      },
      colors: {
        // Theme-aware semantic tokens (reference CSS variables)
        page:          'var(--color-page)',
        surface:       'var(--color-surface)',
        'surface-alt': 'var(--color-surface-alt)',
        inset:         'var(--color-inset)',

        // Dynamic primary palette (from theme role colors)
        primary: {
          DEFAULT: 'rgb(var(--color-primary-rgb) / <alpha-value>)',
          50:  'rgb(var(--color-primary-50-rgb) / <alpha-value>)',
          100: 'rgb(var(--color-primary-100-rgb) / <alpha-value>)',
          200: 'rgb(var(--color-primary-200-rgb) / <alpha-value>)',
          300: 'rgb(var(--color-primary-300-rgb) / <alpha-value>)',
          400: 'rgb(var(--color-primary-400-rgb) / <alpha-value>)',
          500: 'rgb(var(--color-primary-500-rgb) / <alpha-value>)',
          600: 'rgb(var(--color-primary-600-rgb) / <alpha-value>)',
          700: 'rgb(var(--color-primary-700-rgb) / <alpha-value>)',
          800: 'rgb(var(--color-primary-800-rgb) / <alpha-value>)',
          900: 'rgb(var(--color-primary-900-rgb) / <alpha-value>)',
        },

        mint: {
          DEFAULT: '#06D6A0',
          50: '#e6faf4',
          100: '#b3f0de',
          200: '#80e6c8',
          300: '#4ddcb2',
          400: '#1ad29c',
          500: '#06D6A0',
          600: '#05b888',
          700: '#049a70',
          800: '#037c58',
          900: '#025e40',
        },
        navy: {
          DEFAULT: '#1A1535',
          50: '#e8e7ed',
          100: '#b8b5c8',
          200: '#8883a3',
          300: '#58517e',
          400: '#3a3359',
          500: '#1A1535',
          600: '#16122e',
          700: '#120f27',
          800: '#0e0c20',
          900: '#0a0919',
        },
        violet: {
          DEFAULT: '#8E82FE',
          50: '#f0eeff',
          100: '#EAE8FF',
          200: '#b2aafe',
          300: '#C5C0FE',
          400: '#8E82FE',
          500: '#8E82FE',
          600: '#6558e5',
          700: '#6558E0',
          800: '#3b2cb3',
          900: '#3D2FB5',
        },
        mist: '#F7F6FF',
        lavender: '#E8E6F0',
        slate: '#6B6580',
        charcoal: '#2D2648',
        midnight: '#120F28',
        ember: '#FF8C69',
        gold: '#FFD166',
        magenta: '#F72585',
      },
      textColor: {
        heading:   'var(--color-text)',
        body:      'var(--color-text-body)',
        secondary: 'var(--color-text-secondary)',
        muted:     'var(--color-text-muted)',
        // The danger RED as TEXT. Separate from the `danger` brand fill on
        // purpose: a fill can be vivid, but text must clear WCAG AA 4.5:1 on
        // every surface, and no static red does that on BOTH themes. The token
        // is derived per theme by ThemeResolver#contrast_ink.
        'danger-ink': 'var(--color-danger-ink)',
      },
      borderColor: {
        subtle: 'var(--color-border)',
        strong: 'var(--color-border-strong)',
      },
    },
  },
}
