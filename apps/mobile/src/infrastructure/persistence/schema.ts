export const SCHEMA_V1 = `
CREATE TABLE identities (
  id TEXT PRIMARY KEY,
  direct_id TEXT NOT NULL UNIQUE,
  did TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  public_key TEXT NOT NULL,
  signing_public_key TEXT NOT NULL,
  agreement_signature TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  device_id TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  verified INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  identity_id TEXT NOT NULL REFERENCES identities(id) ON DELETE CASCADE,
  device_id TEXT NOT NULL UNIQUE,
  label TEXT NOT NULL,
  public_key TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  revoked_at INTEGER,
  last_seen_at INTEGER
);

CREATE TABLE contacts (
  id TEXT PRIMARY KEY,
  direct_id TEXT NOT NULL UNIQUE,
  did TEXT NOT NULL,
  display_name TEXT NOT NULL,
  public_key TEXT NOT NULL,
  signing_public_key TEXT NOT NULL,
  agreement_signature TEXT NOT NULL,
  fingerprint TEXT NOT NULL,
  device_id TEXT NOT NULL,
  verified INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);

CREATE TABLE blocked_contacts (
  contact_id TEXT PRIMARY KEY REFERENCES contacts(id) ON DELETE CASCADE,
  blocked_at INTEGER NOT NULL,
  reason TEXT
);

CREATE TABLE conversations (
  id TEXT PRIMARY KEY,
  contact_id TEXT NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  last_message_preview TEXT,
  last_message_at INTEGER,
  unread_count INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE messages (
  id TEXT PRIMARY KEY,
  conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  sender_direct_id TEXT NOT NULL,
  recipient_direct_id TEXT NOT NULL,
  body TEXT NOT NULL,
  ciphertext BLOB NOT NULL,
  created_at INTEGER NOT NULL,
  status TEXT NOT NULL,
  direction TEXT NOT NULL,
  kind TEXT NOT NULL,
  transport TEXT
);

CREATE TABLE delivery_queue (
  id TEXT PRIMARY KEY,
  message_id TEXT NOT NULL UNIQUE REFERENCES messages(id) ON DELETE CASCADE,
  peer_id TEXT NOT NULL,
  payload BLOB NOT NULL,
  attempts INTEGER NOT NULL DEFAULT 0,
  next_attempt_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  created_at INTEGER NOT NULL,
  last_error TEXT
);

CREATE TABLE acknowledgements (
  id TEXT PRIMARY KEY,
  message_id TEXT NOT NULL UNIQUE,
  peer_id TEXT NOT NULL,
  signature BLOB NOT NULL,
  received_at INTEGER NOT NULL,
  verified INTEGER NOT NULL
);

CREATE TABLE encryption_sessions (
  id TEXT PRIMARY KEY,
  peer_direct_id TEXT NOT NULL UNIQUE,
  their_agreement_key TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX idx_messages_conversation ON messages(conversation_id, created_at);
CREATE INDEX idx_delivery_due ON delivery_queue(next_attempt_at);
CREATE INDEX idx_conversations_updated ON conversations(updated_at);
`;
