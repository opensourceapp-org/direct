import { useEffect, useState } from 'react';
import { View } from 'react-native';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { ThemeProvider, useTheme } from '../theme/ThemeProvider';
import { Skeleton, Text, ToastProvider } from '../components/ui/system';
import { DirectContext } from './context';
import { bootDirect, type DirectController } from './controller';
import { RootNavigator } from '../navigation/RootNavigator';
import { useAppStore } from '../stores/appStore';

export function App({ wasmBinary }: { wasmBinary?: Uint8Array }) {
  const [controller, setController] = useState<DirectController | null>(null);

  useEffect(() => {
    if (!wasmBinary) {
      useAppStore.getState().setBooting(false, 'No local database opener is linked for this runtime.');
      return undefined;
    }
    let live = true;
    bootDirect(wasmBinary)
      .then((ready) => {
        if (live) setController(ready);
      })
      .catch((error: unknown) => {
        useAppStore.getState().setBooting(false, error instanceof Error ? error.message : 'DIRECT failed to open its database.');
      });
    return () => {
      live = false;
    };
  }, [wasmBinary]);

  const bootError = useAppStore((state) => state.bootError);
  const booting = useAppStore((state) => state.booting);

  return (
    <SafeAreaProvider>
      <ThemeProvider>
        <ToastProvider>
          <View style={{ flex: 1 }}>
            {bootError ? <BootMessage message={bootError} /> : null}
            {!bootError && controller && !booting ? (
              <DirectContext.Provider value={controller}>
                <RootNavigator />
              </DirectContext.Provider>
            ) : null}
            {!bootError && (!controller || booting) ? <BootScreen /> : null}
          </View>
        </ToastProvider>
      </ThemeProvider>
    </SafeAreaProvider>
  );
}

function BootScreen() {
  const theme = useTheme();
  return (
    <View style={{ flex: 1, backgroundColor: theme.background, padding: 24, gap: 12, justifyContent: 'center' }}>
      <Skeleton width={88} height={12} />
      <Skeleton width="70%" height={28} />
      <Skeleton width="46%" height={12} />
    </View>
  );
}

function BootMessage({ message }: { message: string }) {
  const theme = useTheme();
  return (
    <View style={{ flex: 1, backgroundColor: theme.background, padding: 24, justifyContent: 'center', gap: 8 }}>
      <Text variant="heading">DIRECT could not start</Text>
      <Text tone="muted">{message}</Text>
    </View>
  );
}
