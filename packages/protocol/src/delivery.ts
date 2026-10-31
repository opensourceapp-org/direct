import { base64UrlToBytes, bytesToBase64Url, createLogger, text, utf8 } from '@direct/shared';
import type { Logger } from '@direct/shared';
import { nextDelayMs } from './backoff';
import { aadFor, decodeEnvelope, encodeEnvelope } from './envelope';
import type { Envelope } from './envelope';
import type { ContactPublic, DeliveryStore, LocalIdentity, MessageRouter, MessageRow, QueueRow } from './types';

const DEFAULT_TTL_MS = 7 * 24 * 60 * 60 * 1000;

export type SendInput = {
  recipient: ContactPublic;
  body: string;
};

export class DeliveryRejected extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'DeliveryRejected';
  }
}

/**
 * Outgoing messages stay in the local database until a signed acknowledgement
 * arrives. A relay that accepts ciphertext does not satisfy that condition.
 */
export class DeliveryEngine {
  private chain: Promise<void> = Promise.resolve();
  private flushing = false;
  private rerun = false;
  private readonly log: Logger;
  private readonly ttlMs: number;

  constructor(
    private readonly deps: {
      store: DeliveryStore;
      router: MessageRouter;
      identity: () => LocalIdentity | null;
      contact: (directId: string) => ContactPublic | null;
      clock: { now(): number };
      ids: { next(prefix: string): string };
      onChange?: () => void;
      logger?: Logger;
      ttlMs?: number;
      random?: () => number;
    },
  ) {
    this.log = deps.logger ?? createLogger();
    this.ttlMs = deps.ttlMs ?? DEFAULT_TTL_MS;
  }

  async sendText(input: SendInput): Promise<MessageRow> {
    const identity = this.requireIdentity();
    const body = input.body.trim();
    if (!body) throw new DeliveryRejected('Message is empty.');
    if (body.length > 8000) throw new DeliveryRejected('Message is too long.');
    if (this.deps.store.isBlocked(input.recipient.directId)) {
      throw new DeliveryRejected('This contact is blocked.');
    }
    const now = this.deps.clock.now();
    const id = this.deps.ids.next('msg');
    const envelope = this.sealUserEnvelope(identity, input.recipient, id, body, now);
    const row: MessageRow = {
      id,
      conversationId: '',
      senderDirectId: identity.directId,
      recipientDirectId: input.recipient.directId,
      body,
      ciphertext: encodeEnvelope(envelope, identity.cipher),
      createdAt: now,
      status: 'pending',
      direction: 'outgoing',
      kind: 'user',
      transport: null,
    };
    this.deps.store.transaction(() => {
      row.conversationId = this.deps.store.ensureConversation(input.recipient.directId, body, now, false);
      this.deps.store.insertMessage(row);
      this.deps.store.enqueue(this.queueRow(row.id, input.recipient.directId, row.ciphertext, now));
    });
    this.log.info('message.queued', { messageId: id, status: 'pending' });
    this.deps.onChange?.();
    await this.flush();
    return this.deps.store.getMessage(id) ?? row;
  }

  flush(): Promise<void> {
    if (this.flushing) {
      this.rerun = true;
      return Promise.resolve();
    }
    this.chain = this.drain();
    return this.chain;
  }

  private async drain(): Promise<void> {
    this.flushing = true;
    try {
      do {
        this.rerun = false;
        await this.flushOnce();
      } while (this.rerun);
    } catch (error) {
      this.log.warn('delivery.flush_failed', { reason: error instanceof Error ? error.name : 'error' });
    } finally {
      this.flushing = false;
    }
  }

  async receive(bytes: Uint8Array, claimedFrom?: string): Promise<'stored' | 'duplicate' | 'receipt' | 'ignored'> {
    const identity = this.deps.identity();
    if (!identity) return 'ignored';
    const preview = this.peekSender(bytes);
    if (!preview) return 'ignored';
    if (preview.to !== identity.directId) return 'ignored';
    if (this.deps.store.isBlocked(preview.from)) return 'ignored';
    const contact = this.deps.contact(preview.from);
    if (!contact) return 'ignored';
    if (claimedFrom && claimedFrom !== 'relay' && claimedFrom !== preview.from) return 'ignored';
    let envelope: Envelope;
    try {
      envelope = decodeEnvelope(bytes, identity.cipher.verify, contact.signingPublic, this.deps.clock.now());
    } catch {
      this.log.warn('envelope.rejected', { reason: 'auth' });
      return 'ignored';
    }
    if (envelope.type === 'ack' || envelope.type === 'read') {
      this.acceptReceipt(identity, contact, envelope);
      this.deps.onChange?.();
      return 'receipt';
    }
    if (this.deps.store.hasMessage(envelope.id)) {
      await this.sendReceipt(contact, envelope.id, 'ack');
      return 'duplicate';
    }
    let body = '';
    try {
      body = text(identity.cipher.open(bytesFromEnvelope(envelope), aadFor(envelope)));
    } catch {
      this.log.warn('envelope.rejected', { reason: 'seal' });
      return 'ignored';
    }
    const now = this.deps.clock.now();
    const row: MessageRow = {
      id: envelope.id,
      conversationId: '',
      senderDirectId: envelope.from,
      recipientDirectId: envelope.to,
      body,
      ciphertext: bytes,
      createdAt: envelope.createdAt,
      status: 'delivered',
      direction: 'incoming',
      kind: 'user',
      transport: 'direct',
    };
    this.deps.store.transaction(() => {
      if (this.deps.store.hasMessage(envelope.id)) return;
      row.conversationId = this.deps.store.ensureConversation(contact.directId, body, now, true);
      this.deps.store.insertMessage(row);
    });
    this.log.info('message.stored', { messageId: envelope.id, status: 'delivered' });
    this.deps.onChange?.();
    await this.sendReceipt(contact, envelope.id, 'ack');
    return 'stored';
  }

  async markRead(recipient: ContactPublic, messageIds: string[]): Promise<void> {
    for (const messageId of messageIds) {
      const message = this.deps.store.getMessage(messageId);
      if (!message || message.direction !== 'incoming' || message.status === 'read') continue;
      this.deps.store.updateMessageStatus(messageId, 'read');
      await this.sendReceipt(recipient, messageId, 'read');
    }
    this.deps.onChange?.();
  }

  private async flushOnce(): Promise<void> {
    const identity = this.deps.identity();
    if (!identity) return;
    const due = this.deps.store.due(this.deps.clock.now(), 20);
    for (const item of due) {
      if (item.expiresAt <= this.deps.clock.now()) {
        this.deps.store.transaction(() => {
          this.deps.store.updateMessageStatus(item.messageId, 'expired');
          this.deps.store.removeFromQueue(item.messageId);
        });
        this.log.info('message.expired', { messageId: item.messageId, status: 'expired' });
        continue;
      }
      if (this.deps.store.isBlocked(item.peerId)) {
        this.deps.store.transaction(() => {
          this.deps.store.updateMessageStatus(item.messageId, 'failed');
          this.deps.store.removeFromQueue(item.messageId);
        });
        continue;
      }
      try {
        const route = await this.deps.router.send(item.peerId, item.payload);
        const message = this.deps.store.getMessage(item.messageId);
        if (!this.deps.store.getQueueByMessage(item.messageId)) continue;
        if (route.kind === 'direct' && message?.kind === 'receipt') {
          this.deps.store.transaction(() => {
            this.deps.store.updateMessageStatus(item.messageId, 'delivered', 'direct');
            this.deps.store.removeFromQueue(item.messageId);
          });
          continue;
        }
        const transport = route.kind === 'relay' ? 'relay' : route.kind === 'direct' ? 'direct' : null;
        const attempts = item.attempts + 1;
        this.deps.store.transaction(() => {
          if (transport && message?.status === 'pending') {
            this.deps.store.updateMessageStatus(item.messageId, 'pending', transport);
          }
          this.deps.store.reschedule(
            item.messageId,
            attempts,
            this.deps.clock.now() + nextDelayMs(attempts, this.deps.random),
            route.kind === 'queued' ? 'recipient unavailable' : null,
          );
        });
        this.log.info('message.routed', { messageId: item.messageId, transport: route.kind, status: 'pending' });
      } catch (error) {
        const attempts = item.attempts + 1;
        this.deps.store.reschedule(
          item.messageId,
          attempts,
          this.deps.clock.now() + nextDelayMs(attempts, this.deps.random),
          error instanceof Error ? error.name : 'send failed',
        );
      }
    }
    this.deps.onChange?.();
  }

  private acceptReceipt(identity: LocalIdentity, contact: ContactPublic, envelope: Envelope): void {
    let inner = '';
    try {
      inner = text(identity.cipher.open(bytesFromEnvelope(envelope), aadFor(envelope)));
    } catch {
      return;
    }
    const [kind, messageId] = inner.split(':');
    if ((kind !== 'ack' && kind !== 'read') || !messageId) return;
    const message = this.deps.store.getMessage(messageId);
    if (!message || message.senderDirectId !== identity.directId) return;
    if (message.status === 'read') return;
    if (kind === 'ack' && message.status === 'delivered') return;
    this.deps.store.transaction(() => {
      if (!this.deps.store.hasAck(messageId) && kind === 'ack') {
        this.deps.store.insertAck({
          id: this.deps.ids.next('ack'),
          messageId,
          peerId: contact.directId,
          signature: base64UrlToBytes(envelope.signature),
          receivedAt: this.deps.clock.now(),
          verified: true,
        });
      }
      this.deps.store.updateMessageStatus(messageId, kind === 'read' ? 'read' : 'delivered');
      this.deps.store.removeFromQueue(messageId);
    });
    this.log.info('message.acknowledged', { messageId, status: kind === 'read' ? 'read' : 'delivered' });
  }

  private async sendReceipt(contact: ContactPublic, messageId: string, kind: 'ack' | 'read'): Promise<void> {
    const identity = this.requireIdentity();
    const now = this.deps.clock.now();
    const id = this.deps.ids.next(kind);
    const plaintext = utf8(`${kind}:${messageId}`);
    const draft: Omit<Envelope, 'signature'> = {
      v: 1,
      id,
      type: kind,
      from: identity.directId,
      to: contact.directId,
      deviceId: identity.deviceId,
      createdAt: now,
      expiresAt: now + this.ttlMs,
      ciphertext: '',
    };
    draft.ciphertext = bytesToBase64Url(identity.cipher.sealTo(contact.agreementPublic, plaintext, aadFor(draft)));
    const payload = encodeEnvelope(draft, identity.cipher);
    this.deps.store.transaction(() => {
      const conversationId = this.deps.store.ensureConversation(contact.directId, null, now, false);
      this.deps.store.insertMessage({
        id,
        conversationId,
        senderDirectId: identity.directId,
        recipientDirectId: contact.directId,
        body: '',
        ciphertext: payload,
        createdAt: now,
        status: 'pending',
        direction: 'outgoing',
        kind: 'receipt',
        transport: null,
      });
      this.deps.store.enqueue(this.queueRow(id, contact.directId, payload, now));
    });
    if (this.flushing) {
      this.rerun = true;
      return;
    }
    await this.flush();
  }

  private sealUserEnvelope(identity: LocalIdentity, recipient: ContactPublic, id: string, body: string, now: number): Omit<Envelope, 'signature'> {
    const draft: Omit<Envelope, 'signature'> = {
      v: 1,
      id,
      type: 'message',
      from: identity.directId,
      to: recipient.directId,
      deviceId: identity.deviceId,
      createdAt: now,
      expiresAt: now + this.ttlMs,
      ciphertext: '',
    };
    draft.ciphertext = bytesToBase64Url(identity.cipher.sealTo(recipient.agreementPublic, utf8(body), aadFor(draft)));
    return draft;
  }

  private queueRow(messageId: string, peerId: string, payload: Uint8Array, now: number): QueueRow {
    return {
      id: this.deps.ids.next('dq'),
      messageId,
      peerId,
      payload,
      attempts: 0,
      nextAttemptAt: now,
      expiresAt: now + this.ttlMs,
      createdAt: now,
      lastError: null,
    };
  }

  private requireIdentity(): LocalIdentity {
    const identity = this.deps.identity();
    if (!identity) throw new DeliveryRejected('Create an identity before sending.');
    return identity;
  }

  private peekSender(bytes: Uint8Array): { from: string; to: string } | null {
    try {
      const parsed = JSON.parse(text(bytes)) as { from?: string; to?: string };
      if (!parsed.from || !parsed.to) return null;
      return { from: parsed.from, to: parsed.to };
    } catch {
      return null;
    }
  }
}

function bytesFromEnvelope(envelope: Envelope): Uint8Array {
  return base64UrlToBytes(envelope.ciphertext);
}
