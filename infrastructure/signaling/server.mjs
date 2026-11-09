import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const require = createRequire(import.meta.url);
const { createSignalingServer } = require('./createServer.cjs');
const { handler } = require('./httpHandler.cjs');

const serverless = Boolean(process.env.VERCEL || process.env.AWS_LAMBDA_FUNCTION_NAME || process.env._HANDLER);
const launchedDirectly = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href;

if (!serverless && launchedDirectly) {
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
}

export default handler;
