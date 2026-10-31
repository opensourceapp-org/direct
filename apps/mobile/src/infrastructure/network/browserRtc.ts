import type { DataChannelLike, IceCandidate, PeerConnectionLike, SessionDescription } from '@direct/transport';

const STUN = [{ urls: 'stun:stun.l.google.com:19302' }, { urls: 'stun:stun1.l.google.com:19302' }];

function wrapChannel(channel: RTCDataChannel): DataChannelLike {
  channel.binaryType = 'arraybuffer';
  const wrapped: DataChannelLike = {
    get readyState() {
      return channel.readyState;
    },
    send(data: Uint8Array) {
      const copy = new Uint8Array(data.byteLength);
      copy.set(data);
      channel.send(copy);
    },
    close() {
      channel.close();
    },
    onopen: null,
    onmessage: null,
  };
  channel.onopen = () => wrapped.onopen?.();
  channel.onmessage = (event) => {
    const data = event.data instanceof ArrayBuffer ? new Uint8Array(event.data) : new Uint8Array();
    wrapped.onmessage?.({ data });
  };
  return wrapped;
}

/** Browser RTCPeerConnection with public STUN. Symmetric NAT may still need TURN. */
export function browserPeerConnectionFactory(): PeerConnectionLike {
  const pc = new RTCPeerConnection({ iceServers: STUN });
  let onicecandidate: ((event: { candidate: IceCandidate | null }) => void) | null = null;
  let ondatachannel: ((event: { channel: DataChannelLike }) => void) | null = null;
  pc.onicecandidate = (event) => {
    const candidate = event.candidate;
    onicecandidate?.({
      candidate: candidate ? { candidate: candidate.candidate, sdpMid: candidate.sdpMid } : null,
    });
  };
  pc.ondatachannel = (event) => {
    ondatachannel?.({ channel: wrapChannel(event.channel) });
  };
  return {
    createDataChannel(label: string) {
      return wrapChannel(pc.createDataChannel(label));
    },
    async createOffer(): Promise<SessionDescription> {
      const offer = await pc.createOffer();
      return { type: 'offer', sdp: offer.sdp ?? '' };
    },
    async createAnswer(): Promise<SessionDescription> {
      const answer = await pc.createAnswer();
      return { type: 'answer', sdp: answer.sdp ?? '' };
    },
    setLocalDescription(description: SessionDescription) {
      return pc.setLocalDescription(description);
    },
    setRemoteDescription(description: SessionDescription) {
      return pc.setRemoteDescription(description);
    },
    addIceCandidate(candidate: IceCandidate) {
      return pc.addIceCandidate(candidate);
    },
    close() {
      pc.close();
    },
    get onicecandidate() {
      return onicecandidate;
    },
    set onicecandidate(handler) {
      onicecandidate = handler;
    },
    get ondatachannel() {
      return ondatachannel;
    },
    set ondatachannel(handler) {
      ondatachannel = handler;
    },
  };
}
