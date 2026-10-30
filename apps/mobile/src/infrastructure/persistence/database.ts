import { openDatabase, sealDatabase, MemoryKeyVault } from '@direct/crypto';
import type { KeyVault } from '@direct/crypto';
import { randomBytes } from '@direct/shared';
import { SCHEMA_V1 } from './schema';

const DB_KEY = 'db.encryption.key';
const DB_BLOB = 'direct.sqlite';

export interface BlobStore {
  get(key: string): Promise<Uint8Array | null>;
  set(key: string, value: Uint8Array): Promise<void>;
}

export class MemoryBlobStore implements BlobStore {
  private readonly records = new Map<string, Uint8Array>();

  async get(key: string): Promise<Uint8Array | null> {
    const value = this.records.get(key);
    return value ? new Uint8Array(value) : null;
  }

  async set(key: string, value: Uint8Array): Promise<void> {
    this.records.set(key, new Uint8Array(value));
  }
}

export type SqlStatement = {
  bind(values: unknown[]): boolean | void;
  step(): boolean;
  getAsObject(): Record<string, SqlValue>;
  free(): void;
};

export type SqlValue = string | number | Uint8Array | null | bigint;

export type SqlDatabase = {
  run(sql: string, params?: unknown[]): void;
  exec(sql: string): void;
  prepare(sql: string): SqlStatement;
  export(): Uint8Array;
  close(): void;
};

type SqlModule = {
  Database: new (data?: ArrayLike<number> | Buffer | null) => SqlDatabase;
};

export async function loadSql(wasmBinary: Uint8Array): Promise<SqlModule> {
  const imported = await import('sql.js');
  const initSqlJs = (imported.default ?? imported) as (config?: { wasmBinary?: ArrayBuffer }) => Promise<SqlModule>;
  return initSqlJs({ wasmBinary: wasmBinary.buffer.slice(wasmBinary.byteOffset, wasmBinary.byteOffset + wasmBinary.byteLength) as ArrayBuffer });
}

export class EncryptedDatabase {
  private depth = 0;
  private dirty = false;

  constructor(
    readonly raw: SqlDatabase,
    private readonly key: Uint8Array,
    private readonly blobs: BlobStore,
  ) {}

  transaction<T>(work: () => T): T {
    const outer = this.depth === 0;
    if (outer) this.raw.run('BEGIN');
    this.depth += 1;
    try {
      const result = work();
      this.depth -= 1;
      if (outer) {
        this.raw.run('COMMIT');
        this.dirty = true;
      }
      return result;
    } catch (error) {
      this.depth -= 1;
      if (outer) this.raw.run('ROLLBACK');
      throw error;
    }
  }

  run(sql: string, params: unknown[] = []): void {
    this.raw.run(sql, params);
  }

  all(sql: string, params: unknown[] = []): Record<string, SqlValue>[] {
    const statement = this.raw.prepare(sql);
    statement.bind(params);
    const rows: Record<string, SqlValue>[] = [];
    while (statement.step()) rows.push(statement.getAsObject());
    statement.free();
    return rows;
  }

  one(sql: string, params: unknown[] = []): Record<string, SqlValue> | null {
    return this.all(sql, params)[0] ?? null;
  }

  async save(): Promise<Uint8Array> {
    const sealed = sealDatabase(this.key, this.raw.export());
    await this.blobs.set(DB_BLOB, sealed);
    this.dirty = false;
    return sealed;
  }

  get isDirty(): boolean {
    return this.dirty;
  }
}

export async function openEncryptedDatabase(options: {
  wasmBinary: Uint8Array;
  vault: KeyVault;
  blobs: BlobStore;
  now?: number;
}): Promise<EncryptedDatabase> {
  const SQL = await loadSql(options.wasmBinary);
  let key = await options.vault.get(DB_KEY);
  const existing = await options.blobs.get(DB_BLOB);
  if (!key) {
    if (existing) throw new Error('The local database is locked and this device has no key for it.');
    key = randomBytes(32);
    await options.vault.set(DB_KEY, key);
  }
  const raw = existing ? new SQL.Database(openDatabase(key, existing)) : new SQL.Database();
  raw.run('PRAGMA foreign_keys = ON');
  migrate(raw, options.now ?? Date.now());
  const database = new EncryptedDatabase(raw, key, options.blobs);
  await database.save();
  return database;
}

function migrate(raw: SqlDatabase, now: number): void {
  raw.run('CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)');
  const current = Number((() => {
    const statement = raw.prepare('SELECT COALESCE(MAX(version), 0) AS version FROM schema_migrations');
    statement.bind([]);
    statement.step();
    const version = Number(statement.getAsObject().version ?? 0);
    statement.free();
    return version;
  })());
  if (current >= 1) return;
  raw.run('BEGIN');
  try {
    raw.exec(SCHEMA_V1);
    raw.run('INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)', [1, now]);
    raw.run('COMMIT');
  } catch (error) {
    raw.run('ROLLBACK');
    throw error;
  }
}

export { MemoryKeyVault };
