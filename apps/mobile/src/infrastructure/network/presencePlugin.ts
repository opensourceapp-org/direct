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
};

type UpgradeServer = {
  on(event: 'upgrade', listener: (request: IncomingMessage, socket: Duplex, head: Buffer) => void): void;
};

const servers = new WeakSet<UpgradeServer>();

function attachSignal(httpServer: UpgradeServer | null | undefined): void {
  if (!httpServer || servers.has(httpServer)) return;
  servers.add(httpServer);
  const fromPackage = path.resolve(process.cwd(), '../../infrastructure/signaling/hub.cjs');
  const fromRepo = path.resolve(process.cwd(), 'infrastructure/signaling/hub.cjs');
  const hubPath = existsSync(fromPackage) ? fromPackage : fromRepo;
  const { createSignalHub } = createRequire(path.join(process.cwd(), 'package.json'))(hubPath) as { createSignalHub: () => SignalHub };
  const hub = createSignalHub();
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

const board = new PresenceBoard();

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

/** Same-machine discovery for browser profiles that cannot see each other's BroadcastChannel. */
export function directPresencePlugin(): Plugin {
  return {
    name: 'direct-presence',
    configureServer(server) {
      attachSignal(server.httpServer);
      server.middlewares.use('/api/direct/mesh', (request, response, next) => {
        const url = new URL(request.url ?? '/', 'http://direct.local');
        const here = url.pathname === '/' || url.pathname === '/api/direct/mesh';
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
              const ok = body.op === 'hello'
                ? board.hello(String(body.peerId ?? ''), String(body.bundle ?? ''))
                : body.op === 'deliver'
                  ? board.deliver(String(body.from ?? ''), String(body.to ?? ''), String(body.payload ?? ''))
                  : false;
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
      });
    },
    configurePreviewServer(server) {
      attachSignal(server.httpServer);
    },
  };
}
