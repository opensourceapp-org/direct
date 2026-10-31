import { create } from 'zustand';
import type { ConversationRecord, ContactRecord } from '../infrastructure/persistence/repositories';
import type { MessageRow } from '@direct/protocol';
import type { Preferences, ThemePreference } from '../infrastructure/preferences';
import { defaultPreferences, loadPreferences } from '../infrastructure/preferences';

export type IdentityView = {
  directId: string;
  did: string;
  deviceId: string;
  displayName: string;
  fingerprint: string;
  bundle: string;
};

export type Attempt = { ok: boolean; transport: string; at: number };

export type NetworkView = {
  online: boolean;
  directAvailable: boolean;
  activeTransport: string;
  discovery: string;
  bootstrap: string;
  peers: number;
  relay: string;
  lastSuccess: number | null;
  networkType: string;
  attempts: Attempt[];
  kadPeers: number;
  libp2p: string;
};

type AppState = {
  booting: boolean;
  bootError: string | null;
  identity: IdentityView | null;
  conversations: ConversationRecord[];
  contacts: ContactRecord[];
  messages: Record<string, MessageRow[]>;
  openedDirectId: string | null;
  peerTransport: Record<string, 'direct' | 'relay' | 'offline' | 'connecting' | 'present'>;
  preferences: Preferences;
  network: NetworkView;
  setBooting: (booting: boolean, bootError?: string | null) => void;
  setSnapshot: (snapshot: Partial<AppState>) => void;
};

const emptyNetwork: NetworkView = {
  online: true,
  directAvailable: true,
  activeTransport: 'Local mesh',
  discovery: 'Listening',
  bootstrap: 'Not started',
  peers: 0,
  relay: 'Off',
  lastSuccess: null,
  networkType: 'Unknown',
  attempts: [],
  kadPeers: 0,
  libp2p: 'Dialer not bundled on this runtime',
};

export const useAppStore = create<AppState>((set) => ({
  booting: true,
  bootError: null,
  identity: null,
  conversations: [],
  contacts: [],
  messages: {},
  openedDirectId: null,
  peerTransport: {},
  preferences: loadPreferences(),
  network: emptyNetwork,
  setBooting: (booting, bootError = null) => set({ booting, bootError }),
  setSnapshot: (snapshot) => set(snapshot),
}));

export type { ThemePreference };
