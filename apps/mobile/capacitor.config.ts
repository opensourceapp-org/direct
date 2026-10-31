import type { CapacitorConfig } from '@capacitor/cli';

const config: CapacitorConfig = {
  appId: 'app.direct.messaging',
  appName: 'DIRECT',
  webDir: 'dist',
  server: {
    androidScheme: 'http',
    hostname: 'localhost',
    cleartext: true,
  },
  android: {
    allowMixedContent: true,
  },
  ios: {
    contentInset: 'automatic',
  },
};

export default config;
