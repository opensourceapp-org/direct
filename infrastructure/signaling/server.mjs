import { createServer } from 'node:http';
import { WebSocketServer } from 'ws';

const port = Number(process.env.PORT ?? 8787);
const sockets = new Map();

const server = createServer((_request, response) => {
  response.writeHead(200, { 'content-type': 'text/plain' });
  response.end('DIRECT signaling. Session descriptions only.');
});

const wss = new WebSocketServer({ server });

wss.on('connection', (socket) => {
  let selfId = '';
  socket.on('message', (raw) => {
    let message;
    try {
      message = JSON.parse(String(raw));
    } catch {
      return;
    }
    if (message.kind === 'hello' && typeof message.from === 'string') {
      selfId = message.from;
      sockets.set(selfId, socket);
      return;
    }
    if (!['offer', 'answer', 'ice'].includes(message.kind)) return;
    const encoded = JSON.stringify(message);
    if (encoded.length > 64 * 1024) return;
    const target = sockets.get(message.to);
    if (target && target.readyState === 1) target.send(encoded);
  });
  socket.on('close', () => {
    if (selfId && sockets.get(selfId) === socket) sockets.delete(selfId);
  });
});

server.listen(port, () => {
  console.log(`DIRECT signaling listening on ${port}`);
});
