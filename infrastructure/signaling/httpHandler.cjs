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

function pathOf(request) {
  return String(request.url || '/').split('?')[0];
}

async function handleHttp(request, response) {
  const url = pathOf(request);
  const method = String(request.method || 'GET').toUpperCase();

  if (method === 'OPTIONS') {
    handleOptions(response);
    return true;
  }

  if (method === 'GET' && url === '/health') {
    sendJson(response, 200, { ok: true, service: 'direct-signaling', contract: 1 });
    return true;
  }

  if (method === 'POST' && (url === '/signal' || url === '/')) {
    let parsed;
    try {
      const raw = await readBody(request);
      parsed = raw ? JSON.parse(raw) : {};
    } catch {
      sendJson(response, 400, { error: 'Expected a JSON signaling body.' });
      return true;
    }
    if (parsed.session == null && request.headers['x-direct-session']) {
      parsed.session = String(request.headers['x-direct-session']);
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

  if (method === 'GET' && url === '/signal') {
    sendJson(response, 200, { ok: true, service: 'direct-signaling', use: 'POST JSON { session, frames, waitMs }' });
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
