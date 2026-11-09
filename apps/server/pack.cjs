const { spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const appDir = __dirname;
const signalingSrc = path.resolve(appDir, '../../infrastructure/signaling');
const signalingDest = path.join(appDir, 'build', 'signaling');

function copySignaling() {
  fs.rmSync(signalingDest, { recursive: true, force: true });
  fs.mkdirSync(signalingDest, { recursive: true });
  for (const name of ['createServer.cjs', 'hub.cjs', 'verify.cjs', 'httpHandler.cjs', 'httpHub.cjs', 'store.cjs']) {
    fs.copyFileSync(path.join(signalingSrc, name), path.join(signalingDest, name));
  }
  const serverFile = path.join(signalingDest, 'createServer.cjs');
  const rewritten = fs.readFileSync(serverFile, 'utf8').replace("require('ws')", "require('./ws')");
  if (!rewritten.includes("require('./ws')")) {
    throw new Error('Could not point the packaged server at the bundled ws module.');
  }
  fs.writeFileSync(serverFile, rewritten);
  const wsSrc = path.dirname(require.resolve('ws/package.json'));
  fs.cpSync(wsSrc, path.join(signalingDest, 'ws'), { recursive: true });
}

function builderArgs() {
  const args = process.argv.slice(2).filter((arg) => arg !== '--');
  if (!args.includes('--publish')) args.push('--publish', 'never');
  return args;
}

copySignaling();

const pnpm = process.platform === 'win32' ? 'pnpm.cmd' : 'pnpm';
const result = spawnSync(pnpm, ['exec', 'electron-builder', ...builderArgs()], {
  cwd: appDir,
  stdio: 'inherit',
  shell: process.platform === 'win32',
  env: {
    ...process.env,
    CSC_IDENTITY_AUTO_DISCOVERY: process.env.CSC_IDENTITY_AUTO_DISCOVERY || 'false',
  },
});

if (result.error) {
  console.error(result.error.message);
  process.exit(1);
}
process.exit(result.status == null ? 1 : result.status);
