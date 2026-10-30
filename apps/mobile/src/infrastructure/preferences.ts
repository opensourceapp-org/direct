export type ThemePreference = 'system' | 'light' | 'dark';

export type Preferences = {
  theme: ThemePreference;
  relayEnabled: boolean;
  relayStorage: boolean;
  backgroundDelivery: boolean;
  signalingUrl: string;
};

export const defaultPreferences: Preferences = {
  theme: 'system',
  relayEnabled: false,
  relayStorage: false,
  backgroundDelivery: true,
  signalingUrl: '',
};

const KEY = 'direct.preferences';

export function loadPreferences(): Preferences {
  if (typeof localStorage === 'undefined') return { ...defaultPreferences };
  try {
    const parsed = JSON.parse(localStorage.getItem(KEY) ?? '{}') as Partial<Preferences>;
    return { ...defaultPreferences, ...parsed, relayStorage: parsed.relayEnabled ? Boolean(parsed.relayStorage) : false };
  } catch {
    return { ...defaultPreferences };
  }
}

export function savePreferences(preferences: Preferences): void {
  if (typeof localStorage === 'undefined') return;
  localStorage.setItem(KEY, JSON.stringify(preferences));
}
