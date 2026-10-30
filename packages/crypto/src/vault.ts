export interface KeyVault {
  get(key: string): Promise<Uint8Array | null>;
  set(key: string, value: Uint8Array): Promise<void>;
  delete(key: string): Promise<void>;
}

export class MemoryKeyVault implements KeyVault {
  private readonly records = new Map<string, Uint8Array>();

  async get(key: string): Promise<Uint8Array | null> {
    const value = this.records.get(key);
    return value ? new Uint8Array(value) : null;
  }

  async set(key: string, value: Uint8Array): Promise<void> {
    this.records.set(key, new Uint8Array(value));
  }

  async delete(key: string): Promise<void> {
    this.records.delete(key);
  }
}
