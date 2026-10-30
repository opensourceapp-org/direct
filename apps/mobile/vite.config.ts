import path from 'node:path';
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: [
      {
        find: /^react-native\/Libraries\/Utilities\/codegenNativeComponent$/,
        replacement: path.resolve(__dirname, 'src/shims/codegenNativeComponent.ts'),
      },
      { find: /^react-native$/, replacement: path.resolve(__dirname, 'src/shims/react-native.ts') },
      { find: '@direct/shared', replacement: path.resolve(__dirname, '../../packages/shared/src/index.ts') },
      { find: '@direct/crypto', replacement: path.resolve(__dirname, '../../packages/crypto/src/index.ts') },
      { find: '@direct/protocol', replacement: path.resolve(__dirname, '../../packages/protocol/src/index.ts') },
      { find: '@direct/transport', replacement: path.resolve(__dirname, '../../packages/transport/src/index.ts') },
    ],
    extensions: ['.web.tsx', '.web.ts', '.tsx', '.ts', '.web.jsx', '.web.js', '.jsx', '.js'],
  },
  define: {
    global: 'globalThis',
    __DEV__: JSON.stringify(true),
  },
  optimizeDeps: {
    exclude: ['react-native-svg', 'react-native-safe-area-context', 'react-native-screens'],
  },
  server: {
    host: true,
    port: 5173,
  },
});
