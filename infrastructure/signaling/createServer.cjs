const { createServer } = require('node:http');
const { isIP } = require('node:net');
const { networkInterfaces } = require('node:os');
const { WebSocketServer } = require('ws');
const { createSignalHub } = require('./hub.cjs');
const { handleHttp } = require('./httpHandler.cjs');

function lanUrls(port) {
  return Object.values(networkInterfaces())
    .flat()
    .filter((entry) => entry && entry.family === 'IPv4' && !entry.internal)
    .map((entry) => `ws://${entry.address}:${port}`);
}

function normalizeIp(address) {
  let host = String(address || '').trim().toLowerCase();
  if (host.startsWith('[') && host.endsWith(']')) host = host.slice(1, -1);
  if (host.startsWith('::ffff:') && isIP(host.slice(7)) === 4) return host.slice(7);
  return host;
}

function isLoopback(address) {
  const host = normalizeIp(address);
  if (host === '::1') return true;
  if (isIP(host) === 4) return host.split('.')[0] === '127';
  return false;
}

const MAX_CONNECTIONS = 2048;
const MAX_PER_IP = 16;
const CONNECT_WINDOW_MS = 10_000;
const MAX_CONNECTS_PER_WINDOW = 10;

function originAllowed(origin, request) {
  if (!origin) return true;
  let parsed;
  try {
    parsed = new URL(origin);
  } catch {
    return false;
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return false;
  const requestHost = String(request.headers.host || '').split(':')[0].toLowerCase();
  const originHost = parsed.hostname.toLowerCase();
  if (!requestHost || originHost !== requestHost) return false;
  return true;
}

function forwardedIps(value) {
  return String(value || '')
    .split(',')
    .map((part) => normalizeIp(part))
    .filter((part) => isIP(part) === 4 || isIP(part) === 6);
}

function clientIp(request) {
  const peer = normalizeIp(request.socket.remoteAddress) || 'unknown';
  // Only a local reverse proxy can tell us the public client address.
  // Direct callers can send any X-Forwarded-For value, so ignore it there.
  if (!isLoopback(peer)) return peer;
  const chain = forwardedIps(request.headers['x-forwarded-for']);
  for (let i = chain.length - 1; i >= 0; i -= 1) {
    if (!isLoopback(chain[i])) return chain[i];
  }
  return peer;
}

/**
 * The same process the phones save as their bootstrap.
 * /roster is answered only for a connection from this computer.
 */
function createSignalingServer() {
  const hub = createSignalHub();
  const server = createServer((request, response) => {
    const url = String(request.url || '/').split('?')[0];
    if (url !== '/roster') {
      handleHttp(request, response).then((handled) => {
        if (handled) return;
        response.writeHead(200, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' });
        response.end('DIRECT signaling. Public bundles, presence, and WebRTC session descriptions only.\n');
      }).catch(() => {
        if (!response.headersSent) {
          response.writeHead(500, { 'content-type': 'application/json', 'cache-control': 'no-store' });
          response.end(JSON.stringify({ error: 'Signaling is temporarily unavailable.' }));
        }
      });
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
    }
  });
  const ipConnections = new Map();
  const connectTimes = new Map();
  let total = 0;

  function tooManyConnects(ip) {
    const at = Date.now();
    const recent = (connectTimes.get(ip) || []).filter((time) => at - time < CONNECT_WINDOW_MS);
    recent.push(at);
    connectTimes.set(ip, recent);
    return recent.length > MAX_CONNECTS_PER_WINDOW;
  }

  const wss = new WebSocketServer({
    server,
    maxPayload: 80 * 1024,
    verifyClient(info, done) {
      if (!originAllowed(info.origin, info.req)) {
        done(false, 403, 'origin not allowed');
        return;
      }
      const ip = clientIp(info.req);
      if (total >= MAX_CONNECTIONS || (ipConnections.get(ip) || 0) >= MAX_PER_IP || tooManyConnects(ip)) {
        done(false, 429, 'too many connections');
        return;
      }
      done(true);
    },
  });
  wss.on('connection', (socket, request) => {
    const ip = clientIp(request);
    total += 1;
    ipConnections.set(ip, (ipConnections.get(ip) || 0) + 1);
    socket.on('close', () => {
      total = Math.max(0, total - 1);
      const next = (ipConnections.get(ip) || 1) - 1;
      if (next <= 0) ipConnections.delete(ip);
      else ipConnections.set(ip, next);
    });
    hub.attach(socket);
  });

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

module.exports = {
  createSignalingServer,
  lanUrls,
  isLoopback,
  originAllowed,
  clientIp,
  MAX_CONNECTIONS,
  MAX_PER_IP,
  MAX_CONNECTS_PER_WINDOW,
};
