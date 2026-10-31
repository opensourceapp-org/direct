import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { resolveTheme, type Theme } from './theme';
import { useAppStore } from '../stores/appStore';

const ThemeContext = createContext<Theme>(resolveTheme('system', false));

export function ThemeProvider({ children }: { children: ReactNode }) {
  const preference = useAppStore((state) => state.preferences.theme);
  const [systemDark, setSystemDark] = useState(() =>
    typeof matchMedia === 'undefined' ? false : matchMedia('(prefers-color-scheme: dark)').matches,
  );

  useEffect(() => {
    if (typeof matchMedia === 'undefined') return undefined;
    const media = matchMedia('(prefers-color-scheme: dark)');
    const apply = () => setSystemDark(media.matches);
    apply();
    media.addEventListener('change', apply);
    return () => media.removeEventListener('change', apply);
  }, []);

  const theme = useMemo(() => resolveTheme(preference, systemDark), [preference, systemDark]);

  useEffect(() => {
    if (typeof document === 'undefined') return;
    const root = document.documentElement;
    root.dataset.theme = theme.name;
    root.style.background = theme.background;
    root.style.color = theme.foreground;
    const tokens: Record<string, string> = {
      '--background': theme.background,
      '--foreground': theme.foreground,
      '--surface': theme.surface,
      '--surface-secondary': theme.surfaceSecondary,
      '--border': theme.border,
      '--muted': theme.muted,
      '--accent': theme.accent,
      '--success': theme.success,
      '--warning': theme.warning,
      '--danger': theme.danger,
    };
    for (const [key, value] of Object.entries(tokens)) root.style.setProperty(key, value);
  }, [theme]);

  return <ThemeContext.Provider value={theme}>{children}</ThemeContext.Provider>;
}

export function useTheme(): Theme {
  return useContext(ThemeContext);
}
