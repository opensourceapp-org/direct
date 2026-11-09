const { readFileSync, existsSync } = require('node:fs');
const { join } = require('node:path');
const { exchange } = require('./httpHub.cjs');

const PAGE = join(__dirname, 'index.html');
const MAX_BODY = 80 * 1024;

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

function sendJson(response, status, body) {
  const payload = JSON.stringify(body);
  response.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'access-control-allow-origin': '*',
    'access-control-allow-headers': 'content-type, x-direct-session',
    'access-control-allow-methods': 'GET, POST, OPTIONS',
  });
  response.end(payload);
}

function handleOptions(response) {
  response.writeHead(204, {
    'access-control-allow-origin': '*',
    'access-control-allow-headers': 'content-type, x-direct-session',
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'cache-control': 'no-store',
  });
  response.end();
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
    handleOptions(response);
    return true;
  }

  if (method === 'GET' && isHealthPath(url)) {
    sendJson(response, 200, { ok: true, service: 'direct-signaling', contract: 1 });
    return true;
  }

  // Hosted apps rewrite /signal to /api, so every POST is a long-poll exchange.
  if (method === 'POST') {
    let parsed;
    try {
      const raw = await readBody(request);
      parsed = raw ? JSON.parse(raw) : {};
    } catch {
      sendJson(response, 400, { error: 'Expected a JSON signaling body.' });
      return true;
    }
    const headers = request.headers || {};
    if (parsed.session == null && (headers['x-direct-session'] || headers['X-Direct-Session'])) {
      parsed.session = String(headers['x-direct-session'] || headers['X-Direct-Session']);
    }
    try {
      const result = await exchange(parsed);
      response.setHeader('x-direct-session', result.session);
      sendJson(response, 200, result);
    } catch (error) {
      sendJson(response, 500, { error: 'Signaling is temporarily unavailable.' });
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
    sendJson(response, 200, { ok: true, service: 'direct-signaling', contract: 1 });
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
