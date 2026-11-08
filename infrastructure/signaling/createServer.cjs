const { createServer } = require('node:http');
const { networkInterfaces } = require('node:os');
const { WebSocketServer } = require('ws');
const { createSignalHub } = require('./hub.cjs');

function lanUrls(port) {
  return Object.values(networkInterfaces())
    .flat()
    .filter((entry) => entry && entry.family === 'IPv4' && !entry.internal)
    .map((entry) => `ws://${entry.address}:${port}`);
}

function isLoopback(address) {
  const host = String(address || '');
  return host === '127.0.0.1' || host === '::1' || host === '::ffff:127.0.0.1';
}

/**
 * The same process the phones save as their bootstrap.
 * /roster is answered only for a connection from this computer.
 */
function createSignalingServer() {
  const hub = createSignalHub();
  const server = createServer((request, response) => {
    const url = String(request.url || '/').split('?')[0];
    if (url === '/health') {
      response.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      response.end(JSON.stringify({ ok: true, service: 'direct-signaling', contract: 1 }));
      return;
    }
    if (url === '/roster') {
      if (!isLoopback(request.socket.remoteAddress)) {
        response.writeHead(403, { 'content-type': 'application/json', 'cache-control': 'no-store' });
        response.end(JSON.stringify({ error: 'The connected list is only available on this computer.' }));
        return;
      }
      response.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' });
      response.end(JSON.stringify({ users: hub.roster() }));
      return;
    }
    response.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
    response.end('DIRECT signaling. Public bundles, presence, and WebRTC session descriptions only.\n');
  });
  const wss = new WebSocketServer({ server, maxPayload: 80 * 1024 });
  wss.on('connection', (socket) => hub.attach(socket));

  function listen(port, host) {
    return new Promise((resolve, reject) => {
      const onError = (error) => {
        server.off('error', onError);
        reject(error);
      };
      server.once('error', onError);
      server.listen(port, host, () => {
        server.off('error', onError);
        const actual = server.address().port;
        resolve({ port: actual, urls: lanUrls(actual) });
      });
    });
  }

  function close() {
    for (const client of wss.clients) client.close();
    return new Promise((resolve) => {
      if (!server.listening) {
        resolve();
        return;
      }
      server.close(() => resolve());
    });
  }

  return { hub, listen, close, lanUrls };
}

module.exports = { createSignalingServer, lanUrls, isLoopback };
