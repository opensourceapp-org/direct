import type { IncomingHandler, TransportAdapter } from './types';

type Delivery = (fromPeerId: string, payload: Uint8Array) => void;

export interface Mesh {
  register(peerId: string, deliver: Delivery): () => void;
  online(peerId: string): boolean;
  deliver(fromPeerId: string, toPeerId: string, payload: Uint8Array): Promise<boolean>;
}

export class MemoryMesh implements Mesh {
  private readonly peers = new Map<string, Delivery>();

  register(peerId: string, deliver: Delivery): () => void {
    this.peers.set(peerId, deliver);
    return () => {
      if (this.peers.get(peerId) === deliver) this.peers.delete(peerId);
    };
  }

  online(peerId: string): boolean {
    return this.peers.has(peerId);
  }

  async deliver(fromPeerId: string, toPeerId: string, payload: Uint8Array): Promise<boolean> {
    const target = this.peers.get(toPeerId);
    if (!target) return false;
    await Promise.resolve();
    target(fromPeerId, payload);
    return true;
  }
}

export class LocalTransport implements TransportAdapter {
  readonly name = 'local';
  private readonly handlers = new Set<IncomingHandler>();
  private connected = false;
  private unregister: (() => void) | null = null;

  constructor(
    private readonly selfId: string,
    private readonly mesh: Mesh,
  ) {}

  async connect(peerId: string): Promise<boolean> {
    this.ensureRegistered();
    if (peerId === this.selfId) return false;
    this.connected = this.mesh.online(peerId);
    return this.connected;
  }

  isConnected(peerId: string): boolean {
    return peerId !== this.selfId && this.mesh.online(peerId);
  }

  async send(peerId: string, payload: Uint8Array): Promise<void> {
    if (!this.isConnected(peerId)) throw new Error('Peer is not on the local mesh.');
    const delivered = await this.mesh.deliver(this.selfId, peerId, payload);
    if (!delivered) throw new Error('Peer left the local mesh.');
  }

  async disconnect(_peerId?: string): Promise<void> {
    this.connected = false;
    this.unregister?.();
    this.unregister = null;
  }

  subscribe(handler: IncomingHandler): () => void {
    this.handlers.add(handler);
    this.ensureRegistered();
    return () => this.handlers.delete(handler);
  }

  private ensureRegistered(): void {
    if (this.unregister) return;
    this.unregister = this.mesh.register(this.selfId, (from, payload) => {
      for (const handler of this.handlers) handler(from, payload);
    });
  }
}
