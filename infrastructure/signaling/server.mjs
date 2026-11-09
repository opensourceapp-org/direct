import { createRequire } from 'node:module';

const { createSignalingServer } = createRequire(import.meta.url)('./createServer.cjs');
const port = Number(process.env.PORT ?? 8787);
const host = process.env.HOST ?? '0.0.0.0';
const signaling = createSignalingServer();

signaling.listen(port, host).then((info) => {
  console.log(`DIRECT signaling listening on ${host}:${info.port}`);
  if (info.urls.length === 0) {
    console.log('No LAN address found. Use this machine\'s public address or tunnel URL on both phones.');
    return;
  }
  console.log('Set the same bootstrap on both phones, for example:');
  for (const url of info.urls) console.log(`  ${url}`);
}).catch((error) => {
  console.error(error && error.message ? error.message : error);
  process.exit(1);
});

function shutdown() {
  signaling.close().finally(() => process.exit(0));
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
