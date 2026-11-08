const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('directServer', {
  start: (port) => ipcRenderer.invoke('server:start', port),
  stop: () => ipcRenderer.invoke('server:stop'),
  status: () => ipcRenderer.invoke('server:status'),
  copy: (text) => ipcRenderer.invoke('server:copy', text),
});
