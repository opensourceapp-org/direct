const { app, BrowserWindow, clipboard, ipcMain } = require('electron');
const path = require('path');
const { createRequire } = require('module');

const requireSignaling = createRequire(__filename);
const signalingPath = path.resolve(__dirname, '../../../infrastructure/signaling/createServer.cjs');
const { createSignalingServer } = requireSignaling(signalingPath);

let window = null;
let signaling = null;
let running = null;
let lastError = '';

function snapshot() {
  return {
    running: Boolean(running),
    port: running ? running.port : 8787,
    urls: running ? running.urls : [],
    users: signaling ? signaling.hub.roster() : [],
    error: lastError,
  };
}

async function start(requestedPort) {
  if (running) return snapshot();
  const port = Number(requestedPort) || 8787;
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    lastError = 'Use a port from 1 to 65535.';
    return snapshot();
  }
  signaling = createSignalingServer();
  try {
    const info = await signaling.listen(port, '0.0.0.0');
    running = info;
    lastError = '';
  } catch (error) {
    await signaling.close();
    signaling = null;
    running = null;
    lastError = error && error.code === 'EADDRINUSE'
      ? `Port ${port} is already in use on this computer.`
      : (error && error.message) || 'The server did not start.';
  }
  return snapshot();
}

async function stop() {
  if (signaling) await signaling.close();
  signaling = null;
  running = null;
  lastError = '';
  return snapshot();
}

function createWindow() {
  window = new BrowserWindow({
    width: 460,
    height: 720,
    minWidth: 380,
    minHeight: 560,
    backgroundColor: '#000000',
    title: 'Direct server',
    webPreferences: {
      preload: path.join(__dirname, 'preload.cjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  window.setMenuBarVisibility(false);
  window.loadFile(path.join(__dirname, 'index.html'));
}

app.whenReady().then(() => {
  ipcMain.handle('server:start', (_event, port) => start(port));
  ipcMain.handle('server:stop', () => stop());
  ipcMain.handle('server:status', () => snapshot());
  ipcMain.handle('server:copy', (_event, text) => {
    clipboard.writeText(String(text || ''));
    return true;
  });
  createWindow();
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  stop().finally(() => {
    if (process.platform !== 'darwin') app.quit();
  });
});
