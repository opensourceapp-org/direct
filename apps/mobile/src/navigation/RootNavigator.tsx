import { useState } from 'react';
import { Pressable, View, useWindowDimensions } from 'react-native';
import { DarkTheme, DefaultTheme, NavigationContainer, useNavigationContainerRef } from '@react-navigation/native';
import { createNativeStackNavigator } from '@react-navigation/native-stack';
import { Icon } from '../components/ui/icons';
import { NavigationBar, Text, Wordmark } from '../components/ui/system';
import { useAppStore } from '../stores/appStore';
import { useTheme } from '../theme/ThemeProvider';
import { OnboardingScreen } from '../screens/OnboardingScreen';
import { InboxScreen } from '../screens/InboxScreen';
import { ChatScreen } from '../screens/ChatScreen';
import { AddContactScreen, ContactScreen, ContactsScreen } from '../screens/ContactsScreen';
import { NetworkScreen } from '../screens/NetworkScreen';
import { SettingsScreen, SettingsSectionScreen } from '../screens/SettingsScreen';
import { IdentityScreen } from '../screens/IdentityScreen';
import type { RootStackParamList } from './types';

const Stack = createNativeStackNavigator<RootStackParamList>();

const TABS = [
  { key: 'Inbox', label: 'Chats' },
  { key: 'Contacts', label: 'Contacts' },
  { key: 'Network', label: 'Network' },
  { key: 'Settings', label: 'Settings' },
] as const;

export function RootNavigator() {
  const theme = useTheme();
  const identity = useAppStore((state) => state.identity);
  const { width } = useWindowDimensions();
  const wide = width >= 960;
  const navigationRef = useNavigationContainerRef<RootStackParamList>();
  const [route, setRoute] = useState<string>(identity ? 'Inbox' : 'Onboarding');
  const base = theme.name === 'dark' ? DarkTheme : DefaultTheme;
  const showTabs = Boolean(identity) && ['Inbox', 'Contacts', 'Network', 'Settings'].includes(route);

  const go = (key: string) => {
    if (key === 'Inbox' || key === 'Contacts' || key === 'Network' || key === 'Settings') {
      navigationRef.navigate(key);
    }
  };

  return (
    <NavigationContainer
      ref={navigationRef}
      theme={{
        ...base,
        colors: {
          ...base.colors,
          background: theme.background,
          card: theme.background,
          text: theme.foreground,
          border: theme.border,
          primary: theme.accent,
          notification: theme.accent,
        },
      }}
      onStateChange={(state) => {
        const name = state?.routes[state.index ?? 0]?.name;
        if (name) setRoute(name);
      }}
    >
      <View style={{ flex: 1, flexDirection: wide ? 'row' : 'column', backgroundColor: theme.background }}>
        {identity && wide ? (
          <View style={{ width: 220, paddingTop: 20, gap: 18 }}>
            <View style={{ paddingHorizontal: 16 }}>
              <Wordmark />
            </View>
            <NavigationBar
              vertical
              active={route}
              onChange={go}
              items={TABS.map((tab) => ({
                key: tab.key,
                label: tab.label,
                icon: <Icon name={iconFor(tab.key)} color={route === tab.key ? theme.foreground : theme.muted} />,
              }))}
            />
          </View>
        ) : null}
        <View style={{ flex: 1 }}>
          {!wide && NESTED.has(route) ? (
            <Pressable
              accessibilityRole="button"
              accessibilityLabel="Back"
              onPress={() => navigationRef.goBack()}
              style={{ flexDirection: 'row', alignItems: 'center', gap: 6, paddingHorizontal: 12, paddingVertical: 10, borderBottomWidth: 1, borderColor: theme.border }}
            >
              <Icon name="back" color={theme.foreground} />
              <Text variant="label">Back</Text>
            </Pressable>
          ) : null}
          <Stack.Navigator screenOptions={{ headerShown: false, animation: 'fade', contentStyle: { backgroundColor: theme.background } }}>
            {identity ? (
              <>
                <Stack.Screen name="Inbox" component={InboxScreen} />
                <Stack.Screen name="Chat" component={ChatScreen} />
                <Stack.Screen name="Contacts" component={ContactsScreen} />
                <Stack.Screen name="AddContact" component={AddContactScreen} />
                <Stack.Screen name="Contact" component={ContactScreen} />
                <Stack.Screen name="Network" component={NetworkScreen} />
                <Stack.Screen name="Settings" component={SettingsScreen} />
                <Stack.Screen name="Section" component={SettingsSectionScreen} />
                <Stack.Screen name="Identity" component={IdentityScreen} />
              </>
            ) : (
              <Stack.Screen name="Onboarding" component={OnboardingScreen} />
            )}
          </Stack.Navigator>
        </View>
        {showTabs && !wide ? (
          <NavigationBar
            active={route}
            onChange={go}
            items={TABS.map((tab) => ({
              key: tab.key,
              label: tab.label,
              icon: <Icon name={iconFor(tab.key)} color={route === tab.key ? theme.foreground : theme.muted} />,
            }))}
          />
        ) : null}
      </View>
    </NavigationContainer>
  );
}

const NESTED = new Set(['AddContact', 'Contact', 'Section', 'Identity']);

function iconFor(key: string) {
  if (key === 'Contacts') return 'contacts' as const;
  if (key === 'Network') return 'network' as const;
  if (key === 'Settings') return 'settings' as const;
  return 'chat' as const;
}
