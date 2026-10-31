export type MessageStatus = 'pending' | 'delivered' | 'read' | 'expired' | 'failed';
export type MessageKind = 'user' | 'receipt';
export type MessageDirection = 'outgoing' | 'incoming';
export type TransportHint = 'direct' | 'relay' | null;

export type MessageRow = {
  id: string;
  conversationId: string;
  senderDirectId: string;
  recipientDirectId: string;
  body: string;
  ciphertext: Uint8Array;
  createdAt: number;
  status: MessageStatus;
  direction: MessageDirection;
  kind: MessageKind;
  transport: TransportHint;
};

export type QueueRow = {
  id: string;
  messageId: string;
  peerId: string;
  payload: Uint8Array;
  attempts: number;
  nextAttemptAt: number;
  expiresAt: number;
  createdAt: number;
  lastError: string | null;
};

export type AckRow = {
  id: string;
  messageId: string;
  peerId: string;
  signature: Uint8Array;
  receivedAt: number;
  verified: boolean;
};

export interface DeliveryStore {
  transaction<T>(work: () => T): T;
  hasMessage(id: string): boolean;
  getMessage(id: string): MessageRow | null;
  insertMessage(row: MessageRow): void;
  updateMessageStatus(id: string, status: MessageStatus, transport?: TransportHint): void;
  enqueue(row: QueueRow): void;
  due(now: number, limit: number): QueueRow[];
  getQueueByMessage(messageId: string): QueueRow | null;
  reschedule(messageId: string, attempts: number, nextAttemptAt: number, lastError: string | null): void;
  removeFromQueue(messageId: string): void;
  insertAck(row: AckRow): void;
  hasAck(messageId: string): boolean;
  isBlocked(directId: string): boolean;
  ensureConversation(peerDirectId: string, preview: string | null, at: number, incoming: boolean): string;
}

export type PeerCipher = {
  sealTo(agreementPublic: Uint8Array, plaintext: Uint8Array, aad: Uint8Array): Uint8Array;
  open(payload: Uint8Array, aad: Uint8Array): Uint8Array;
  sign(message: Uint8Array): Uint8Array;
  verify(signingPublic: Uint8Array, message: Uint8Array, signature: Uint8Array): boolean;
};

export type RouteResult =
  | { kind: 'direct'; transport: string }
  | { kind: 'relay'; transport: string }
  | { kind: 'queued' };

export interface MessageRouter {
  send(peerId: string, payload: Uint8Array): Promise<RouteResult>;
}

export type ContactPublic = {
  directId: string;
  signingPublic: Uint8Array;
  agreementPublic: Uint8Array;
};

export type LocalIdentity = {
  directId: string;
  deviceId: string;
  cipher: PeerCipher;
};
