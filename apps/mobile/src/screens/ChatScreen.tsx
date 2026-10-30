import { useEffect, useState } from 'react';
import { ScrollView, View } from 'react-native';
import { useNavigation, useRoute } from '@react-navigation/native';
import type { RouteProp } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { ConnectionIndicator, EmptyState, IconButton, Input, MessageBubble, Text, Tooltip } from '../components/ui/system';
import { Icon } from '../components/ui/icons';
import { deliveryLabel, formatWhen } from '../app/format';
import { useDirect } from '../app/context';
import { useToast } from '../components/ui/system';
import { useAppStore } from '../stores/appStore';
import { useTheme } from '../theme/ThemeProvider';
import type { RootStackParamList } from '../navigation/types';
import type { MessageRow } from '@direct/protocol';

const NO_MESSAGES: MessageRow[] = [];

export function Thread({ directId, showBack }: { directId: string; showBack?: boolean }) {
  const theme = useTheme();
  const direct = useDirect();
  const toast = useToast();
  const navigation = useNavigation<NativeStackNavigationProp<RootStackParamList>>();
  const contacts = useAppStore((state) => state.contacts);
  const messages = useAppStore((state) => state.messages[`conv_${directId}`] ?? NO_MESSAGES);
  const status = useAppStore((state) => state.peerTransport[directId] ?? 'offline');
  const contact = contacts.find((item) => item.directId === directId);
  const [draft, setDraft] = useState('');

  useEffect(() => {
    void direct.openConversation(directId);
  }, [direct, directId]);

  const send = async () => {
    const body = draft.trim();
    if (!body) return;
    setDraft('');
    try {
      await direct.send(directId, body);
    } catch (error) {
      setDraft(body);
      toast(error instanceof Error ? error.message : 'Message was not queued.');
    }
  };

  return (
    <View style={{ flex: 1, backgroundColor: theme.background }}>
      <View style={{ paddingHorizontal: 12, paddingVertical: 12, borderBottomWidth: 1, borderColor: theme.border, flexDirection: 'row', alignItems: 'center', gap: 8 }}>
        {showBack ? (
          <IconButton label="Back" onPress={() => navigation.navigate('Inbox')}>
            <Icon name="back" color={theme.foreground} />
          </IconButton>
        ) : null}
        <View style={{ flex: 1, gap: 2 }}>
          <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
            <Text variant="heading">{contact?.displayName || directId}</Text>
            {contact?.verified ? <Text variant="meta" tone="success">Verified</Text> : <Text variant="meta" tone="muted">Unverified</Text>}
          </View>
          <ConnectionIndicator status={status} />
        </View>
      </View>
      <ScrollView style={{ flex: 1 }} contentContainerStyle={{ paddingVertical: 18 }}>
        {messages.length === 0 ? (
          <EmptyState title="No messages" body="A message is encrypted on this device, saved, and delivered when the recipient can be reached. It stays pending until their device signs an acknowledgement." />
        ) : messages.map((message) => (
          <MessageBubble
            key={message.id}
            body={message.body}
            outgoing={message.direction === 'outgoing'}
            time={formatWhen(message.createdAt)}
            status={message.direction === 'outgoing' ? deliveryLabel(message.status, message.transport) : undefined}
          />
        ))}
      </ScrollView>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8, padding: 12, borderTopWidth: 1, borderColor: theme.border }}>
        <Tooltip label="Attachments are not available yet">
          <IconButton label="Attachment" disabled onPress={() => undefined}>
            <Icon name="paperclip" color={theme.muted} />
          </IconButton>
        </Tooltip>
        <View style={{ flex: 1 }}>
          <Input value={draft} onChangeText={setDraft} placeholder="Message" onSubmit={() => void send()} />
        </View>
        <IconButton label="Send" onPress={() => void send()}>
          <Icon name="send" color={theme.foreground} />
        </IconButton>
      </View>
    </View>
  );
}

export function ChatScreen() {
  const route = useRoute<RouteProp<RootStackParamList, 'Chat'>>();
  return <Thread directId={route.params.directId} showBack />;
}
