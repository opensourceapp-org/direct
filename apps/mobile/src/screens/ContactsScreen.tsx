import { useState } from 'react';
import { Pressable, ScrollView, View } from 'react-native';
import { useNavigation, useRoute } from '@react-navigation/native';
import type { RouteProp } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { Avatar, Badge, Button, Dialog, Divider, EmptyState, Input, Text, Textarea } from '../components/ui/system';
import { useToast } from '../components/ui/system';
import { useDirect } from '../app/context';
import { useAppStore } from '../stores/appStore';
import { useTheme } from '../theme/ThemeProvider';
import type { RootStackParamList } from '../navigation/types';

export function ContactsScreen() {
  const theme = useTheme();
  const navigation = useNavigation<NativeStackNavigationProp<RootStackParamList>>();
  const saved = useAppStore((state) => state.contacts);
  const contacts = saved.filter((contact) => contact.accepted);
  return (
    <View style={{ flex: 1, backgroundColor: theme.background }}>
      <View style={{ paddingHorizontal: 16, paddingTop: 18, paddingBottom: 12, flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center' }}>
        <Text variant="heading">Contacts</Text>
        <Button label="Add" onPress={() => navigation.navigate('AddContact')} />
      </View>
      <Divider />
      {contacts.length === 0 ? (
        <EmptyState title="No contacts" body="Add someone with a QR bundle or a DIRECT ID published on this bootstrap. There is no central directory." />
      ) : (
        <ScrollView>
          {contacts.map((contact) => (
            <Pressable
              key={contact.id}
              accessibilityRole="button"
              onPress={() => navigation.navigate('Contact', { directId: contact.directId })}
              style={({ pressed }) => [{ paddingHorizontal: 16, paddingVertical: 12, backgroundColor: pressed ? theme.surface : theme.background, borderBottomWidth: 1, borderColor: theme.border, flexDirection: 'row', gap: 12, alignItems: 'center' }]}
            >
              <Avatar label={contact.displayName || contact.directId} />
              <View style={{ flex: 1, gap: 2 }}>
                <Text variant="label">{contact.displayName || contact.directId}</Text>
                <Text variant="meta" tone="muted">{contact.directId}</Text>
              </View>
              {contact.blocked ? <Badge label="Blocked" tone="danger" /> : contact.verified ? <Badge label="Verified" /> : <Badge label="Unverified" />}
            </Pressable>
          ))}
        </ScrollView>
      )}
    </View>
  );
}

export function AddContactScreen() {
  const theme = useTheme();
  const direct = useDirect();
  const toast = useToast();
  const navigation = useNavigation<NativeStackNavigationProp<RootStackParamList>>();
  const [directId, setDirectId] = useState('');
  const [bundle, setBundle] = useState('');

  const addId = async () => {
    try {
      await direct.addByDirectId(directId.trim());
      navigation.navigate('Contacts');
    } catch (error) {
      toast(error instanceof Error ? error.message : 'That DIRECT ID was not found.');
    }
  };

  const addBundle = async () => {
    try {
      await direct.addBundle(bundle);
      navigation.navigate('Contacts');
    } catch (error) {
      toast(error instanceof Error ? error.message : 'That bundle could not be verified.');
    }
  };

  return (
    <ScrollView style={{ flex: 1, backgroundColor: theme.background }} contentContainerStyle={{ padding: 20, gap: 16, maxWidth: 640 }}>
      <Text variant="title">Add a contact</Text>
      <Text tone="muted">Look up a DIRECT ID from another phone that has DIRECT open on this same bootstrap. The phones can be on different networks. You can also paste the identity bundle from their QR code.</Text>
      <Text variant="label">DIRECT ID</Text>
      <Input value={directId} onChangeText={setDirectId} placeholder="dir_…" />
      <Button label="Look up" onPress={() => void addId()} disabled={!directId.trim()} />
      <Divider />
      <Text variant="label">Identity bundle</Text>
      <Textarea value={bundle} onChangeText={setBundle} placeholder="Paste the JSON bundle" />
      <Button label="Verify and add" variant="secondary" onPress={() => void addBundle()} disabled={!bundle.trim()} />
    </ScrollView>
  );
}

export function ContactScreen() {
  const theme = useTheme();
  const route = useRoute<RouteProp<RootStackParamList, 'Contact'>>();
  const direct = useDirect();
  const navigation = useNavigation<NativeStackNavigationProp<RootStackParamList>>();
  const contact = useAppStore((state) => state.contacts.find((item) => item.directId === route.params.directId));
  const [removeOpen, setRemoveOpen] = useState(false);
  const [blockOpen, setBlockOpen] = useState(false);
  if (!contact) {
    return <EmptyState title="Contact removed" body="This identity is no longer on this device." />;
  }
  return (
    <ScrollView style={{ flex: 1, backgroundColor: theme.background }} contentContainerStyle={{ padding: 20, gap: 14, maxWidth: 640 }}>
      <Text variant="title">{contact.displayName}</Text>
      <Row label="DIRECT ID" value={contact.directId} />
      <Row label="DID" value={contact.did} />
      <Row label="Fingerprint" value={contact.fingerprint} />
      <Row label="Device" value={contact.deviceId} />
      <Text tone="muted">{contact.verified ? 'You marked this fingerprint as verified.' : 'Compare this fingerprint with the person before you rely on it.'}</Text>
      <View style={{ flexDirection: 'row', gap: 8, flexWrap: 'wrap' }}>
        <Button label="Message" onPress={() => navigation.navigate('Chat', { directId: contact.directId })} />
        <Button label={contact.verified ? 'Clear verification' : 'Mark verified'} variant="secondary" onPress={() => void direct.setVerified(contact.directId, !contact.verified)} />
        <Button label="Block" variant="danger" onPress={() => setBlockOpen(true)} />
        <Button label="Remove" variant="ghost" onPress={() => setRemoveOpen(true)} />
      </View>
      <Dialog
        visible={blockOpen}
        title="Block this contact?"
        body="New messages will not be sent or accepted. Existing messages stay on this device."
        confirmLabel="Block"
        danger
        onClose={() => setBlockOpen(false)}
        onConfirm={() => {
          void direct.block(contact.directId);
          setBlockOpen(false);
        }}
      />
      <Dialog
        visible={removeOpen}
        title="Remove this contact?"
        body="Their conversation is deleted from this device. Outgoing messages that have not been acknowledged will stop retrying."
        confirmLabel="Remove"
        danger
        onClose={() => setRemoveOpen(false)}
        onConfirm={() => {
          void direct.removeContact(contact.directId);
          setRemoveOpen(false);
          navigation.navigate('Contacts');
        }}
      />
    </ScrollView>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <View style={{ gap: 4 }}>
      <Text variant="meta" tone="muted">{label}</Text>
      <Text variant="label">{value}</Text>
    </View>
  );
}
