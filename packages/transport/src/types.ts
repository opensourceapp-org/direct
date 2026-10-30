export type IncomingHandler = (peerId: string, payload: Uint8Array) => void;

/**
 * Common transport boundary. The UI and messaging services never talk to
 * WebRTC, libp2p, or Waku directly — they talk to this interface.
 */
export interface TransportAdapter {
  readonly name: string;
  connect(peerId: string): Promise<boolean>;
  send(peerId: string, payload: Uint8Array): Promise<void>;
  disconnect(peerId: string): Promise<void>;
  isConnected(peerId: string): boolean;
  subscribe(handler: IncomingHandler): () => void;
}

export type RouteResult =
  | { kind: 'direct'; transport: string }
  | { kind: 'relay'; transport: string }
  | { kind: 'queued' };
