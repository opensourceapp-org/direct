import { useEffect, useState } from 'react';
import { ScrollView, View } from 'react-native';
import { Button, Divider, Input, StatusIndicator, Text } from '../components/ui/system';
import { useDirect } from '../app/context';
import { useAppStore } from '../stores/appStore';
import { useTheme } from '../theme/ThemeProvider';
import { formatWhen } from '../app/format';

export function NetworkScreen() {
  const theme = useTheme();
  const network = useAppStore((state) => state.network);
  const rows: { label: string; value: string; tone: 'neutral' | 'success' | 'warning' | 'accent' | 'danger' }[] = [
    { label: 'Network', value: network.online ? 'Online' : 'Offline', tone: network.online ? 'success' : 'danger' },
    { label: 'Direct connection', value: network.directAvailable ? 'Available' : 'Unavailable', tone: 'success' },
    { label: 'Active transport', value: network.activeTransport, tone: 'neutral' },
    { label: 'Peer discovery', value: network.discovery, tone: 'neutral' },
    { label: 'Bootstrap', value: network.bootstrap, tone: network.discovery === 'Shared bootstrap' ? 'success' : 'neutral' },
    { label: 'Connected peers', value: String(network.peers), tone: network.peers > 0 ? 'success' : 'neutral' },
    { label: 'Kademlia records', value: String(network.kadPeers), tone: 'neutral' },
    { label: 'Relay', value: network.relay, tone: network.relay.startsWith('Off') ? 'neutral' : 'accent' },
    { label: 'Last successful connection', value: network.lastSuccess ? formatWhen(network.lastSuccess) : 'None on this session', tone: 'neutral' },
    { label: 'Network type', value: network.networkType, tone: 'neutral' },
  ];
  return (
    <ScrollView style={{ flex: 1, backgroundColor: theme.background }} contentContainerStyle={{ padding: 20, gap: 20, maxWidth: 760 }}>
      <View style={{ gap: 6 }}>
        <Text variant="meta" tone="muted">DIAGNOSTICS</Text>
        <Text variant="title">Network</Text>
        <Text tone="muted">Direct paths are preferred. Relay acceptance is not delivery.</Text>
      </View>
      <View style={{ borderWidth: 1, borderColor: theme.border, borderRadius: 8 }}>
        {rows.map((row, index) => { const { label, value, tone } = row; return (
          <View key={label}>
            {index > 0 ? <Divider /> : null}
            <View style={{ flexDirection: 'row', justifyContent: 'space-between', gap: 16, paddingHorizontal: 14, paddingVertical: 12, alignItems: 'center' }}>
              <Text variant="label" tone="muted">{label}</Text>
              <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, flexShrink: 1 }}>
                <StatusIndicator tone={tone} />
                <Text variant="label" style={{ textAlign: 'right' }}>{value}</Text>
              </View>
            </View>
          </View>
        ); })}
      </View>
      <View style={{ gap: 8 }}>
        <Text variant="label">Recent route attempts</Text>
        <View style={{ flexDirection: 'row', alignItems: 'flex-end', gap: 4, height: 36 }}>
          {(network.attempts.length ? network.attempts : [false, false, false, false, false, false]).map((attempt, index) => {
            const ok = typeof attempt === 'boolean' ? attempt : attempt.ok;
            return <View key={index} style={{ width: 8, height: ok ? 28 : 10, backgroundColor: ok ? theme.foreground : theme.border }} />;
          })}
        </View>
        <Text variant="meta" tone="muted">Filled bars are successful direct or relay handoffs. A handoff is not an acknowledgement.</Text>
      </View>
      <BootstrapField />
      <View style={{ gap: 6 }}>
        <Text variant="label">libp2p</Text>
        <Text tone="muted">{network.libp2p}</Text>
      </View>
    </ScrollView>
  );
}

function BootstrapField() {
  const direct = useDirect();
  const saved = useAppStore((state) => state.preferences.signalingUrl);
  const [value, setValue] = useState(saved);
  useEffect(() => setValue(saved), [saved]);
  return (
    <View style={{ gap: 8 }}>
      <Text variant="label">Bootstrap address</Text>
      <Text tone="muted">Two phones use one bootstrap. This field already has the public signaling server. Paste a different address only if both phones should use your own server. The bootstrap learns who is online and forwards session descriptions. It does not receive message text.</Text>
      <Input value={value} onChangeText={setValue} placeholder="wss://direct-signaling.apps.grok.bot" />
      <Button label="Use this bootstrap" variant="secondary" onPress={() => direct.updatePreferences({ signalingUrl: value.trim() })} />
    </View>
  );
}
