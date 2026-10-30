import { base64UrlToBytes, bytesToBase64Url } from '@direct/shared';
import type { Mesh } from '@direct/transport';

const CHANNEL = 'direct.mesh.v1';
const FRESH_MS = 6000;

type Hello = { t: 'hello'; peerId: string; bundle: string; at: number };
type Deliver = { t: 'deliver'; from: string; to: string; payload: string };
type Frame = Hello | Deliver;

export class BrowserMesh implements Mesh {
  private readonly channel: BroadcastChannel | null;
  private selfId = '';
  private bundle = '';
  private handler: ((fromPeerId: string, payload: Uint8Array) => void) | null = null;
  private readonly peers = new Map<string, number>();
  private timer: ReturnType<typeof setInterval> | null = null;

  constructor(private readonly onBundle: (bundle: string) => void) {
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

  async deliver(fromPeerId: string, toPeerId: string, payload: Uint8Array): Promise<boolean> {
    if (!this.channel || !this.online(toPeerId)) return false;
    const frame: Deliver = { t: 'deliver', from: fromPeerId, to: toPeerId, payload: bytesToBase64Url(payload) };
    this.channel.postMessage(frame);
    return true;
  }

  private hello(): void {
    if (!this.channel || !this.selfId || !this.bundle) return;
    const frame: Hello = { t: 'hello', peerId: this.selfId, bundle: this.bundle, at: Date.now() };
    this.channel.postMessage(frame);
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
