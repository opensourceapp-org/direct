const { spawn, spawnSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const appDir = __dirname;
const prepareOnly = process.argv.includes('--prepare');
const electronDir = path.join(appDir, 'node_modules', 'electron');
const installScript = path.join(electronDir, 'install.js');

function binary() {
  try {
    return require(electronDir);
  } catch {
    return '';
  }
}

function ensureBinary() {
  const existing = binary();
  if (existing && fs.existsSync(existing)) return existing;
  if (!fs.existsSync(installScript)) {
    console.error('The desktop app is not installed yet. From the DIRECT folder, run pnpm install, then pnpm server.');
    if (prepareOnly) return '';
    process.exit(1);
  }
  console.log('Downloading the Direct server app...');
  const result = spawnSync(process.execPath, [installScript], { stdio: 'inherit' });
  if (result.status !== 0) {
    console.error('The desktop app did not download. Check the network connection, then run pnpm server again.');
    process.exit(result.status || 1);
  }
  const downloaded = binary();
  if (!downloaded || !fs.existsSync(downloaded)) {
    console.error('The desktop app did not download. Check the network connection, then run pnpm server again.');
    process.exit(1);
  }
  return downloaded;
}

const executable = ensureBinary();
if (prepareOnly || !executable) process.exit(0);

const args = [];
if (process.platform === 'linux') args.push('--no-sandbox', '--disable-dev-shm-usage');
args.push(appDir);

const env = { ...process.env };
delete env.ELECTRON_RUN_AS_NODE;

const child = spawn(executable, args, { stdio: 'inherit', env, windowsHide: false });
child.on('error', (error) => {
  console.error(error && error.message ? error.message : error);
  process.exit(1);
});
child.on('exit', (code, signal) => {
  if (signal) process.exit(1);
  process.exit(code == null ? 1 : code);
});
