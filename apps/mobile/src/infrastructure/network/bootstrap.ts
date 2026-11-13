import { HOSTED_BOOTSTRAP_URL, httpSignalUrl, usesHttpSignal } from '@direct/protocol';
import type { SignalingClient, SignalMessage } from '@direct/transport';

const OFFER_WAIT_MS = 500;
const LOOKUP_WAIT_MS = 4_000;

export function defaultBootstrapUrl(): string {
  return HOSTED_BOOTSTRAP_URL;
}

/** Empty uses the public hosted signaling server. */
export function resolveBootstrapUrl(override: string): string {
  const trimmed = override.trim();
  return trimmed || defaultBootstrapUrl();
}

/**
 * Shared rendezvous for phones that are not on the same network.
 * Announces a public bundle, looks up another DIRECT ID, and forwards
 * WebRTC session descriptions. It does not carry message text.
 */
type SignalSocket = { readyState: number; send(data: string): void; close(): void };

export class DirectBootstrap implements SignalingClient {
  private socket: SignalSocket | null = null;
  private timer: ReturnType<typeof setTimeout> | null = null;
  private readonly handlers = new Set<(message: SignalMessage) => void>();
  private readonly lookups = new Map<string, (bundle: string | null) => void>();
  private readonly offers = new Map<string, (missing: boolean) => void>();
  private selfId = '';
  private bundle = '';
  private nonce = '';
  private signProof: ((nonce: string) => string) | null = null;
  private discoverable = false;
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
    this.nonce = '';
    for (const resolve of this.lookups.values()) resolve(null);
    this.lookups.clear();
    for (const done of this.offers.values()) done(true);
    this.offers.clear();
  }

  reconnect(): void {
    this.socket?.close();
  }

  announce(bundle: string, signProof?: (nonce: string) => string, discoverable = false): void {
    this.bundle = bundle;
    this.discoverable = discoverable;
    if (signProof) this.signProof = signProof;
    this.hello();
  }

  lookup(directId: string): Promise<string | null> {
    if (!this.socket || this.socket.readyState !== 1) return Promise.resolve(null);
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
    if (!this.socket || this.socket.readyState !== 1) throw new Error('Bootstrap is not connected.');
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
    if (!url) {
      this.state = 'idle';
      this.schedule();
      return;
    }
    this.state = 'connecting';
    if (usesHttpSignal(url)) {
      const socket = new HttpSignalSocket(httpSignalUrl(url), {
        onOpen: () => {
          if (this.socket !== socket) return;
          this.state = 'open';
          this.hello();
        },
        onMessage: (text) => {
          if (this.socket !== socket) return;
          this.incoming(text);
        },
        onClose: () => {
          if (this.socket !== socket) return;
          this.socket = null;
          this.nonce = '';
          this.state = this.stopped ? 'idle' : 'connecting';
          for (const resolve of this.lookups.values()) resolve(null);
          this.lookups.clear();
          this.schedule();
        },
      });
      this.socket = socket;
      return;
    }
    if (typeof WebSocket === 'undefined') {
      this.state = 'idle';
      this.schedule();
      return;
    }
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
      this.nonce = '';
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
    if (!this.socket || this.socket.readyState !== 1 || !this.selfId || !this.bundle) return;
    const frame: Record<string, unknown> = { kind: 'hello', from: this.selfId, bundle: this.bundle };
    if (this.nonce && this.signProof) {
      frame.nonce = this.nonce;
      frame.proof = this.signProof(this.nonce);
    }
    if (this.discoverable) frame.discoverable = true;
    this.socket.send(JSON.stringify(frame));
  }

  private incoming(raw: string): void {
    let message: unknown;
    try {
      message = JSON.parse(raw);
    } catch {
      return;
    }
    if (!message || typeof message !== 'object') return;
    const record = message as { kind?: string; requestId?: string; present?: boolean; bundle?: string | null; to?: string; nonce?: string };
    if (record.kind === 'challenge' && typeof record.nonce === 'string') {
      this.nonce = record.nonce;
      this.hello();
      return;
    }
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

class HttpSignalSocket implements SignalSocket {
  readyState = 0;
  private session = '';
  private outgoing: string[] = [];
  private stopped = false;

  constructor(
    private readonly endpoint: string,
    private readonly events: { onOpen: () => void; onMessage: (text: string) => void; onClose: () => void },
  ) {
    void this.loop();
  }

  send(data: string): void {
    this.outgoing.push(data);
  }

  close(): void {
    this.stopped = true;
    this.readyState = 3;
  }

  private async loop(): Promise<void> {
    this.readyState = 1;
    this.events.onOpen();
    while (!this.stopped) {
      const frames = this.outgoing.splice(0);
      try {
        const response = await fetch(this.endpoint, {
          method: 'POST',
          headers: {
            'content-type': 'application/json',
            ...(this.session ? { 'x-direct-session': this.session } : {}),
          },
          body: JSON.stringify({
            session: this.session || undefined,
            waitMs: frames.length === 0 ? 2_000 : 0,
            frames: frames.map((frame) => JSON.parse(frame) as unknown),
          }),
        });
        if (!response.ok) throw new Error('The bootstrap closed the connection.');
        const body = await response.json() as { session?: string; frames?: unknown[] };
        if (typeof body.session === 'string') this.session = body.session;
        for (const frame of body.frames ?? []) this.events.onMessage(JSON.stringify(frame));
      } catch {
        this.readyState = 3;
        this.events.onClose();
        return;
      }
    }
    this.readyState = 3;
    this.events.onClose();
  }
}
