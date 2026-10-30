import { base64UrlToBytes, bytesToBase64Url } from '@direct/shared';
import type { IncomingHandler, TransportAdapter } from '@direct/transport';

const CHANNEL = 'direct.relay.v1';
const STORAGE_KEY = 'direct.relay.storage.v1';
const FRESH_MS = 6000;

type Present = { t: 'present'; peerId: string; at: number };
type Forward = { t: 'forward'; to: string; payload: string };
type Frame = Present | Forward;
type Stored = { to: string; payload: string; exp: number };

export type RelayOptions = {
  enabled: boolean;
  storage: boolean;
  ttlMs: number;
};

/**
 * Browser binding of the relay policy used by WakuTransport.
 * Payloads are ciphertext. Storage is off unless explicitly enabled.
 * Acceptance is not recipient delivery.
 */
export class ChannelRelay implements TransportAdapter {
  readonly name = 'waku';
  private readonly channel: BroadcastChannel | null;
  private readonly present = new Map<string, number>();
  private handler: IncomingHandler | null = null;
  private selfId = '';
  private timer: ReturnType<typeof setInterval> | null = null;

  constructor(private readonly options: RelayOptions) {
    this.channel = typeof BroadcastChannel === 'undefined' ? null : new BroadcastChannel(CHANNEL);
    if (this.channel) this.channel.onmessage = (event: MessageEvent<Frame>) => this.onFrame(event.data);
  }

  configure(patch: Partial<RelayOptions>): void {
    if (patch.enabled !== undefined) this.options.enabled = patch.enabled;
    if (patch.storage !== undefined) this.options.storage = patch.storage;
    if (patch.ttlMs !== undefined) this.options.ttlMs = patch.ttlMs;
  }

  live(peerId: string): boolean {
    const at = this.present.get(peerId);
    return Boolean(this.options.enabled && at && Date.now() - at < FRESH_MS);
  }

  async connect(peerId: string): Promise<boolean> {
    if (!this.options.enabled) return false;
    if (this.live(peerId)) return true;
    return this.options.storage;
  }

  isConnected(peerId: string): boolean {
    return this.live(peerId);
  }

  async send(peerId: string, payload: Uint8Array): Promise<void> {
    if (!this.options.enabled) throw new Error('Relay is disabled.');
    if (this.live(peerId) && this.channel) {
      const frame: Forward = { t: 'forward', to: peerId, payload: bytesToBase64Url(payload) };
      this.channel.postMessage(frame);
      return;
    }
    if (!this.options.storage) throw new Error('Relay storage is off.');
    const items = readStored().filter((item) => item.exp > Date.now());
    items.push({ to: peerId, payload: bytesToBase64Url(payload), exp: Date.now() + this.options.ttlMs });
    writeStored(items.slice(-50));
  }

  async disconnect(): Promise<void> {
    if (this.timer) clearInterval(this.timer);
    this.timer = null;
  }

  subscribe(handler: IncomingHandler): () => void {
    this.handler = handler;
    return () => {
      if (this.handler === handler) this.handler = null;
    };
  }

  attach(selfId: string): void {
    this.selfId = selfId;
    this.announce();
    this.pull();
    if (this.timer) clearInterval(this.timer);
    this.timer = setInterval(() => {
      this.announce();
      this.pull();
    }, 2000);
  }

  private announce(): void {
    if (!this.options.enabled || !this.channel || !this.selfId) return;
    const frame: Present = { t: 'present', peerId: this.selfId, at: Date.now() };
    this.channel.postMessage(frame);
  }

  private pull(): void {
    if (!this.options.enabled || !this.options.storage || !this.selfId || !this.handler) return;
    const now = Date.now();
    const items = readStored();
    const keep: Stored[] = [];
    for (const item of items) {
      if (item.exp <= now) continue;
      if (item.to === this.selfId) {
        try {
          this.handler('relay', base64UrlToBytes(item.payload));
        } catch {
          keep.push(item);
        }
        continue;
      }
      keep.push(item);
    }
    writeStored(keep);
  }

  private onFrame(frame: Frame): void {
    if (!this.options.enabled || !frame) return;
    if (frame.t === 'present' && frame.peerId && frame.peerId !== this.selfId) {
      this.present.set(frame.peerId, frame.at || Date.now());
      return;
    }
    if (frame.t === 'forward' && frame.to === this.selfId && frame.payload && this.handler) {
      try {
        this.handler('relay', base64UrlToBytes(frame.payload));
      } catch {
        // Drop malformed ciphertext.
      }
    }
  }
}

function readStored(): Stored[] {
  if (typeof localStorage === 'undefined') return [];
  try {
    const parsed = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '[]') as Stored[];
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function writeStored(items: Stored[]): void {
  if (typeof localStorage === 'undefined') return;
  localStorage.setItem(STORAGE_KEY, JSON.stringify(items));
}
