import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { networkInterfaces } from 'node:os';
import { WebSocketServer } from 'ws';

const { createSignalHub } = createRequire(import.meta.url)('./hub.cjs');
const port = Number(process.env.PORT ?? 8787);
const host = process.env.HOST ?? '0.0.0.0';
const hub = createSignalHub();

const server = createServer((request, response) => {
  if (request.url === '/health') {
    response.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    response.end(JSON.stringify({ ok: true, service: 'direct-signaling', contract: 1 }));
    return;
  }
  response.writeHead(200, { 'content-type': 'text/plain' });
  response.end('DIRECT signaling. Public bundles, presence, and WebRTC session descriptions only.\n');
});

// Native apps connect to ws://host:8787 and the web preview to /api/direct/signal; both reach one hub.
const wss = new WebSocketServer({ server, maxPayload: 80 * 1024 });
wss.on('connection', (socket) => hub.attach(socket));

server.listen(port, host, () => {
  console.log(`DIRECT signaling listening on ${host}:${port}`);
  const addresses = Object.values(networkInterfaces())
    .flat()
    .filter((entry) => entry && entry.family === 'IPv4' && !entry.internal)
    .map((entry) => entry.address);
  if (addresses.length === 0) {
    console.log('No LAN address found. Use this machine\'s public address or tunnel URL on both phones.');
    return;
  }
  console.log('Set the same bootstrap on both phones, for example:');
  for (const address of addresses) console.log(`  ws://${address}:${port}`);
});
