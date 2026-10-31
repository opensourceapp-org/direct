import { MemoryKeyVault } from '@direct/crypto';
import type { KeyVault } from '@direct/crypto';
import type { BlobStore } from '../persistence/database';

function openDb(name: string, store: string): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(name, 1);
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains(store)) request.result.createObjectStore(store);
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error('IndexedDB failed to open.'));
  });
}

function requestToPromise<T>(request: IDBRequest<T>): Promise<T> {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error ?? new Error('IndexedDB request failed.'));
  });
}

class IndexedDbVault implements KeyVault {
  constructor(
    private readonly db: IDBDatabase,
    private readonly store: string,
  ) {}

  async get(key: string): Promise<Uint8Array | null> {
    const value = await requestToPromise(this.db.transaction(this.store, 'readonly').objectStore(this.store).get(key));
    if (!value) return null;
    return value instanceof Uint8Array ? new Uint8Array(value) : new Uint8Array(value as ArrayBuffer);
  }

  async set(key: string, value: Uint8Array): Promise<void> {
    await requestToPromise(this.db.transaction(this.store, 'readwrite').objectStore(this.store).put(new Uint8Array(value), key));
  }

  async delete(key: string): Promise<void> {
    await requestToPromise(this.db.transaction(this.store, 'readwrite').objectStore(this.store).delete(key));
  }
}

class IndexedDbBlobs implements BlobStore {
  constructor(private readonly vault: IndexedDbVault) {}

  get(key: string): Promise<Uint8Array | null> {
    return this.vault.get(key);
  }

  set(key: string, value: Uint8Array): Promise<void> {
    return this.vault.set(key, value);
  }
}

export async function openBrowserVault(): Promise<KeyVault> {
  if (typeof indexedDB === 'undefined') return new MemoryKeyVault();
  return new IndexedDbVault(await openDb('direct-vault', 'secrets'), 'secrets');
}

export async function openBrowserBlobs(): Promise<BlobStore> {
  if (typeof indexedDB === 'undefined') {
    const { MemoryBlobStore } = await import('../persistence/database');
    return new MemoryBlobStore();
  }
  const vault = new IndexedDbVault(await openDb('direct-files', 'blobs'), 'blobs');
  return new IndexedDbBlobs(vault);
}
