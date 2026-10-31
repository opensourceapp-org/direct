import { bytesToBase64Url, base64UrlToBytes } from '@direct/shared';
import type {
  AckRow,
  DeliveryStore,
  MessageDirection,
  MessageKind,
  MessageRow,
  MessageStatus,
  QueueRow,
  TransportHint,
} from '@direct/protocol';
import type { EncryptedDatabase, SqlValue } from './database';

export type IdentityRecord = {
  id: string;
  directId: string;
  did: string;
  displayName: string;
  agreementPublic: string;
  signingPublic: string;
  agreementSignature: string;
  fingerprint: string;
  deviceId: string;
  createdAt: number;
};

export type ContactRecord = {
  id: string;
  directId: string;
  did: string;
  displayName: string;
  agreementPublic: string;
  signingPublic: string;
  agreementSignature: string;
  fingerprint: string;
  deviceId: string;
  verified: boolean;
  blocked: boolean;
  accepted: boolean;
  createdAt: number;
};

export type ConversationRecord = {
  id: string;
  contactId: string;
  directId: string;
  displayName: string;
  fingerprint: string;
  verified: boolean;
  blocked: boolean;
  accepted: boolean;
  preview: string;
  updatedAt: number;
  unread: number;
  lastStatus: string | null;
  lastTransport: string | null;
};

export type DeviceRecord = {
  id: string;
  deviceId: string;
  label: string;
  publicKey: string;
  createdAt: number;
  revokedAt: number | null;
  lastSeenAt: number | null;
};

function asString(row: Record<string, SqlValue>, key: string): string {
  const value = row[key];
  if (typeof value !== 'string') return value == null ? '' : String(value);
  return value;
}

function asNumber(row: Record<string, SqlValue>, key: string): number {
  const value = row[key];
  if (typeof value === 'number') return value;
  if (typeof value === 'bigint') return Number(value);
  return Number(value ?? 0);
}

function asBytes(row: Record<string, SqlValue>, key: string): Uint8Array {
  const value = row[key];
  if (value instanceof Uint8Array) return value;
  if (typeof value === 'string') return new TextEncoder().encode(value);
  return new Uint8Array();
}

export class DirectRepository implements DeliveryStore {
  constructor(private readonly db: EncryptedDatabase) {}

  transaction<T>(work: () => T): T {
    return this.db.transaction(work);
  }

  save(): Promise<Uint8Array> {
    return this.db.save();
  }

  insertIdentity(record: IdentityRecord): void {
    this.db.run(
      `INSERT INTO identities (
        id, direct_id, did, display_name, public_key, signing_public_key,
        agreement_signature, fingerprint, device_id, created_at, verified
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1)`,
      [
        record.id,
        record.directId,
        record.did,
        record.displayName,
        record.agreementPublic,
        record.signingPublic,
        record.agreementSignature,
        record.fingerprint,
        record.deviceId,
        record.createdAt,
      ],
    );
  }

  getIdentity(): IdentityRecord | null {
    const row = this.db.one('SELECT * FROM identities ORDER BY created_at ASC LIMIT 1');
    if (!row) return null;
    return {
      id: asString(row, 'id'),
      directId: asString(row, 'direct_id'),
      did: asString(row, 'did'),
      displayName: asString(row, 'display_name'),
      agreementPublic: asString(row, 'public_key'),
      signingPublic: asString(row, 'signing_public_key'),
      agreementSignature: asString(row, 'agreement_signature'),
      fingerprint: asString(row, 'fingerprint'),
      deviceId: asString(row, 'device_id'),
      createdAt: asNumber(row, 'created_at'),
    };
  }

  updateIdentityKeys(record: Pick<IdentityRecord, 'agreementPublic' | 'agreementSignature' | 'fingerprint'>): void {
    this.db.run(
      `UPDATE identities SET public_key = ?, agreement_signature = ?, fingerprint = ?`,
      [record.agreementPublic, record.agreementSignature, record.fingerprint],
    );
  }

  updateDisplayName(name: string): void {
    this.db.run('UPDATE identities SET display_name = ?', [name]);
  }

  insertDevice(device: DeviceRecord & { identityId: string }): void {
    this.db.run(
      `INSERT INTO devices (id, identity_id, device_id, label, public_key, created_at, revoked_at, last_seen_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      [device.id, device.identityId, device.deviceId, device.label, device.publicKey, device.createdAt, device.revokedAt, device.lastSeenAt],
    );
  }

  listDevices(): DeviceRecord[] {
    return this.db.all('SELECT * FROM devices ORDER BY created_at ASC').map((row) => ({
      id: asString(row, 'id'),
      deviceId: asString(row, 'device_id'),
      label: asString(row, 'label'),
      publicKey: asString(row, 'public_key'),
      createdAt: asNumber(row, 'created_at'),
      revokedAt: row.revoked_at == null ? null : asNumber(row, 'revoked_at'),
      lastSeenAt: row.last_seen_at == null ? null : asNumber(row, 'last_seen_at'),
    }));
  }

  revokeDevice(id: string, at: number): void {
    this.transaction(() => {
      this.db.run('UPDATE devices SET revoked_at = ? WHERE id = ?', [at, id]);
      this.db.run('DELETE FROM encryption_sessions');
    });
  }

  touchDevice(deviceId: string, at: number): void {
    this.db.run('UPDATE devices SET last_seen_at = ? WHERE device_id = ? AND revoked_at IS NULL', [at, deviceId]);
  }

  upsertContact(contact: ContactRecord): void {
    this.db.run(
      `INSERT INTO contacts (
        id, direct_id, did, display_name, public_key, signing_public_key,
        agreement_signature, fingerprint, device_id, verified, accepted, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(direct_id) DO UPDATE SET
        display_name = excluded.display_name,
        did = excluded.did,
        public_key = excluded.public_key,
        signing_public_key = excluded.signing_public_key,
        agreement_signature = excluded.agreement_signature,
        fingerprint = excluded.fingerprint,
        device_id = excluded.device_id,
        verified = CASE WHEN contacts.fingerprint = excluded.fingerprint THEN contacts.verified ELSE 0 END,
        accepted = CASE WHEN excluded.accepted = 1 OR contacts.accepted = 1 THEN 1 ELSE 0 END`,
      [
        contact.id,
        contact.directId,
        contact.did,
        contact.displayName,
        contact.agreementPublic,
        contact.signingPublic,
        contact.agreementSignature,
        contact.fingerprint,
        contact.deviceId,
        contact.verified ? 1 : 0,
        contact.accepted ? 1 : 0,
        contact.createdAt,
      ],
    );
  }

  listContacts(): ContactRecord[] {
    return this.db.all(
      `SELECT contacts.*, CASE WHEN blocked_contacts.contact_id IS NULL THEN 0 ELSE 1 END AS blocked
       FROM contacts
       LEFT JOIN blocked_contacts ON blocked_contacts.contact_id = contacts.id
       ORDER BY display_name COLLATE NOCASE ASC, direct_id ASC`,
    ).map(mapContact);
  }

  getContact(directId: string): ContactRecord | null {
    const row = this.db.one(
      `SELECT contacts.*, CASE WHEN blocked_contacts.contact_id IS NULL THEN 0 ELSE 1 END AS blocked
       FROM contacts LEFT JOIN blocked_contacts ON blocked_contacts.contact_id = contacts.id
       WHERE contacts.direct_id = ?`,
      [directId],
    );
    return row ? mapContact(row) : null;
  }

  setContactVerified(directId: string, verified: boolean): void {
    this.db.run('UPDATE contacts SET verified = ? WHERE direct_id = ?', [verified ? 1 : 0, directId]);
  }

  setContactAccepted(directId: string, accepted: boolean): void {
    this.db.run('UPDATE contacts SET accepted = ? WHERE direct_id = ?', [accepted ? 1 : 0, directId]);
  }

  blockContact(directId: string, at: number): void {
    const contact = this.getContact(directId);
    if (!contact) return;
    this.db.run(
      'INSERT INTO blocked_contacts (contact_id, blocked_at, reason) VALUES (?, ?, ?) ON CONFLICT(contact_id) DO UPDATE SET blocked_at = excluded.blocked_at',
      [contact.id, at, null],
    );
  }

  removeContact(directId: string): void {
    this.transaction(() => {
      const contact = this.getContact(directId);
      if (!contact) return;
      this.db.run(
        `DELETE FROM delivery_queue WHERE message_id IN (
          SELECT messages.id FROM messages
          JOIN conversations ON conversations.id = messages.conversation_id
          WHERE conversations.contact_id = ?
        )`,
        [contact.id],
      );
      this.db.run('DELETE FROM contacts WHERE id = ?', [contact.id]);
      this.db.run('DELETE FROM encryption_sessions WHERE peer_direct_id = ?', [directId]);
    });
  }

  listConversations(): ConversationRecord[] {
    return this.db.all(
      `SELECT conversations.id, conversations.contact_id, conversations.updated_at, conversations.unread_count,
              conversations.last_message_preview, contacts.direct_id, contacts.display_name, contacts.fingerprint,
              contacts.verified, contacts.accepted, CASE WHEN blocked_contacts.contact_id IS NULL THEN 0 ELSE 1 END AS blocked,
              (SELECT status FROM messages WHERE messages.conversation_id = conversations.id AND messages.kind = 'user' ORDER BY created_at DESC LIMIT 1) AS last_status,
              (SELECT transport FROM messages WHERE messages.conversation_id = conversations.id AND messages.kind = 'user' ORDER BY created_at DESC LIMIT 1) AS last_transport
       FROM conversations
       JOIN contacts ON contacts.id = conversations.contact_id
       LEFT JOIN blocked_contacts ON blocked_contacts.contact_id = contacts.id
       ORDER BY conversations.updated_at DESC`,
    ).map((row) => ({
      id: asString(row, 'id'),
      contactId: asString(row, 'contact_id'),
      directId: asString(row, 'direct_id'),
      displayName: asString(row, 'display_name'),
      fingerprint: asString(row, 'fingerprint'),
      verified: asNumber(row, 'verified') === 1,
      blocked: asNumber(row, 'blocked') === 1,
      accepted: asNumber(row, 'accepted') === 1,
      preview: asString(row, 'last_message_preview'),
      updatedAt: asNumber(row, 'updated_at'),
      unread: asNumber(row, 'unread_count'),
      lastStatus: row.last_status == null ? null : asString(row, 'last_status'),
      lastTransport: row.last_transport == null ? null : asString(row, 'last_transport'),
    }));
  }

  listMessages(conversationId: string): MessageRow[] {
    return this.db
      .all(
        `SELECT * FROM messages WHERE conversation_id = ? AND kind = 'user' ORDER BY created_at ASC, id ASC`,
        [conversationId],
      )
      .map(mapMessage);
  }

  clearUnread(conversationId: string): void {
    this.db.run('UPDATE conversations SET unread_count = 0 WHERE id = ?', [conversationId]);
  }

  recordSession(peerDirectId: string, agreementKey: string, at: number): void {
    const id = `ses_${peerDirectId}`;
    this.db.run(
      `INSERT INTO encryption_sessions (id, peer_direct_id, their_agreement_key, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?)
       ON CONFLICT(peer_direct_id) DO UPDATE SET their_agreement_key = excluded.their_agreement_key, updated_at = excluded.updated_at`,
      [id, peerDirectId, agreementKey, at, at],
    );
  }

  storageStats(): { messages: number; queued: number; contacts: number; bytes: number } {
    const messages = asNumber(this.db.one(`SELECT COUNT(*) AS count FROM messages WHERE kind = 'user'`) ?? {}, 'count');
    const queued = asNumber(this.db.one('SELECT COUNT(*) AS count FROM delivery_queue') ?? {}, 'count');
    const contacts = asNumber(this.db.one('SELECT COUNT(*) AS count FROM contacts') ?? {}, 'count');
    return { messages, queued, contacts, bytes: this.db.raw.export().length };
  }

  wipeMessages(): void {
    this.transaction(() => {
      this.db.run('DELETE FROM acknowledgements');
      this.db.run('DELETE FROM delivery_queue');
      this.db.run('DELETE FROM messages');
      this.db.run(`UPDATE conversations SET last_message_preview = '', last_message_at = NULL, unread_count = 0`);
    });
  }

  hasMessage(id: string): boolean {
    return Boolean(this.db.one('SELECT id FROM messages WHERE id = ?', [id]));
  }

  getMessage(id: string): MessageRow | null {
    const row = this.db.one('SELECT * FROM messages WHERE id = ?', [id]);
    return row ? mapMessage(row) : null;
  }

  insertMessage(row: MessageRow): void {
    this.db.run(
      `INSERT INTO messages (
        id, conversation_id, sender_direct_id, recipient_direct_id, body, ciphertext,
        created_at, status, direction, kind, transport
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [
        row.id,
        row.conversationId,
        row.senderDirectId,
        row.recipientDirectId,
        row.body,
        row.ciphertext,
        row.createdAt,
        row.status,
        row.direction,
        row.kind,
        row.transport,
      ],
    );
  }

  updateMessageStatus(id: string, status: MessageStatus, transport?: TransportHint): void {
    if (transport !== undefined) {
      this.db.run('UPDATE messages SET status = ?, transport = ? WHERE id = ?', [status, transport, id]);
      return;
    }
    this.db.run('UPDATE messages SET status = ? WHERE id = ?', [status, id]);
  }

  enqueue(row: QueueRow): void {
    this.db.run(
      `INSERT INTO delivery_queue (
        id, message_id, peer_id, payload, attempts, next_attempt_at, expires_at, created_at, last_error
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      [row.id, row.messageId, row.peerId, row.payload, row.attempts, row.nextAttemptAt, row.expiresAt, row.createdAt, row.lastError],
    );
  }

  due(now: number, limit: number): QueueRow[] {
    return this.db
      .all(
        `SELECT * FROM delivery_queue WHERE next_attempt_at <= ? ORDER BY next_attempt_at ASC LIMIT ?`,
        [now, limit],
      )
      .map(mapQueue);
  }

  getQueueByMessage(messageId: string): QueueRow | null {
    const row = this.db.one('SELECT * FROM delivery_queue WHERE message_id = ?', [messageId]);
    return row ? mapQueue(row) : null;
  }

  reschedule(messageId: string, attempts: number, nextAttemptAt: number, lastError: string | null): void {
    this.db.run(
      'UPDATE delivery_queue SET attempts = ?, next_attempt_at = ?, last_error = ? WHERE message_id = ?',
      [attempts, nextAttemptAt, lastError, messageId],
    );
  }

  removeFromQueue(messageId: string): void {
    this.db.run('DELETE FROM delivery_queue WHERE message_id = ?', [messageId]);
  }

  insertAck(row: AckRow): void {
    this.db.run(
      `INSERT OR IGNORE INTO acknowledgements (id, message_id, peer_id, signature, received_at, verified)
       VALUES (?, ?, ?, ?, ?, ?)`,
      [row.id, row.messageId, row.peerId, row.signature, row.receivedAt, row.verified ? 1 : 0],
    );
  }

  hasAck(messageId: string): boolean {
    return Boolean(this.db.one('SELECT id FROM acknowledgements WHERE message_id = ?', [messageId]));
  }

  isBlocked(directId: string): boolean {
    return Boolean(
      this.db.one(
        `SELECT blocked_contacts.contact_id FROM blocked_contacts
         JOIN contacts ON contacts.id = blocked_contacts.contact_id
         WHERE contacts.direct_id = ?`,
        [directId],
      ),
    );
  }

  ensureConversation(peerDirectId: string, preview: string | null, at: number, incoming: boolean): string {
    const contact = this.getContact(peerDirectId);
    if (!contact) throw new Error('Contact is not on this device.');
    const id = `conv_${peerDirectId}`;
    const existing = this.db.one('SELECT id, unread_count FROM conversations WHERE id = ?', [id]);
    if (!existing) {
      this.db.run(
        `INSERT INTO conversations (id, contact_id, created_at, updated_at, last_message_preview, last_message_at, unread_count)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
        [id, contact.id, at, at, preview ?? '', at, incoming ? 1 : 0],
      );
      return id;
    }
    this.db.run(
      `UPDATE conversations
       SET updated_at = ?,
           last_message_at = ?,
           last_message_preview = CASE WHEN ? IS NULL THEN last_message_preview ELSE ? END,
           unread_count = unread_count + ?
       WHERE id = ?`,
      [at, at, preview, preview, incoming ? 1 : 0, id],
    );
    return id;
  }

  unsealedDatabase(): Uint8Array {
    return this.db.raw.export();
  }
}

function mapContact(row: Record<string, SqlValue>): ContactRecord {
  return {
    id: asString(row, 'id'),
    directId: asString(row, 'direct_id'),
    did: asString(row, 'did'),
    displayName: asString(row, 'display_name'),
    agreementPublic: asString(row, 'public_key'),
    signingPublic: asString(row, 'signing_public_key'),
    agreementSignature: asString(row, 'agreement_signature'),
    fingerprint: asString(row, 'fingerprint'),
    deviceId: asString(row, 'device_id'),
    verified: asNumber(row, 'verified') === 1,
    blocked: asNumber(row, 'blocked') === 1,
    accepted: asNumber(row, 'accepted') === 1,
    createdAt: asNumber(row, 'created_at'),
  };
}

function mapMessage(row: Record<string, SqlValue>): MessageRow {
  const transport = asString(row, 'transport');
  return {
    id: asString(row, 'id'),
    conversationId: asString(row, 'conversation_id'),
    senderDirectId: asString(row, 'sender_direct_id'),
    recipientDirectId: asString(row, 'recipient_direct_id'),
    body: asString(row, 'body'),
    ciphertext: asBytes(row, 'ciphertext'),
    createdAt: asNumber(row, 'created_at'),
    status: asString(row, 'status') as MessageStatus,
    direction: asString(row, 'direction') as MessageDirection,
    kind: asString(row, 'kind') as MessageKind,
    transport: transport === 'direct' || transport === 'relay' ? transport : null,
  };
}

function mapQueue(row: Record<string, SqlValue>): QueueRow {
  return {
    id: asString(row, 'id'),
    messageId: asString(row, 'message_id'),
    peerId: asString(row, 'peer_id'),
    payload: asBytes(row, 'payload'),
    attempts: asNumber(row, 'attempts'),
    nextAttemptAt: asNumber(row, 'next_attempt_at'),
    expiresAt: asNumber(row, 'expires_at'),
    createdAt: asNumber(row, 'created_at'),
    lastError: row.last_error == null ? null : asString(row, 'last_error'),
  };
}

export function publicKeyMaterial(bytes: Uint8Array): string {
  return bytesToBase64Url(bytes);
}

export function publicKeyBytes(value: string): Uint8Array {
  return base64UrlToBytes(value);
}
