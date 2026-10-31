import type { IncomingHandler, TransportAdapter } from './types';
import type { KademliaTable } from './kademlia';

export type Libp2pDialer = {
  findPeer(peerId: string): Promise<{ peerId: string; addrs: string[] } | null>;
  dial(peerId: string): Promise<boolean>;
  hangup(peerId: string): Promise<void>;
  send(peerId: string, payload: Uint8Array): Promise<void>;
  listen(handler: IncomingHandler): () => void;
};

/**
 * libp2p adapter. js-libp2p is not bundled: Hermes does not provide the Node
 * APIs that current kad-dht transports assume. Inject a dialer that wraps a
 * checked libp2p node, or use InProcessLibp2p for tests and same-process nodes.
 */
export class Libp2pTransport implements TransportAdapter {
  readonly name = 'libp2p';
  private readonly connected = new Set<string>();
  private unsubscribe: (() => void) | null = null;

  constructor(private readonly dialer: Libp2pDialer) {}

  async connect(peerId: string): Promise<boolean> {
    const found = await this.dialer.findPeer(peerId);
    if (!found) return false;
    const ok = await this.dialer.dial(peerId);
    if (ok) this.connected.add(peerId);
    return ok;
  }

  isConnected(peerId: string): boolean {
    return this.connected.has(peerId);
  }

  async send(peerId: string, payload: Uint8Array): Promise<void> {
    if (!this.connected.has(peerId)) throw new Error('libp2p peer is not dialed.');
    await this.dialer.send(peerId, payload);
  }

  async disconnect(peerId: string): Promise<void> {
    this.connected.delete(peerId);
    await this.dialer.hangup(peerId);
  }

  subscribe(handler: IncomingHandler): () => void {
    this.unsubscribe?.();
    this.unsubscribe = this.dialer.listen(handler);
    return () => this.unsubscribe?.();
  }
}

type NodeState = {
  id: Uint8Array;
  peerId: string;
  handler: IncomingHandler | null;
  online: boolean;
};

export class InProcessLibp2p {
  private readonly nodes = new Map<string, NodeState>();

  register(table: KademliaTable, peerId: string): Libp2pTransport {
    this.nodes.set(peerId, { id: table.localId, peerId, handler: null, online: true });
    const dialer: Libp2pDialer = {
      findPeer: async (target) => {
        const record = table.findByPeerId(target);
        const node = this.nodes.get(target);
        if (!record || !node?.online) return null;
        return { peerId: target, addrs: record.addrs };
      },
      dial: async (target) => Boolean(this.nodes.get(target)?.online),
      hangup: async () => undefined,
      send: async (target, payload) => {
        const node = this.nodes.get(target);
        if (!node?.online || !node.handler) throw new Error('libp2p stream is closed.');
        node.handler(peerId, payload);
      },
      listen: (handler) => {
        const node = this.nodes.get(peerId);
        if (node) node.handler = handler;
        return () => {
          if (node) node.handler = null;
        };
      },
    };
    return new Libp2pTransport(dialer);
  }

  announce(table: KademliaTable, peerId: string, addrs: string[], now: number): void {
    const node = this.nodes.get(peerId);
    if (!node) return;
    table.add({ id: node.id, peerId, addrs, lastSeen: now });
  }
}
