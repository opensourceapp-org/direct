const { readFileSync, existsSync } = require('node:fs');
const { isIP } = require('node:net');
const { join } = require('node:path');
const { exchange, SignalingAuthError, getStore } = require('./httpHub.cjs');

const PAGE = join(__dirname, 'index.html');
const MAX_BODY = 80 * 1024;
const POST_WINDOW_MS = 10_000;
const MAX_POSTS_PER_WINDOW = 40;
const MAX_NEW_SESSIONS_PER_WINDOW = 10;

function readBody(request) {
  if (typeof request.body === 'string') return Promise.resolve(request.body);
  if (Buffer.isBuffer(request.body)) return Promise.resolve(request.body.toString('utf8'));
  if (request.body && typeof request.body === 'object' && !request.readable) {
    return Promise.resolve(JSON.stringify(request.body));
  }
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    request.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY) {
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

function requestHost(request) {
  const forwarded = headerValue(request, 'x-forwarded-host').split(',')[0].trim();
  const host = forwarded || headerValue(request, 'host');
  return host.split(':')[0].trim().toLowerCase();
}

function corsOrigin(request) {
  const origin = headerValue(request, 'origin');
  if (!origin) return null;
  try {
    const parsed = new URL(origin);
    const host = parsed.hostname.toLowerCase();
    const localHttp = parsed.protocol === 'http:' && (host === 'localhost' || host === '127.0.0.1');
    if (localHttp) return origin;
    if (parsed.protocol !== 'https:') return null;
    const expected = requestHost(request);
    if (expected && host === expected) return origin;
  } catch {
    // Ignore malformed Origin. Native phones send none.
  }
  return null;
}

function corsHeaders(request) {
  const headers = {
    'access-control-allow-headers': 'content-type, x-direct-session, x-direct-token',
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    vary: 'origin',
  };
  const allowed = corsOrigin(request);
  if (allowed) headers['access-control-allow-origin'] = allowed;
  return headers;
}

function sendJson(request, response, status, body) {
  const payload = JSON.stringify(body);
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    ...corsHeaders(request),
  });
  response.end(payload);
}

function handleOptions(request, response) {
  response.writeHead(204, {
    'cache-control': 'no-store',
    ...corsHeaders(request),
  });
  response.end();
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

function requestIp(request) {
  const peer = normalizeIp(request.socket && request.socket.remoteAddress);
  const forwarded = String(headerValue(request, 'x-forwarded-for') || '')
    .split(',')
    .map((part) => normalizeIp(part))
    .filter((part) => isIP(part) === 4 || isIP(part) === 6);
  if (peer && !isLoopback(peer)) return peer;
  for (let i = forwarded.length - 1; i >= 0; i -= 1) {
    if (!isLoopback(forwarded[i])) return forwarded[i];
  }
  if (forwarded[0]) return forwarded[0];
  return peer || 'unknown';
}

async function tooManyPosts(ip, isNewSession) {
  const store = await getStore();
  return store.hitRate(ip, isNewSession, POST_WINDOW_MS, MAX_POSTS_PER_WINDOW, MAX_NEW_SESSIONS_PER_WINDOW);
}

function headerValue(request, name) {
  const headers = request.headers || {};
  const value = headers[name] || headers[name.toLowerCase()];
  if (Array.isArray(value)) return String(value[0] || '');
  return String(value || '');
}

function normalizePath(value) {
  let path = String(value || '').trim();
  if (!path) return '';
  if (/^https?:\/\//i.test(path)) {
    try {
      path = new URL(path).pathname;
    } catch {
      path = path.replace(/^https?:\/\/[^/]+/i, '') || '/';
    }
  }
  path = path.split('?')[0];
  if (!path.startsWith('/')) path = `/${path}`;
  if (path.length > 1) path = path.replace(/\/+$/, '');
  return path;
}

function isFunctionPath(path) {
  return path === '/api' || path === '/index.js' || path === '/api/index' || path === '/api/index.js';
}

function pathOf(request) {
  const candidates = [
    request.url,
    headerValue(request, 'x-forwarded-uri'),
    headerValue(request, 'x-invoke-path'),
    headerValue(request, 'x-matched-path'),
    headerValue(request, 'x-vercel-original-path'),
  ]
    .map(normalizePath)
    .filter(Boolean);
  const original = candidates.find((path) => !isFunctionPath(path));
  return original || candidates[0] || '/';
}

function isHealthPath(url) {
  return url === '/health' || url.endsWith('/health');
}

async function handleHttp(request, response) {
  const url = pathOf(request);
  const method = String(request.method || 'GET').toUpperCase();

  if (method === 'OPTIONS') {
    handleOptions(request, response);
    return true;
  }

  if (method === 'GET' && isHealthPath(url)) {
    sendJson(request, response, 200, { ok: true, service: 'direct-signaling', contract: 1 });
    return true;
  }

  // Hosted apps rewrite /signal to /api, so every POST is a long-poll exchange.
  if (method === 'POST') {
    let parsed;
    try {
      const raw = await readBody(request);
      parsed = raw ? JSON.parse(raw) : {};
    } catch {
      sendJson(request, response, 400, { error: 'Expected a JSON signaling body.' });
      return true;
    }
    const headers = request.headers || {};
    if (parsed.session == null && (headers['x-direct-session'] || headers['X-Direct-Session'])) {
      parsed.session = String(headers['x-direct-session'] || headers['X-Direct-Session']);
    }
    if (parsed.token == null && (headers['x-direct-token'] || headers['X-Direct-Token'])) {
      parsed.token = String(headers['x-direct-token'] || headers['X-Direct-Token']);
    }
    const ip = requestIp(request);
    const isNewSession = !parsed.session;
    if (await tooManyPosts(ip, isNewSession)) {
      sendJson(request, response, 429, { error: 'Too many signaling requests. Try again shortly.' });
      return true;
    }
    try {
      const result = await exchange(parsed);
      response.setHeader('x-direct-session', result.session);
      sendJson(request, response, 200, result);
    } catch (error) {
      if (error instanceof SignalingAuthError || error.status === 401) {
        sendJson(request, response, 401, { error: 'That signaling session is not valid.' });
        return true;
      }
      sendJson(request, response, 500, { error: 'Signaling is temporarily unavailable.' });
      console.error(error && error.message ? error.message : error);
    }
    return true;
  }

  if (method === 'GET' && (url === '/' || url === '/index.html') && existsSync(PAGE)) {
    response.writeHead(200, {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
    });
    response.end(readFileSync(PAGE));
    return true;
  }

  if (method === 'GET') {
    sendJson(request, response, 200, { ok: true, service: 'direct-signaling', contract: 1 });
    return true;
  }

  return false;
}

async function handler(request, response) {
  const handled = await handleHttp(request, response);
  if (handled) return;
  response.writeHead(200, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' });
  response.end('DIRECT signaling. Public bundles, presence, and WebRTC session descriptions only.\n');
}

module.exports = { handleHttp, handler };
