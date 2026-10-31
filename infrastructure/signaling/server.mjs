import { createServer } from 'node:http';
import { createRequire } from 'node:module';
import { WebSocketServer } from 'ws';

const { createSignalHub } = createRequire(import.meta.url)('./hub.cjs');
const port = Number(process.env.PORT ?? 8787);
const hub = createSignalHub();

const server = createServer((_request, response) => {
  response.writeHead(200, { 'content-type': 'text/plain' });
  response.end('DIRECT signaling. Public bundles and session descriptions only.');
});

const wss = new WebSocketServer({ server });
wss.on('connection', (socket) => hub.attach(socket));

server.listen(port, () => {
  console.log(`DIRECT signaling listening on ${port}`);
});
