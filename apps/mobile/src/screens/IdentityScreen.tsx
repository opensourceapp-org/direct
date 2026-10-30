import { ScrollView, View } from 'react-native';
import { Badge, Button, Text } from '../components/ui/system';
import { useToast } from '../components/ui/system';
import { QrCode } from '../components/QrCode';
import { useAppStore } from '../stores/appStore';
import { useTheme } from '../theme/ThemeProvider';

export function IdentityScreen() {
  const theme = useTheme();
  const identity = useAppStore((state) => state.identity);
  const toast = useToast();
  if (!identity) return null;
  const copy = async () => {
    const clipboard = navigator.clipboard;
    if (!clipboard) {
      toast('Copy is not available in this browser.');
      return;
    }
    await clipboard.writeText(identity.directId);
    toast('DIRECT ID copied.');
  };
  return (
    <ScrollView style={{ flex: 1, backgroundColor: theme.background }} contentContainerStyle={{ padding: 20, gap: 16, maxWidth: 720 }}>
      <View style={{ flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
        <Text variant="title">{identity.displayName}</Text>
        <Badge label="Verified on this device" />
      </View>
      <Text tone="muted">Private keys are not shown. Share the QR code or the DIRECT ID. Ask the other person to compare the fingerprint.</Text>
      <View style={{ borderWidth: 1, borderColor: theme.border, borderRadius: 8, padding: 16, alignSelf: 'flex-start' }}>
        <QrCode value={identity.bundle} />
      </View>
      <Field label="DIRECT ID" value={identity.directId} />
      <Field label="DID" value={identity.did} />
      <Field label="Fingerprint" value={identity.fingerprint} />
      <Field label="Device ID" value={identity.deviceId} />
      <Button label="Copy DIRECT ID" variant="secondary" onPress={() => void copy()} />
    </ScrollView>
  );
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <View style={{ gap: 4 }}>
      <Text variant="meta" tone="muted">{label}</Text>
      <Text variant="label">{value}</Text>
    </View>
  );
}
