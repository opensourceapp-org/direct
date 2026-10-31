import { base64UrlToBytes, bytesToBase64Url } from '@direct/shared';
import type { Mesh } from '@direct/transport';

const CHANNEL = 'direct.mesh.v1';
const MESH_URL = '/api/direct/mesh';
const FRESH_MS = 12_000;

type Hello = { t: 'hello'; peerId: string; bundle: string; at: number };
type Deliver = { t: 'deliver'; from: string; to: string; payload: string };
type Frame = Hello | Deliver;

export type MeshLoopback = {
  hello(peerId: string, bundle: string): Promise<boolean>;
  deliver(from: string, to: string, payload: string): Promise<boolean>;
  pull(peerId: string): Promise<{ peers: { peerId: string; bundle: string; at: number }[]; mail: { from: string; payload: string }[] }>;
};

export function httpLoopback(): MeshLoopback | null {
  if (typeof fetch !== 'function') return null;
  return {
    async hello(peerId, bundle) {
      const response = await fetch(MESH_URL, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ op: 'hello', peerId, bundle }),
      });
      return response.ok;
    },
    async deliver(from, to, payload) {
      const response = await fetch(MESH_URL, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ op: 'deliver', from, to, payload }),
      });
      return response.ok;
    },
    async pull(peerId) {
      const response = await fetch(`${MESH_URL}?peer=${encodeURIComponent(peerId)}`);
      if (!response.ok) return { peers: [], mail: [] };
      return response.json() as Promise<{ peers: { peerId: string; bundle: string; at: number }[]; mail: { from: string; payload: string }[] }>;
    },
  };
}

/**
 * Same-profile tabs use BroadcastChannel. A normal window and a private window do not share that
 * channel, so the preview server on this same address keeps a short-lived public presence board.
 */
export class BrowserMesh implements Mesh {
  private readonly channel: BroadcastChannel | null;
  private selfId = '';
  private bundle = '';
  private handler: ((fromPeerId: string, payload: Uint8Array) => void) | null = null;
  private readonly peers = new Map<string, number>();
  private timer: ReturnType<typeof setInterval> | null = null;
  private pulling: Promise<void> | null = null;

  constructor(
    private readonly onBundle: (bundle: string) => void,
    private readonly loopback: MeshLoopback | null = httpLoopback(),
  ) {
    this.channel = typeof BroadcastChannel === 'undefined' ? null : new BroadcastChannel(CHANNEL);
    if (this.channel) this.channel.onmessage = (event: MessageEvent<Frame>) => this.onMessage(event.data);
  }

  publishBundle(bundle: string): void {
    this.bundle = bundle;
    this.hello();
  }

  knownPeers(): string[] {
    const now = Date.now();
    return [...this.peers.entries()].filter(([, at]) => now - at < FRESH_MS).map(([peerId]) => peerId);
  }

  register(peerId: string, deliver: (fromPeerId: string, payload: Uint8Array) => void): () => void {
    this.selfId = peerId;
    this.handler = deliver;
    this.hello();
    this.timer = setInterval(() => this.hello(), 2000);
    return () => {
      if (this.timer) clearInterval(this.timer);
      this.timer = null;
      this.handler = null;
    };
  }

  online(peerId: string): boolean {
    const at = this.peers.get(peerId);
    return Boolean(at && Date.now() - at < FRESH_MS);
  }

  async sync(): Promise<void> {
    await this.pull();
  }

  async deliver(fromPeerId: string, toPeerId: string, payload: Uint8Array): Promise<boolean> {
    if (!this.online(toPeerId)) return false;
    const encoded = bytesToBase64Url(payload);
    let sent = false;
    if (this.channel) {
      const frame: Deliver = { t: 'deliver', from: fromPeerId, to: toPeerId, payload: encoded };
      this.channel.postMessage(frame);
      sent = true;
    }
    if (this.loopback) {
      try {
        sent = (await this.loopback.deliver(fromPeerId, toPeerId, encoded)) || sent;
      } catch {
        // The preview server is optional. Same-profile delivery can still use the channel.
      }
    }
    return sent;
  }

  private hello(): void {
    if (!this.selfId || !this.bundle) return;
    if (this.channel) {
      const frame: Hello = { t: 'hello', peerId: this.selfId, bundle: this.bundle, at: Date.now() };
      this.channel.postMessage(frame);
    }
    if (this.loopback) {
      void this.loopback.hello(this.selfId, this.bundle).catch(() => undefined);
      void this.pull();
    }
  }

  private pull(): Promise<void> {
    if (!this.loopback || !this.selfId) return Promise.resolve();
    if (this.pulling) return this.pulling;
    this.pulling = this.loopback.pull(this.selfId).then((page) => {
      for (const peer of page.peers) {
        if (!peer.peerId || peer.peerId === this.selfId || !peer.bundle) continue;
        this.peers.set(peer.peerId, peer.at || Date.now());
        this.onBundle(peer.bundle);
      }
      for (const item of page.mail) {
        if (!item.from || !item.payload) continue;
        try {
          this.handler?.(item.from, base64UrlToBytes(item.payload));
        } catch {
          // Ignore malformed frames. They are not messages.
        }
      }
    }).catch(() => undefined).finally(() => {
      this.pulling = null;
    });
    return this.pulling;
  }

  private onMessage(frame: Frame): void {
    if (!frame || typeof frame !== 'object') return;
    if (frame.t === 'hello' && frame.peerId && frame.peerId !== this.selfId && frame.bundle) {
      const first = !this.peers.has(frame.peerId);
      this.peers.set(frame.peerId, frame.at || Date.now());
      this.onBundle(frame.bundle);
      if (first) this.hello();
      return;
    }
    if (frame.t === 'deliver' && frame.to === this.selfId && frame.from && frame.payload) {
      try {
        this.handler?.(frame.from, base64UrlToBytes(frame.payload));
      } catch {
        // Ignore malformed frames. They are not messages.
      }
    }
  }
}
