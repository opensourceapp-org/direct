import { HOSTED_BOOTSTRAP_URL, applyHostedDefault } from '@direct/protocol';

export type ThemePreference = 'system' | 'light' | 'dark';

export type Preferences = {
  theme: ThemePreference;
  relayEnabled: boolean;
  relayStorage: boolean;
  backgroundDelivery: boolean;
  signalingUrl: string;
  bootstrapDefaultVersion: number;
};

export const defaultPreferences: Preferences = {
  theme: 'system',
  relayEnabled: false,
  relayStorage: false,
  backgroundDelivery: true,
  signalingUrl: HOSTED_BOOTSTRAP_URL,
  bootstrapDefaultVersion: 0,
};

const KEY = 'direct.preferences';

export function loadPreferences(): Preferences {
  if (typeof localStorage === 'undefined') return withHostedDefault({ ...defaultPreferences });
  try {
    const parsed = JSON.parse(localStorage.getItem(KEY) ?? '{}') as Partial<Preferences>;
    const loaded = {
      ...defaultPreferences,
      ...parsed,
      relayStorage: parsed.relayEnabled ? Boolean(parsed.relayStorage) : false,
    };
    const next = withHostedDefault(loaded);
    if (next.signalingUrl !== loaded.signalingUrl || next.bootstrapDefaultVersion !== loaded.bootstrapDefaultVersion) {
      savePreferences(next);
    }
    return next;
  } catch {
    return withHostedDefault({ ...defaultPreferences });
  }
}

function withHostedDefault(preferences: Preferences): Preferences {
  const chosen = applyHostedDefault(preferences.signalingUrl, preferences.bootstrapDefaultVersion);
  return { ...preferences, signalingUrl: chosen.url, bootstrapDefaultVersion: chosen.version };
}

export function savePreferences(preferences: Preferences): void {
  if (typeof localStorage === 'undefined') return;
  localStorage.setItem(KEY, JSON.stringify(preferences));
}
