export const DEFAULT_BOOTSTRAP_PORT = 8787;

export type BootstrapUrlError = 'empty' | 'scheme' | 'host' | 'port' | 'userinfo' | 'query' | 'loopback';

export type BootstrapUrlResult = { ok: true; url: string } | { ok: false; error: BootstrapUrlError };

export const BOOTSTRAP_URL_MESSAGES: Record<BootstrapUrlError, string> = {
  empty: 'Enter the bootstrap address, such as ws://192.168.1.20:8787.',
  scheme: 'Use a ws:// or wss:// address.',
  host: 'The bootstrap address needs a host name or IP address, with no spaces.',
  port: 'The port must be a number from 1 to 65535.',
  userinfo: 'Remove the user name and password from the address.',
  query: 'Remove the ? or # part from the address.',
  loopback: 'localhost on a phone is the phone itself. Use the computer\'s network address, the same one on both phones.',
};

const SCHEMES: Record<string, 'ws' | 'wss'> = { ws: 'ws', wss: 'wss', http: 'ws', https: 'wss' };

/** Mirrors contracts/bootstrap-url.json. The Kotlin and Swift apps implement the same rules. */
export function normalizeBootstrapUrl(input: string, options: { allowLoopback?: boolean } = {}): BootstrapUrlResult {
  const value = input.trim();
  if (!value) return { ok: false, error: 'empty' };
  const schemeMatch = /^([A-Za-z][A-Za-z0-9+.-]*):\/\/(.*)$/.exec(value);
  const scheme = schemeMatch ? SCHEMES[schemeMatch[1]!.toLowerCase()] : 'ws';
  if (!scheme) return { ok: false, error: 'scheme' };
  const rest = schemeMatch ? schemeMatch[2]! : value;
  if (/\s/.test(rest)) return { ok: false, error: 'host' };
  if (rest.includes('?') || rest.includes('#')) return { ok: false, error: 'query' };
  const slash = rest.indexOf('/');
  const authority = slash === -1 ? rest : rest.slice(0, slash);
  let path = slash === -1 ? '' : rest.slice(slash);
  while (path.endsWith('/')) path = path.slice(0, -1);
  if (authority.includes('@')) return { ok: false, error: 'userinfo' };

  let host = '';
  let port: string | null = null;
  let bracketed = false;
  if (authority.startsWith('[')) {
    const close = authority.indexOf(']');
    if (close === -1) return { ok: false, error: 'host' };
    host = authority.slice(1, close).toLowerCase();
    bracketed = true;
    const after = authority.slice(close + 1);
    if (after.startsWith(':')) port = after.slice(1);
    else if (after) return { ok: false, error: 'host' };
    if (!/^[0-9a-f:.]+$/.test(host)) return { ok: false, error: 'host' };
  } else {
    const parts = authority.split(':');
    if (parts.length > 2) return { ok: false, error: 'host' };
    host = parts[0]!.toLowerCase();
    if (parts.length === 2) port = parts[1]!;
    if (!/^[a-z0-9.-]+$/.test(host)) return { ok: false, error: 'host' };
  }
  if (!host) return { ok: false, error: 'host' };

  let portNumber: number | null = null;
  if (port !== null) {
    if (!/^[0-9]{1,5}$/.test(port)) return { ok: false, error: 'port' };
    portNumber = Number(port);
    if (portNumber < 1 || portNumber > 65535) return { ok: false, error: 'port' };
  } else if (scheme === 'ws') {
    portNumber = DEFAULT_BOOTSTRAP_PORT;
  }

  const loopback = host === 'localhost'
    || host.endsWith('.localhost')
    || host.startsWith('127.')
    || host === '::1'
    || host === '0.0.0.0';
  if (loopback && !options.allowLoopback) return { ok: false, error: 'loopback' };

  const shownHost = bracketed ? `[${host}]` : host;
  return { ok: true, url: `${scheme}://${shownHost}${portNumber === null ? '' : `:${portNumber}`}${path}` };
}
