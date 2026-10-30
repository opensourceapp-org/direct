import type { RouteResult, TransportAdapter } from './types';

export type RouterOptions = {
  direct: TransportAdapter[];
  relay: TransportAdapter | null;
  relayEnabled: boolean;
};

/**
 * Transport priority:
 * 1. An existing direct connection.
 * 2. A new direct connection.
 * 3. An optional distributed relay.
 * 4. Caller keeps the payload and retries. Relay acceptance is never delivery.
 */
export class TransportRouter {
  constructor(private readonly options: RouterOptions) {}

  setRelayEnabled(enabled: boolean): void {
    this.options.relayEnabled = enabled;
  }

  useDirect(transports: TransportAdapter[]): void {
    this.options.direct = transports;
  }

  async send(peerId: string, payload: Uint8Array): Promise<RouteResult> {
    for (const transport of this.options.direct) {
      if (!transport.isConnected(peerId)) continue;
      await transport.send(peerId, payload);
      return { kind: 'direct', transport: transport.name };
    }
    for (const transport of this.options.direct) {
      if (transport.isConnected(peerId)) continue;
      const connected = await transport.connect(peerId);
      if (!connected) continue;
      await transport.send(peerId, payload);
      return { kind: 'direct', transport: transport.name };
    }
    if (this.options.relayEnabled && this.options.relay) {
      const relay = this.options.relay;
      const available = relay.isConnected(peerId) || (await relay.connect(peerId));
      if (available) {
        await relay.send(peerId, payload);
        return { kind: 'relay', transport: relay.name };
      }
    }
    return { kind: 'queued' };
  }

  connectedPeers(peerIds: string[]): { peerId: string; transport: string }[] {
    const found: { peerId: string; transport: string }[] = [];
    for (const peerId of peerIds) {
      const direct = this.options.direct.find((transport) => transport.isConnected(peerId));
      if (direct) found.push({ peerId, transport: direct.name });
    }
    return found;
  }
}
