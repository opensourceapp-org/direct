const { webcrypto } = require('crypto');

if (!globalThis.crypto?.getRandomValues) {
  globalThis.crypto = webcrypto;
}
