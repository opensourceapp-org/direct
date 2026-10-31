export type KadPeer = {
  id: Uint8Array;
  peerId: string;
  addrs: string[];
  lastSeen: number;
};

const BITS = 256;

export function xorDistance(left: Uint8Array, right: Uint8Array): Uint8Array {
  const length = Math.max(left.length, right.length);
  const out = new Uint8Array(length);
  for (let i = 0; i < length; i += 1) {
    out[i] = (left[left.length - length + i] ?? 0) ^ (right[right.length - length + i] ?? 0);
  }
  return out;
}

export function compareDistance(left: Uint8Array, right: Uint8Array): number {
  const size = Math.max(left.length, right.length);
  for (let i = 0; i < size; i += 1) {
    const a = left[left.length - size + i] ?? 0;
    const b = right[right.length - size + i] ?? 0;
    if (a !== b) return a - b;
  }
  return 0;
}

export function bucketIndex(localId: Uint8Array, remoteId: Uint8Array): number {
  const distance = xorDistance(localId, remoteId);
  for (let i = 0; i < distance.length; i += 1) {
    const byte = distance[i] ?? 0;
    if (byte === 0) continue;
    return (distance.length - 1 - i) * 8 + Math.floor(Math.log2(byte));
  }
  return 0;
}

/**
 * Kademlia k-bucket routing table using XOR distance.
 * This is DIRECT's discovery table. It is not the libp2p kad-dht wire protocol.
 * A native libp2p node can replace the dialer behind Libp2pTransport.
 */
export class KademliaTable {
  private readonly buckets: KadPeer[][];

  constructor(
    readonly localId: Uint8Array,
    readonly k = 20,
  ) {
    if (localId.length !== 32) throw new Error('Kademlia ids are 32 bytes.');
    this.buckets = Array.from({ length: BITS }, () => []);
  }

  add(peer: KadPeer): void {
    if (equalId(peer.id, this.localId)) return;
    const index = bucketIndex(this.localId, peer.id);
    const bucket = this.buckets[index] ?? [];
    const existing = bucket.findIndex((item) => equalId(item.id, peer.id));
    if (existing >= 0) {
      bucket.splice(existing, 1);
      bucket.push({ ...peer, addrs: [...peer.addrs] });
      return;
    }
    if (bucket.length >= this.k) {
      bucket.shift();
    }
    bucket.push({ ...peer, addrs: [...peer.addrs] });
  }

  get size(): number {
    return this.buckets.reduce((sum, bucket) => sum + bucket.length, 0);
  }

  closest(target: Uint8Array, limit: number): KadPeer[] {
    const peers = this.buckets.flat();
    return peers
      .sort((left, right) => compareDistance(xorDistance(left.id, target), xorDistance(right.id, target)))
      .slice(0, limit);
  }

  findByPeerId(peerId: string): KadPeer | null {
    for (const bucket of this.buckets) {
      const found = bucket.find((peer) => peer.peerId === peerId);
      if (found) return found;
    }
    return null;
  }
}

function equalId(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  for (let i = 0; i < left.length; i += 1) if (left[i] !== right[i]) return false;
  return true;
}
