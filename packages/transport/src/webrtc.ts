import type { IncomingHandler, TransportAdapter } from './types';

export type SessionDescription = { type: 'offer' | 'answer'; sdp: string };
export type IceCandidate = { candidate: string; sdpMid?: string | null };

export type SignalMessage = {
  to: string;
  from: string;
  kind: 'offer' | 'answer' | 'ice';
  description?: SessionDescription;
  candidate?: IceCandidate;
};

export interface SignalingClient {
  send(message: SignalMessage): Promise<void>;
  onMessage(handler: (message: SignalMessage) => void): () => void;
}

export interface DataChannelLike {
  readyState: 'connecting' | 'open' | 'closing' | 'closed';
  send(data: Uint8Array): void;
  close(): void;
  onopen: (() => void) | null;
  onmessage: ((event: { data: Uint8Array }) => void) | null;
}

export interface PeerConnectionLike {
  createDataChannel(label: string): DataChannelLike;
  createOffer(): Promise<SessionDescription>;
  createAnswer(): Promise<SessionDescription>;
  setLocalDescription(description: SessionDescription): Promise<void>;
  setRemoteDescription(description: SessionDescription): Promise<void>;
  addIceCandidate(candidate: IceCandidate): Promise<void>;
  close(): void;
  onicecandidate: ((event: { candidate: IceCandidate | null }) => void) | null;
  ondatachannel: ((event: { channel: DataChannelLike }) => void) | null;
}

export type PeerConnectionFactory = () => PeerConnectionLike;

const MAX_SIGNAL_BYTES = 64 * 1024;

export function assertSignalMessage(message: SignalMessage): void {
  const size = JSON.stringify(message).length;
  if (size > MAX_SIGNAL_BYTES) throw new Error('Signaling payload is too large.');
  if (message.kind !== 'offer' && message.kind !== 'answer' && message.kind !== 'ice') {
    throw new Error('Signaling channel rejected a non-session message.');
  }
}

class VirtualDataChannel implements DataChannelLike {
  readyState: DataChannelLike['readyState'] = 'connecting';
  onopen: (() => void) | null = null;
  onmessage: ((event: { data: Uint8Array }) => void) | null = null;
  peer: VirtualDataChannel | null = null;

  send(data: Uint8Array): void {
    if (this.readyState !== 'open' || !this.peer) throw new Error('Data channel is not open.');
    this.peer.onmessage?.({ data: new Uint8Array(data) });
  }

  close(): void {
    this.readyState = 'closed';
  }

  open(): void {
    this.readyState = 'open';
    this.onopen?.();
  }
}

class VirtualPeerConnection implements PeerConnectionLike {
  private static peers = new Map<string, VirtualPeerConnection>();
  private readonly id = `vpc_${Math.random().toString(16).slice(2)}`;
  private remote: VirtualPeerConnection | null = null;
  localChannel: VirtualDataChannel | null = null;
  onicecandidate: ((event: { candidate: IceCandidate | null }) => void) | null = null;
  ondatachannel: ((event: { channel: DataChannelLike }) => void) | null = null;

  createDataChannel(): DataChannelLike {
    this.localChannel = new VirtualDataChannel();
    return this.localChannel;
  }

  async createOffer(): Promise<SessionDescription> {
    return { type: 'offer', sdp: `virtual:${this.id}` };
  }

  async createAnswer(): Promise<SessionDescription> {
    return { type: 'answer', sdp: `virtual:${this.id}` };
  }

  async setLocalDescription(): Promise<void> {
    VirtualPeerConnection.peers.set(this.id, this);
    queueMicrotask(() => this.onicecandidate?.({ candidate: null }));
  }

  async setRemoteDescription(description: SessionDescription): Promise<void> {
    const remoteId = description.sdp.replace('virtual:', '');
    this.remote = VirtualPeerConnection.peers.get(remoteId) ?? null;
    if (!this.remote) return;
    this.remote.remote = this;
    if (!this.localChannel && this.remote.localChannel) {
      const channel = new VirtualDataChannel();
      channel.peer = this.remote.localChannel;
      this.remote.localChannel.peer = channel;
      this.localChannel = channel;
      this.ondatachannel?.({ channel });
      this.remote.localChannel.open();
      channel.open();
    }
  }

  async addIceCandidate(): Promise<void> {
    return undefined;
  }

  close(): void {
    VirtualPeerConnection.peers.delete(this.id);
    this.localChannel?.close();
  }
}

export function virtualPeerConnectionFactory(): PeerConnectionLike {
  return new VirtualPeerConnection();
}

export class WebRTCTransport implements TransportAdapter {
  readonly name = 'webrtc';
  private readonly channels = new Map<string, DataChannelLike>();
  private readonly connections = new Map<string, PeerConnectionLike>();
  private handler: IncomingHandler | null = null;

  constructor(
    private readonly selfId: string,
    private readonly signaling: SignalingClient,
    private readonly factory: PeerConnectionFactory,
  ) {
    this.signaling.onMessage((message) => {
      void this.onSignal(message);
    });
  }

  isConnected(peerId: string): boolean {
    return this.channels.get(peerId)?.readyState === 'open';
  }

  async connect(peerId: string): Promise<boolean> {
    if (this.isConnected(peerId)) return true;
    if (peerId === this.selfId) return false;
    try {
      const connection = this.factory();
      this.connections.set(peerId, connection);
      const channel = connection.createDataChannel('direct');
      this.bindChannel(peerId, channel);
      const offer = await connection.createOffer();
      await connection.setLocalDescription(offer);
      assertSignalMessage({ to: peerId, from: this.selfId, kind: 'offer', description: offer });
      await this.signaling.send({ to: peerId, from: this.selfId, kind: 'offer', description: offer });
      return await this.waitUntilOpen(peerId, 400);
    } catch {
      return false;
    }
  }

  async send(peerId: string, payload: Uint8Array): Promise<void> {
    const channel = this.channels.get(peerId);
    if (!channel || channel.readyState !== 'open') throw new Error('WebRTC data channel is not open.');
    channel.send(payload);
  }

  async disconnect(peerId: string): Promise<void> {
    this.channels.get(peerId)?.close();
    this.channels.delete(peerId);
    this.connections.get(peerId)?.close();
    this.connections.delete(peerId);
  }

  subscribe(handler: IncomingHandler): () => void {
    this.handler = handler;
    return () => {
      if (this.handler === handler) this.handler = null;
    };
  }

  private bindChannel(peerId: string, channel: DataChannelLike): void {
    this.channels.set(peerId, channel);
    channel.onopen = () => undefined;
    channel.onmessage = (event) => this.handler?.(peerId, event.data);
  }

  private async onSignal(message: SignalMessage): Promise<void> {
    if (message.to !== this.selfId) return;
    try {
      assertSignalMessage(message);
    } catch {
      return;
    }
    if (message.kind === 'offer' && message.description) {
      const connection = this.factory();
      this.connections.set(message.from, connection);
      connection.ondatachannel = (event) => this.bindChannel(message.from, event.channel);
      await connection.setRemoteDescription(message.description);
      const answer = await connection.createAnswer();
      await connection.setLocalDescription(answer);
      await this.signaling.send({ to: message.from, from: this.selfId, kind: 'answer', description: answer });
    }
    if (message.kind === 'answer' && message.description) {
      await this.connections.get(message.from)?.setRemoteDescription(message.description);
    }
    if (message.kind === 'ice' && message.candidate) {
      await this.connections.get(message.from)?.addIceCandidate(message.candidate);
    }
  }

  private waitUntilOpen(peerId: string, timeoutMs: number): Promise<boolean> {
    const started = Date.now();
    return new Promise((resolve) => {
      const timer = setInterval(() => {
        if (this.isConnected(peerId)) {
          clearInterval(timer);
          resolve(true);
        } else if (Date.now() - started > timeoutMs) {
          clearInterval(timer);
          resolve(false);
        }
      }, 10);
    });
  }
}

export class SignalingBus {
  private readonly handlers = new Map<string, (message: SignalMessage) => void>();

  client(selfId: string): SignalingClient {
    return {
      send: async (message) => {
        assertSignalMessage(message);
        this.handlers.get(message.to)?.(message);
      },
      onMessage: (handler) => {
        this.handlers.set(selfId, handler);
        return () => {
          if (this.handlers.get(selfId) === handler) this.handlers.delete(selfId);
        };
      },
    };
  }
}
