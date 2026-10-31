import { existsSync } from 'node:fs';
import type { IncomingMessage } from 'node:http';
import type { Duplex } from 'node:stream';
import path from 'node:path';
import { createRequire } from 'node:module';
import type { Plugin } from 'vite';
import { WebSocketServer } from 'ws';
import { PresenceBoard } from './presenceBoard';

type SignalHub = {
  attach(socket: {
    readyState: number;
    send(data: string): void;
    ping?: () => void;
    on(event: 'message', listener: (raw: unknown) => void): void;
    on(event: 'close', listener: () => void): void;
  }): void;
  remember(id: string, bundle: string): boolean;
};

type UpgradeServer = {
  on(event: 'upgrade', listener: (request: IncomingMessage, socket: Duplex, head: Buffer) => void): void;
};

const servers = new WeakSet<UpgradeServer>();
const board = new PresenceBoard();
let sharedHub: SignalHub | null = null;

function signalHub(): SignalHub {
  if (sharedHub) return sharedHub;
  const fromPackage = path.resolve(process.cwd(), '../../infrastructure/signaling/hub.cjs');
  const fromRepo = path.resolve(process.cwd(), 'infrastructure/signaling/hub.cjs');
  const hubPath = existsSync(fromPackage) ? fromPackage : fromRepo;
  const { createSignalHub } = createRequire(path.join(process.cwd(), 'package.json'))(hubPath) as {
    createSignalHub: (options?: { onHello?: (id: string, bundle: string) => void }) => SignalHub;
  };
  sharedHub = createSignalHub({
    onHello: (id, bundle) => {
      board.hello(id, bundle);
    },
  });
  return sharedHub;
}

function attachSignal(httpServer: UpgradeServer | null | undefined): void {
  if (!httpServer || servers.has(httpServer)) return;
  servers.add(httpServer);
  const hub = signalHub();
  const sockets = new WebSocketServer({ noServer: true });
  httpServer.on('upgrade', (request: IncomingMessage, socket: Duplex, head: Buffer) => {
    const pathname = new URL(request.url ?? '/', 'http://direct.local').pathname;
    if (pathname !== '/api/direct/signal') return;
    sockets.handleUpgrade(request, socket, head, (ws) => hub.attach(ws));
  });
}

type Incoming = {
  method?: string;
  url?: string;
  on(event: 'data', listener: (chunk: Buffer) => void): void;
  on(event: 'end' | 'error', listener: (error?: unknown) => void): void;
  destroy(): void;
};

function readBody(request: Incoming): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    request.on('data', (chunk: Buffer) => {
      size += chunk.length;
      if (size > 120_000) {
        reject(new Error('too large'));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    request.on('error', reject);
  });
}

type MiddlewareResponse = {
  statusCode: number;
  setHeader(name: string, value: string): void;
  end(body?: string): void;
};

type Middleware = (request: Incoming, response: MiddlewareResponse, next: () => void) => void;

/** Same-machine discovery, shared with the WebSocket bootstrap in this process. */
function meshMiddleware(): Middleware {
  return (request, response, next) => {
    const url = new URL(request.url ?? '/', 'http://direct.local');
    const here = url.pathname === '/' || url.pathname === '/api/direct/mesh';
    response.setHeader('cache-control', 'no-store');
    if (request.method === 'GET' && here) {
      const peer = url.searchParams.get('peer') ?? '';
      response.setHeader('content-type', 'application/json');
      response.end(JSON.stringify(board.pull(peer)));
      return;
    }
    if (request.method === 'POST' && here) {
      void readBody(request)
        .then((raw) => {
          const body = JSON.parse(raw) as { op?: string; peerId?: string; bundle?: string; from?: string; to?: string; payload?: string };
          let ok = false;
          if (body.op === 'hello') {
            const peerId = String(body.peerId ?? '');
            const bundle = String(body.bundle ?? '');
            ok = board.hello(peerId, bundle);
            if (ok) signalHub().remember(peerId, bundle);
          } else if (body.op === 'deliver') {
            ok = board.deliver(String(body.from ?? ''), String(body.to ?? ''), String(body.payload ?? ''));
          }
          response.statusCode = ok ? 204 : 400;
          response.end();
        })
        .catch(() => {
          response.statusCode = 400;
          response.end();
        });
      return;
    }
    next();
  };
}

/** Same-machine discovery for browser profiles that cannot see each other's BroadcastChannel. */
export function directPresencePlugin(): Plugin {
  return {
    name: 'direct-presence',
    configureServer(server) {
      attachSignal(server.httpServer);
      server.middlewares.use('/api/direct/mesh', meshMiddleware());
    },
    configurePreviewServer(server) {
      attachSignal(server.httpServer);
      server.middlewares.use('/api/direct/mesh', meshMiddleware());
    },
  };
}
