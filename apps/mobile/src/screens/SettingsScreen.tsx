import { useState } from 'react';
import { Pressable, ScrollView, View } from 'react-native';
import { useNavigation, useRoute } from '@react-navigation/native';
import type { RouteProp } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { Button, Dialog, Divider, Input, Text } from '../components/ui/system';
import { useToast } from '../components/ui/system';
import { useDirect } from '../app/context';
import { useAppStore } from '../stores/appStore';
import { useTheme } from '../theme/ThemeProvider';
import type { RootStackParamList, SettingsSectionId } from '../navigation/types';

const SECTIONS: { id: SettingsSectionId; label: string; detail: string }[] = [
  { id: 'profile', label: 'Profile and identity', detail: 'Name, DIRECT ID, fingerprint' },
  { id: 'devices', label: 'Device management', detail: 'This device and revocation' },
  { id: 'security', label: 'Security', detail: 'Key rotation and verification' },
  { id: 'privacy', label: 'Privacy', detail: 'What never leaves the device' },
  { id: 'appearance', label: 'Appearance', detail: 'Light, dark, or system' },
  { id: 'background', label: 'Background delivery', detail: 'Retries while the app may run' },
  { id: 'relay', label: 'Relay preferences', detail: 'Optional ciphertext fallback' },
  { id: 'storage', label: 'Storage', detail: 'Local database size' },
  { id: 'recovery', label: 'Identity recovery', detail: 'The phrase that restores you' },
  { id: 'about', label: 'About DIRECT', detail: 'No Middlemen. Just Connection.' },
];

export function SettingsScreen() {
  const theme = useTheme();
  const navigation = useNavigation<NativeStackNavigationProp<RootStackParamList>>();
  return (
    <ScrollView style={{ flex: 1, backgroundColor: theme.background }}>
      <View style={{ paddingHorizontal: 16, paddingTop: 18, paddingBottom: 12 }}>
        <Text variant="heading">Settings</Text>
      </View>
      <Divider />
      {SECTIONS.map((section) => (
        <Pressable
          key={section.id}
          accessibilityRole="button"
          onPress={() => navigation.navigate('Section', { id: section.id })}
          style={({ pressed }) => [{ paddingHorizontal: 16, paddingVertical: 14, backgroundColor: pressed ? theme.surface : theme.background, borderBottomWidth: 1, borderColor: theme.border }]}
        >
          <Text variant="label">{section.label}</Text>
          <Text variant="meta" tone="muted">{section.detail}</Text>
        </Pressable>
      ))}
    </ScrollView>
  );
}

export function SettingsSectionScreen() {
  const route = useRoute<RouteProp<RootStackParamList, 'Section'>>();
  const id = route.params.id;
  return (
    <ScrollView style={{ flex: 1 }} contentContainerStyle={{ padding: 20, gap: 16, maxWidth: 680 }}>
      {id === 'profile' ? <ProfileSection /> : null}
      {id === 'devices' ? <DevicesSection /> : null}
      {id === 'security' ? <SecuritySection /> : null}
      {id === 'privacy' ? <PrivacySection /> : null}
      {id === 'appearance' ? <AppearanceSection /> : null}
      {id === 'background' ? <BackgroundSection /> : null}
      {id === 'relay' ? <RelaySection /> : null}
      {id === 'storage' ? <StorageSection /> : null}
      {id === 'recovery' ? <RecoverySection /> : null}
      {id === 'about' ? <AboutSection /> : null}
    </ScrollView>
  );
}

function ProfileSection() {
  const direct = useDirect();
  const navigation = useNavigation<NativeStackNavigationProp<RootStackParamList>>();
  const identity = useAppStore((state) => state.identity);
  const [name, setName] = useState(identity?.displayName ?? '');
  return (
    <View style={{ gap: 12 }}>
      <Text variant="title">Profile and identity</Text>
      <Input value={name} onChangeText={setName} placeholder="Name" autoCapitalize="words" />
      <Button label="Save name" onPress={() => void direct.rename(name)} />
      <Button label="View identity" variant="secondary" onPress={() => navigation.navigate('Identity')} />
    </View>
  );
}

function DevicesSection() {
  const direct = useDirect();
  const identity = useAppStore((state) => state.identity);
  const [open, setOpen] = useState(false);
  return (
    <View style={{ gap: 12 }}>
      <Text variant="title">Devices</Text>
      <Text tone="muted">This build is one device. Revoking it marks the device record and drops local session notes. It does not delete your recovery phrase.</Text>
      <Text variant="label">{identity?.deviceId}</Text>
      <Button label="Revoke this device record" variant="danger" onPress={() => setOpen(true)} />
      <Dialog
        visible={open}
        title="Revoke this device record?"
        body="Contacts will need to refresh your agreement key if you rotate after revocation. The recovery phrase still restores the signing identity."
        confirmLabel="Revoke"
        danger
        onClose={() => setOpen(false)}
        onConfirm={() => {
          void direct.revokeCurrentDevice();
          setOpen(false);
        }}
      />
    </View>
  );
}

function SecuritySection() {
  const direct = useDirect();
  const toast = useToast();
  return (
    <View style={{ gap: 12 }}>
      <Text variant="title">Security</Text>
      <Text tone="muted">
        Each message uses a fresh X25519 key and AES-256-GCM from audited libraries. Rotating the agreement key keeps your DIRECT ID and keeps the previous key long enough to open messages already sealed to it. This build does not bundle the Double Ratchet. Native releases are expected to plug libsignal in behind the same cipher boundary.
      </Text>
      <Button
        label="Rotate agreement key"
        onPress={() => void direct.rotateAgreement().then(() => toast('Agreement key rotated.'))}
      />
    </View>
  );
}

function PrivacySection() {
  return (
    <View style={{ gap: 12 }}>
      <Text variant="title">Privacy</Text>
      <Text>Logs record message identifiers and statuses. They do not record message text, recovery phrases, or private keys.</Text>
      <Text>The local database is sealed with AES-256-GCM. On iOS and Android the database key is intended for the Keychain and the Keystore. This browser keeps that key in the browser profile.</Text>
      <Text>There is no central message store.</Text>
    </View>
  );
}

function AppearanceSection() {
  const direct = useDirect();
  const themeName = useAppStore((state) => state.preferences.theme);
  return (
    <View style={{ gap: 12 }}>
      <Text variant="title">Appearance</Text>
      <View style={{ flexDirection: 'row', gap: 8 }}>
        {(['system', 'light', 'dark'] as const).map((mode) => (
          <Button key={mode} label={mode[0]?.toUpperCase() + mode.slice(1)} variant={themeName === mode ? 'primary' : 'secondary'} onPress={() => direct.updatePreferences({ theme: mode })} />
        ))}
      </View>
    </View>
  );
}

function BackgroundSection() {
  const direct = useDirect();
  const enabled = useAppStore((state) => state.preferences.backgroundDelivery);
  return (
    <View style={{ gap: 12 }}>
      <Text variant="title">Background delivery</Text>
      <Text tone="muted">
        While DIRECT is open, the queue retries every few seconds. iOS may suspend that work; the queue runs again when the app becomes active. Android can schedule the same flush with WorkManager. This browser retries when the tab is visible and, if you leave this on, also while it is in the background.
      </Text>
      <Button label={enabled ? 'Pause background retries' : 'Allow background retries'} variant="secondary" onPress={() => direct.updatePreferences({ backgroundDelivery: !enabled })} />
    </View>
  );
}

function RelaySection() {
  const direct = useDirect();
  const preferences = useAppStore((state) => state.preferences);
  const [disclose, setDisclose] = useState(false);
  return (
    <View style={{ gap: 12 }}>
      <Text variant="title">Relay</Text>
      <Text tone="muted">Direct delivery stays first. A relay only forwards ciphertext. Turning it on does not mark messages delivered.</Text>
      <Button
        label={preferences.relayEnabled ? 'Turn relay off' : 'Turn relay on'}
        onPress={() => direct.updatePreferences({ relayEnabled: !preferences.relayEnabled })}
      />
      <Button
        label={preferences.relayStorage ? 'Turn temporary storage off' : 'Allow temporary storage'}
        variant="secondary"
        disabled={!preferences.relayEnabled || preferences.relayStorage}
        onPress={() => setDisclose(true)}
      />
      {preferences.relayStorage ? (
        <Button label="Turn temporary storage off" variant="danger" onPress={() => direct.updatePreferences({ relayStorage: false })} />
      ) : null}
      <Dialog
        visible={disclose}
        title="Store ciphertext temporarily?"
        body="Participating devices may keep encrypted payloads until they expire or the recipient connects. They cannot read them. A stored payload is not a delivery receipt. Leave this off if you only want live forwarding."
        confirmLabel="Allow storage"
        onClose={() => setDisclose(false)}
        onConfirm={() => {
          direct.updatePreferences({ relayStorage: true });
          setDisclose(false);
        }}
      />
    </View>
  );
}

function StorageSection() {
  const direct = useDirect();
  const [stats, setStats] = useState(() => direct.repo.storageStats());
  const [open, setOpen] = useState(false);
  return (
    <View style={{ gap: 12 }}>
      <Text variant="title">Storage</Text>
      <Text>{stats.messages} messages · {stats.queued} queued · {stats.contacts} contacts · {stats.bytes} bytes in memory</Text>
      <Button label="Refresh" variant="secondary" onPress={() => setStats(direct.repo.storageStats())} />
      <Button label="Delete local messages" variant="danger" onPress={() => setOpen(true)} />
      <Dialog
        visible={open}
        title="Delete local messages?"
        body="This removes messages, the delivery queue, and acknowledgements from this device. Your identity stays."
        confirmLabel="Delete"
        danger
        onClose={() => setOpen(false)}
        onConfirm={() => {
          void direct.wipeMessages().then(() => setStats(direct.repo.storageStats()));
          setOpen(false);
        }}
      />
    </View>
  );
}

function RecoverySection() {
  const direct = useDirect();
  const [open, setOpen] = useState(false);
  const [phrase, setPhrase] = useState<string | null>(null);
  return (
    <View style={{ gap: 12 }}>
      <Text variant="title">Identity recovery</Text>
      <Text tone="muted">The phrase is the seed of your signing key. Agreement keys rotated after creation are kept on this device and are not folded into the phrase. Restoring the phrase brings back the original agreement key. Ask contacts to refresh your fingerprint.</Text>
      <Button label="Reveal recovery phrase" variant="danger" onPress={() => setOpen(true)} />
      {phrase ? <Text variant="label">{phrase}</Text> : null}
      <Dialog
        visible={open}
        title="Reveal the recovery phrase?"
        body="Anyone who can see these words can restore this identity. Do this somewhere private."
        confirmLabel="Reveal"
        danger
        onClose={() => setOpen(false)}
        onConfirm={() => {
          void direct.revealMnemonic().then(setPhrase);
          setOpen(false);
        }}
      />
    </View>
  );
}

function AboutSection() {
  return (
    <View style={{ gap: 12 }}>
      <Text variant="title">DIRECT</Text>
      <Text>No Middlemen. Just Connection.</Text>
      <Text tone="muted">Version 0.1.0. A device-first messenger. Messages are encrypted before they move, stored locally, and acknowledged by the recipient. No company is in the middle of the conversation.</Text>
    </View>
  );
}
