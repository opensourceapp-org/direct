const SENSITIVE_KEY = /private|secret|seed|mnemonic|passphrase|plaintext|body|session|agreement|signing|ciphertext|payload|key/i;

export type LogFields = Record<string, unknown>;

export type LogEntry = {
  event: string;
  fields: LogFields;
};

export type Logger = {
  info(event: string, fields?: LogFields): void;
  warn(event: string, fields?: LogFields): void;
};

export function redact(value: unknown, depth = 0): unknown {
  if (depth > 6) return '[max-depth]';
  if (typeof value === 'string') {
    if (value.length > 180) return `[string:${value.length}]`;
    return value;
  }
  if (value instanceof Uint8Array) return `[bytes:${value.length}]`;
  if (Array.isArray(value)) return value.map((item) => redact(item, depth + 1));
  if (value && typeof value === 'object') {
    const out: LogFields = {};
    for (const [key, inner] of Object.entries(value)) {
      out[key] = SENSITIVE_KEY.test(key) ? '[redacted]' : redact(inner, depth + 1);
    }
    return out;
  }
  return value;
}

export function createLogger(sink: (entry: LogEntry) => void = () => undefined): Logger {
  const write = (event: string, fields?: LogFields) => {
    sink({ event, fields: (redact(fields ?? {}) as LogFields) });
  };
  return {
    info: write,
    warn: write,
  };
}
