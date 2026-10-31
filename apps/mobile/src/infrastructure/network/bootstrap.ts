import type { SignalingClient, SignalMessage } from '@direct/transport';

const OFFER_WAIT_MS = 500;
const LOOKUP_WAIT_MS = 4_000;

export function defaultBootstrapUrl(): string {
  if (typeof location === 'undefined' || !location.host) return '';
  const scheme = location.protocol === 'https:' ? 'wss:' : 'ws:';
  return `${scheme}//${location.host}/api/direct/signal`;
}

/** Empty means the DIRECT address this phone already opened. */
export function resolveBootstrapUrl(override: string): string {
  const trimmed = override.trim();
  return trimmed || defaultBootstrapUrl();
}

/**
 * Shared rendezvous for phones that are not on the same network.
 * Announces a public bundle, looks up another DIRECT ID, and forwards
 * WebRTC session descriptions. It does not carry message text.
 */
export class DirectBootstrap implements SignalingClient {
  private socket: WebSocket | null = null;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private readonly handlers = new Set<(message: SignalMessage) => void>();
  private readonly lookups = new Map<string, (bundle: string | null) => void>();
  private readonly offers = new Map<string, (missing: boolean) => void>();
  private selfId = '';
  private bundle = '';
  private stopped = true;
  state: 'idle' | 'connecting' | 'open' = 'idle';
  currentUrl = '';

  constructor(private readonly urlFor: () => string) {}

  start(directId: string): void {
    this.selfId = directId;
    this.stopped = false;
    this.open();
  }

  stop(): void {
    this.stopped = true;
    this.state = 'idle';
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.socket?.close();
    this.socket = null;
    for (const resolve of this.lookups.values()) resolve(null);
    this.lookups.clear();
    for (const done of this.offers.values()) done(true);
    this.offers.clear();
  }

  reconnect(): void {
    this.socket?.close();
  }

  announce(bundle: string): void {
    this.bundle = bundle;
    this.hello();
  }

  lookup(directId: string): Promise<string | null> {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) return Promise.resolve(null);
    const requestId = globalThis.crypto.randomUUID();
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.lookups.delete(requestId);
        resolve(null);
      }, LOOKUP_WAIT_MS);
      this.lookups.set(requestId, (found) => {
        clearTimeout(timer);
        resolve(found);
      });
      this.socket?.send(JSON.stringify({ kind: 'lookup', directId, requestId }));
    });
  }

  async send(message: SignalMessage): Promise<void> {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN) throw new Error('Bootstrap is not connected.');
    this.socket.send(JSON.stringify(message));
    if (message.kind !== 'offer') return;
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.offers.delete(message.to);
        resolve();
      }, OFFER_WAIT_MS);
      this.offers.set(message.to, (missing) => {
        clearTimeout(timer);
        this.offers.delete(message.to);
        if (missing) reject(new Error('That device is not on this bootstrap.'));
        else resolve();
      });
    });
  }

  onMessage(handler: (message: SignalMessage) => void): () => void {
    this.handlers.add(handler);
    return () => {
      this.handlers.delete(handler);
    };
  }

  private open(): void {
    if (this.stopped) return;
    const url = this.urlFor();
    this.currentUrl = url;
    if (!url || typeof WebSocket === 'undefined') {
      this.state = 'idle';
      this.schedule();
      return;
    }
    this.state = 'connecting';
    let socket: WebSocket;
    try {
      socket = new WebSocket(url);
    } catch {
      this.schedule();
      return;
    }
    this.socket = socket;
    socket.addEventListener('open', () => {
      if (this.socket !== socket) return;
      this.state = 'open';
      this.hello();
    });
    socket.addEventListener('message', (event) => {
      if (this.socket !== socket || typeof event.data !== 'string') return;
      this.incoming(event.data);
    });
    socket.addEventListener('close', () => {
      if (this.socket !== socket) return;
      this.socket = null;
      this.state = this.stopped ? 'idle' : 'connecting';
      for (const resolve of this.lookups.values()) resolve(null);
      this.lookups.clear();
      this.schedule();
    });
  }

  private schedule(): void {
    if (this.stopped || this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      this.open();
    }, 2_000);
    const timer = this.timer as { unref?: () => void };
    timer.unref?.();
  }

  private hello(): void {
    if (!this.socket || this.socket.readyState !== WebSocket.OPEN || !this.selfId || !this.bundle) return;
    this.socket.send(JSON.stringify({ kind: 'hello', from: this.selfId, bundle: this.bundle }));
  }

  private incoming(raw: string): void {
    let message: unknown;
    try {
      message = JSON.parse(raw);
    } catch {
      return;
    }
    if (!message || typeof message !== 'object') return;
    const record = message as { kind?: string; requestId?: string; present?: boolean; bundle?: string | null; to?: string };
    if (record.kind === 'lookup' && record.requestId) {
      const done = this.lookups.get(record.requestId);
      this.lookups.delete(record.requestId);
      done?.(record.present && typeof record.bundle === 'string' ? record.bundle : null);
      return;
    }
    if (record.kind === 'unreachable' && record.to) {
      this.offers.get(record.to)?.(true);
      return;
    }
    if (record.kind === 'offer' || record.kind === 'answer' || record.kind === 'ice') {
      for (const handler of this.handlers) handler(record as SignalMessage);
    }
  }
}
