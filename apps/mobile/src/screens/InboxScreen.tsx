import { useMemo, useState } from 'react';
import { Pressable, ScrollView, useWindowDimensions, View } from 'react-native';
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { Avatar, Button, Divider, EmptyState, IconButton, Input, Text } from '../components/ui/system';
import { Icon } from '../components/ui/icons';
import { deliveryLabel, formatWhen } from '../app/format';
import { useAppStore } from '../stores/appStore';
import { useTheme } from '../theme/ThemeProvider';
import type { RootStackParamList } from '../navigation/types';
import { Thread } from './ChatScreen';

export function InboxScreen() {
  const theme = useTheme();
  const navigation = useNavigation<NativeStackNavigationProp<RootStackParamList>>();
  const { width } = useWindowDimensions();
  const wide = width >= 960;
  const conversations = useAppStore((state) => state.conversations);
  const opened = useAppStore((state) => state.openedDirectId);
  const peerTransport = useAppStore((state) => state.peerTransport);
  const [query, setQuery] = useState('');
  const filtered = useMemo(() => {
    const needle = query.trim().toLowerCase();
    if (!needle) return conversations;
    return conversations.filter((conversation) =>
      `${conversation.displayName} ${conversation.directId} ${conversation.preview}`.toLowerCase().includes(needle),
    );
  }, [conversations, query]);

  const open = (directId: string) => {
    useAppStore.getState().setSnapshot({ openedDirectId: directId });
    if (!wide) navigation.navigate('Chat', { directId });
  };

  return (
    <View style={{ flex: 1, flexDirection: 'row', backgroundColor: theme.background }}>
      <View style={{ flex: wide ? undefined : 1, width: wide ? 380 : undefined, borderRightWidth: wide ? 1 : 0, borderColor: theme.border }}>
        <View style={{ paddingHorizontal: 16, paddingTop: 18, paddingBottom: 12, gap: 12 }}>
          <View style={{ flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' }}>
            <Text variant="heading">Chats</Text>
            <IconButton label="New conversation" onPress={() => navigation.navigate('Contacts')}>
              <Icon name="plus" color={theme.foreground} />
            </IconButton>
          </View>
          <Input value={query} onChangeText={setQuery} placeholder="Search conversations" />
        </View>
        <Divider />
        {filtered.length === 0 ? (
          <EmptyState
            title={conversations.length === 0 ? 'No conversations yet' : 'No matches'}
            body={conversations.length === 0 ? 'Add a contact with a DIRECT ID or a QR bundle. Messages stay on this device until the other person is reachable.' : 'Try a name, DIRECT ID, or part of a message.'}
            action={conversations.length === 0 ? <Button label="Add a contact" variant="secondary" onPress={() => navigation.navigate('Contacts')} /> : undefined}
          />
        ) : (
          <ScrollView>
            {filtered.map((conversation) => {
              const selected = opened === conversation.directId;
              const delivery = conversation.lastStatus === 'pending' || conversation.lastStatus === 'expired' || conversation.lastStatus === 'failed'
                ? deliveryLabel(conversation.lastStatus, conversation.lastTransport)
                : null;
              return (
                <Pressable
                  key={conversation.id}
                  accessibilityRole="button"
                  onPress={() => open(conversation.directId)}
                  style={({ pressed }) => [{
                    paddingHorizontal: 16,
                    paddingVertical: 12,
                    backgroundColor: selected || pressed ? theme.surface : theme.background,
                    borderBottomWidth: 1,
                    borderColor: theme.border,
                  }]}
                >
                  <View style={{ flexDirection: 'row', gap: 12 }}>
                    <Avatar label={conversation.displayName || conversation.directId} online={peerTransport[conversation.directId] === 'direct'} />
                    <View style={{ flex: 1, gap: 2 }}>
                      <View style={{ flexDirection: 'row', justifyContent: 'space-between', gap: 8 }}>
                        <Text variant="label" style={{ flex: 1 }} numberOfLines={1}>{conversation.displayName || conversation.directId}</Text>
                        <Text variant="meta" tone="muted">{conversation.updatedAt ? formatWhen(conversation.updatedAt) : ''}</Text>
                      </View>
                      <Text variant="meta" tone="muted" numberOfLines={1}>{conversation.directId}</Text>
                      <View style={{ flexDirection: 'row', justifyContent: 'space-between', gap: 8 }}>
                        <Text variant="body" tone="muted" numberOfLines={1} style={{ flex: 1 }}>{conversation.preview || 'No messages yet'}</Text>
                        {conversation.unread > 0 ? <View style={{ minWidth: 8, height: 8, borderRadius: 4, backgroundColor: theme.accent, marginTop: 6 }} /> : null}
                      </View>
                      {delivery ? <Text variant="meta" tone="muted">{delivery}</Text> : null}
                    </View>
                  </View>
                </Pressable>
              );
            })}
          </ScrollView>
        )}
      </View>
      {wide ? (
        <View style={{ flex: 1 }}>
          {opened ? <Thread directId={opened} /> : (
            <EmptyState title="Select a conversation" body="Messages are shown from this device’s encrypted database." />
          )}
        </View>
      ) : null}
    </View>
  );
}
