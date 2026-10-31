import type { AckRow, DeliveryStore, MessageRow, MessageStatus, QueueRow, TransportHint } from './types';

type Conversation = {
  id: string;
  peerDirectId: string;
  preview: string;
  updatedAt: number;
  unread: number;
};

export class MemoryDeliveryStore implements DeliveryStore {
  readonly messages: MessageRow[] = [];
  readonly queue: QueueRow[] = [];
  readonly acks: AckRow[] = [];
  readonly conversations = new Map<string, Conversation>();
  readonly blocked = new Set<string>();
  private depth = 0;
  private backup = '';

  transaction<T>(work: () => T): T {
    const outer = this.depth === 0;
    if (outer) this.backup = this.capture();
    this.depth += 1;
    try {
      const result = work();
      this.depth -= 1;
      return result;
    } catch (error) {
      this.depth -= 1;
      if (outer) this.restore(this.backup);
      throw error;
    }
  }

  hasMessage(id: string): boolean {
    return this.messages.some((message) => message.id === id);
  }

  getMessage(id: string): MessageRow | null {
    return this.messages.find((message) => message.id === id) ?? null;
  }

  insertMessage(row: MessageRow): void {
    if (this.hasMessage(row.id)) throw new Error(`Duplicate message ${row.id}`);
    this.messages.push({ ...row, ciphertext: new Uint8Array(row.ciphertext) });
  }

  updateMessageStatus(id: string, status: MessageStatus, transport?: TransportHint): void {
    const message = this.getMessage(id);
    if (!message) return;
    message.status = status;
    if (transport !== undefined) message.transport = transport;
  }

  enqueue(row: QueueRow): void {
    this.queue.push({ ...row, payload: new Uint8Array(row.payload) });
  }

  due(now: number, limit: number): QueueRow[] {
    return this.queue
      .filter((row) => row.nextAttemptAt <= now)
      .sort((left, right) => left.nextAttemptAt - right.nextAttemptAt)
      .slice(0, limit)
      .map((row) => ({ ...row, payload: new Uint8Array(row.payload) }));
  }

  getQueueByMessage(messageId: string): QueueRow | null {
    return this.queue.find((row) => row.messageId === messageId) ?? null;
  }

  reschedule(messageId: string, attempts: number, nextAttemptAt: number, lastError: string | null): void {
    const row = this.getQueueByMessage(messageId);
    if (!row) return;
    row.attempts = attempts;
    row.nextAttemptAt = nextAttemptAt;
    row.lastError = lastError;
  }

  removeFromQueue(messageId: string): void {
    const index = this.queue.findIndex((row) => row.messageId === messageId);
    if (index >= 0) this.queue.splice(index, 1);
  }

  insertAck(row: AckRow): void {
    if (this.hasAck(row.messageId)) return;
    this.acks.push({ ...row, signature: new Uint8Array(row.signature) });
  }

  hasAck(messageId: string): boolean {
    return this.acks.some((ack) => ack.messageId === messageId);
  }

  isBlocked(directId: string): boolean {
    return this.blocked.has(directId);
  }

  ensureConversation(peerDirectId: string, preview: string | null, at: number, incoming: boolean): string {
    const id = `conv_${peerDirectId}`;
    const existing = this.conversations.get(id);
    if (!existing) {
      this.conversations.set(id, {
        id,
        peerDirectId,
        preview: preview ?? '',
        updatedAt: at,
        unread: incoming ? 1 : 0,
      });
      return id;
    }
    if (preview !== null) existing.preview = preview;
    existing.updatedAt = at;
    if (incoming) existing.unread += 1;
    return id;
  }

  private capture(): string {
    return JSON.stringify({
      messages: this.messages.map(serializeMessage),
      queue: this.queue.map(serializeQueue),
      acks: this.acks.map((ack) => ({ ...ack, signature: [...ack.signature] })),
      conversations: [...this.conversations.values()],
    });
  }

  private restore(snapshot: string): void {
    const parsed = JSON.parse(snapshot) as {
      messages: Array<Omit<MessageRow, 'ciphertext'> & { ciphertext: number[] }>;
      queue: Array<Omit<QueueRow, 'payload'> & { payload: number[] }>;
      acks: Array<Omit<AckRow, 'signature'> & { signature: number[] }>;
      conversations: Conversation[];
    };
    this.messages.splice(0, this.messages.length, ...parsed.messages.map((row) => ({ ...row, ciphertext: Uint8Array.from(row.ciphertext) })));
    this.queue.splice(0, this.queue.length, ...parsed.queue.map((row) => ({ ...row, payload: Uint8Array.from(row.payload) })));
    this.acks.splice(0, this.acks.length, ...parsed.acks.map((row) => ({ ...row, signature: Uint8Array.from(row.signature) })));
    this.conversations.clear();
    for (const conversation of parsed.conversations) this.conversations.set(conversation.id, conversation);
  }
}

function serializeMessage(row: MessageRow): unknown {
  return { ...row, ciphertext: [...row.ciphertext] };
}

function serializeQueue(row: QueueRow): unknown {
  return { ...row, payload: [...row.payload] };
}
