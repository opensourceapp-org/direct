export type ThemeName = 'light' | 'dark';

export type Theme = {
  name: ThemeName;
  background: string;
  foreground: string;
  surface: string;
  surfaceSecondary: string;
  border: string;
  muted: string;
  accent: string;
  success: string;
  warning: string;
  danger: string;
  inverse: string;
  inverseForeground: string;
  fontFamily: string;
};

export const lightTheme: Theme = {
  name: 'light',
  background: '#FFFFFF',
  foreground: '#171717',
  surface: '#FAFAFA',
  surfaceSecondary: '#F5F5F5',
  border: '#E5E5E5',
  muted: '#737373',
  accent: '#0070F3',
  success: '#16A34A',
  warning: '#D97706',
  danger: '#DC2626',
  inverse: '#171717',
  inverseForeground: '#FFFFFF',
  fontFamily: 'Geist Sans, Inter, ui-sans-serif, system-ui, sans-serif',
};

export const darkTheme: Theme = {
  name: 'dark',
  background: '#000000',
  foreground: '#EDEDED',
  surface: '#0A0A0A',
  surfaceSecondary: '#111111',
  border: '#262626',
  muted: '#A1A1AA',
  accent: '#3291FF',
  success: '#22C55E',
  warning: '#F59E0B',
  danger: '#EF4444',
  inverse: '#EDEDED',
  inverseForeground: '#000000',
  fontFamily: 'Geist Sans, Inter, ui-sans-serif, system-ui, sans-serif',
};

export function resolveTheme(preference: 'system' | 'light' | 'dark', systemDark: boolean): Theme {
  if (preference === 'light') return lightTheme;
  if (preference === 'dark') return darkTheme;
  return systemDark ? darkTheme : lightTheme;
}
