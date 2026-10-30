import type { IncomingHandler, TransportAdapter } from './types';

type Stored = { payload: Uint8Array; expiresAt: number };

/**
 * Waku-shaped relay. Live subscribers receive ciphertext only.
 * Temporary storage is off unless `storage` is explicitly enabled.
 * Accepting a payload here is not recipient delivery.
 */
export class MemoryWakuNode {
  private readonly listeners = new Map<string, Set<IncomingHandler>>();
  private readonly stored = new Map<string, Stored[]>();

  join(topic: string, handler: IncomingHandler, now: number): () => void {
    const set = this.listeners.get(topic) ?? new Set();
    set.add(handler);
    this.listeners.set(topic, set);
    const waiting = this.stored.get(topic) ?? [];
    const remaining: Stored[] = [];
    for (const item of waiting) {
      if (item.expiresAt <= now) continue;
      handler(topic, item.payload);
    }
    this.stored.set(topic, remaining);
    return () => set.delete(handler);
  }

  publish(topic: string, payload: Uint8Array, options: { storage: boolean; expiresAt: number; now: number }): 'live' | 'stored' | 'dropped' {
    const listeners = this.listeners.get(topic);
    if (listeners && listeners.size > 0) {
      for (const listener of listeners) listener(topic, payload);
      return 'live';
    }
    if (!options.storage) return 'dropped';
    const bucket = this.stored.get(topic) ?? [];
    bucket.push({ payload, expiresAt: options.expiresAt });
    this.stored.set(topic, bucket.filter((item) => item.expiresAt > options.now));
    return 'stored';
  }

  storedCount(topic: string): number {
    return this.stored.get(topic)?.length ?? 0;
  }

  storedPayloads(topic: string): Uint8Array[] {
    return (this.stored.get(topic) ?? []).map((item) => item.payload);
  }

  hasListener(topic: string): boolean {
    return (this.listeners.get(topic)?.size ?? 0) > 0;
  }
}

export class WakuTransport implements TransportAdapter {
  readonly name = 'waku';
  private readonly joined = new Set<string>();
  private pull: (() => void) | null = null;

  constructor(
    private readonly selfId: string,
    private readonly node: MemoryWakuNode,
    private readonly options: { enabled: boolean; storage: boolean; ttlMs: number; now: () => number },
  ) {}

  async connect(peerId: string): Promise<boolean> {
    if (!this.options.enabled) return false;
    if (this.node.hasListener(this.topic(peerId))) return true;
    return this.options.storage;
  }

  isConnected(peerId: string): boolean {
    return this.options.enabled && this.node.hasListener(this.topic(peerId));
  }

  async send(peerId: string, payload: Uint8Array): Promise<void> {
    if (!this.options.enabled) throw new Error('Relay is disabled.');
    const now = this.options.now();
    const result = this.node.publish(this.topic(peerId), payload, {
      storage: this.options.storage,
      expiresAt: now + this.options.ttlMs,
      now,
    });
    if (result === 'dropped') throw new Error('Relay has no live recipient and storage is off.');
  }

  async disconnect(peerId: string): Promise<void> {
    this.joined.delete(peerId);
  }

  subscribe(handler: IncomingHandler): () => void {
    this.pull?.();
    this.pull = this.node.join(this.topic(this.selfId), (_topic, payload) => {
      handler('relay', payload);
    }, this.options.now());
    return () => this.pull?.();
  }

  private topic(peerId: string): string {
    return `direct/v1/${peerId}`;
  }
}
