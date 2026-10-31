import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { Animated, Modal as NativeModal, Pressable, ScrollView, StyleSheet, Text as NativeText, TextInput, View, type TextStyle, type ViewStyle } from 'react-native';
import { useTheme } from '../../theme/ThemeProvider';
import type { Theme } from '../../theme/theme';

type Tone = 'default' | 'muted' | 'accent' | 'danger' | 'success' | 'inverse';

export function Text({
  children,
  variant = 'body',
  tone = 'default',
  style,
  numberOfLines,
}: {
  children: ReactNode;
  variant?: 'display' | 'title' | 'heading' | 'body' | 'label' | 'meta';
  tone?: Tone;
  numberOfLines?: number;
  style?: TextStyle;
}) {
  const theme = useTheme();
  const sizes = {
    display: { fontSize: 40, lineHeight: 44, fontWeight: '500' as const, letterSpacing: -1.2 },
    title: { fontSize: 22, lineHeight: 28, fontWeight: '500' as const, letterSpacing: -0.4 },
    heading: { fontSize: 15, lineHeight: 20, fontWeight: '500' as const, letterSpacing: -0.2 },
    body: { fontSize: 14, lineHeight: 20, fontWeight: '400' as const },
    label: { fontSize: 13, lineHeight: 18, fontWeight: '500' as const },
    meta: { fontSize: 12, lineHeight: 16, fontWeight: '400' as const },
  };
  const colors: Record<Tone, string> = {
    default: theme.foreground,
    muted: theme.muted,
    accent: theme.accent,
    danger: theme.danger,
    success: theme.success,
    inverse: theme.inverseForeground,
  };
  return (
    <NativeText numberOfLines={numberOfLines} style={[{ fontFamily: theme.fontFamily, color: colors[tone] }, sizes[variant], style]}>{children}</NativeText>
  );
}

export function Wordmark() {
  return (
    <Text variant="label" style={{ letterSpacing: 1.8, fontWeight: '600' }}>
      DIRECT
    </Text>
  );
}

export function Button({
  label,
  onPress,
  variant = 'primary',
  disabled,
}: {
  label: string;
  onPress: () => void;
  variant?: 'primary' | 'secondary' | 'ghost' | 'danger';
  disabled?: boolean;
}) {
  const theme = useTheme();
  const styles = {
    primary: { backgroundColor: theme.inverse, borderColor: theme.inverse, color: theme.inverseForeground },
    secondary: { backgroundColor: 'transparent', borderColor: theme.border, color: theme.foreground },
    ghost: { backgroundColor: 'transparent', borderColor: 'transparent', color: theme.foreground },
    danger: { backgroundColor: 'transparent', borderColor: theme.border, color: theme.danger },
  }[variant];
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => [{
        height: 36,
        paddingHorizontal: 14,
        borderRadius: 6,
        borderWidth: 1,
        alignItems: 'center',
        justifyContent: 'center',
        opacity: disabled ? 0.4 : pressed ? 0.72 : 1,
        backgroundColor: styles.backgroundColor,
        borderColor: styles.borderColor,
      }]}
    >
      <Text variant="label" style={{ color: styles.color }}>{label}</Text>
    </Pressable>
  );
}

export function IconButton({
  label,
  onPress,
  children,
  disabled,
}: {
  label: string;
  onPress: () => void;
  children: ReactNode;
  disabled?: boolean;
}) {
  const theme = useTheme();
  return (
    <Pressable
      accessibilityRole="button"
      accessibilityLabel={label}
      disabled={disabled}
      onPress={onPress}
      style={({ pressed }) => [{
        width: 32,
        height: 32,
        borderRadius: 6,
        alignItems: 'center',
        justifyContent: 'center',
        opacity: disabled ? 0.35 : pressed ? 0.6 : 1,
        backgroundColor: pressed ? theme.surfaceSecondary : 'transparent',
      }]}
    >
      {children}
    </Pressable>
  );
}

function fieldStyle(theme: Theme, multiline = false): ViewStyle & TextStyle {
  return {
    borderWidth: 1,
    borderColor: theme.border,
    backgroundColor: theme.background,
    color: theme.foreground,
    borderRadius: 6,
    paddingHorizontal: 12,
    paddingVertical: multiline ? 10 : 0,
    minHeight: multiline ? 96 : 36,
    fontSize: 14,
    fontFamily: theme.fontFamily,
  };
}

export function Input({
  value,
  onChangeText,
  placeholder,
  autoCapitalize = 'none',
  secureTextEntry,
  onSubmit,
}: {
  value: string;
  onChangeText: (value: string) => void;
  placeholder?: string;
  autoCapitalize?: 'none' | 'sentences' | 'words';
  secureTextEntry?: boolean;
  onSubmit?: () => void;
}) {
  const theme = useTheme();
  return (
    <TextInput
      value={value}
      onChangeText={onChangeText}
      placeholder={placeholder}
      placeholderTextColor={theme.muted}
      autoCapitalize={autoCapitalize}
      autoCorrect={false}
      secureTextEntry={secureTextEntry}
      onSubmitEditing={onSubmit}
      style={fieldStyle(theme)}
    />
  );
}

export function Textarea({
  value,
  onChangeText,
  placeholder,
}: {
  value: string;
  onChangeText: (value: string) => void;
  placeholder?: string;
}) {
  const theme = useTheme();
  return (
    <TextInput
      value={value}
      onChangeText={onChangeText}
      placeholder={placeholder}
      placeholderTextColor={theme.muted}
      multiline
      autoCapitalize="none"
      autoCorrect={false}
      style={[fieldStyle(theme, true), { textAlignVertical: 'top' }]}
    />
  );
}

export function Avatar({ label, online }: { label: string; online?: boolean }) {
  const theme = useTheme();
  const initials = label.split(' ').filter(Boolean).slice(0, 2).map((part) => part[0]?.toUpperCase()).join('') || '·';
  return (
    <View style={{ width: 32, height: 32 }}>
      <View style={{
        width: 32,
        height: 32,
        borderRadius: 16,
        borderWidth: 1,
        borderColor: theme.border,
        backgroundColor: theme.surface,
        alignItems: 'center',
        justifyContent: 'center',
      }}>
        <Text variant="meta" style={{ fontWeight: '500' }}>{initials}</Text>
      </View>
      {online === undefined ? null : (
        <View style={{
          position: 'absolute',
          right: -1,
          bottom: -1,
          width: 8,
          height: 8,
          borderRadius: 4,
          backgroundColor: online ? theme.success : theme.border,
          borderWidth: 1,
          borderColor: theme.background,
        }} />
      )}
    </View>
  );
}

export function Badge({ label, tone = 'neutral' }: { label: string; tone?: 'neutral' | 'accent' | 'danger' }) {
  const theme = useTheme();
  const color = tone === 'accent' ? theme.accent : tone === 'danger' ? theme.danger : theme.muted;
  return (
    <View style={{ borderWidth: 1, borderColor: theme.border, borderRadius: 999, paddingHorizontal: 8, paddingVertical: 2 }}>
      <Text variant="meta" style={{ color }}>{label}</Text>
    </View>
  );
}

export function Divider() {
  const theme = useTheme();
  return <View style={{ height: StyleSheet.hairlineWidth, backgroundColor: theme.border }} />;
}

export function Skeleton({ width, height = 12 }: { width: number | `${number}%`; height?: number }) {
  const theme = useTheme();
  const opacity = useMemo(() => new Animated.Value(0.4), []);
  useEffect(() => {
    const loop = Animated.loop(
      Animated.sequence([
        Animated.timing(opacity, { toValue: 1, duration: 700, useNativeDriver: true }),
        Animated.timing(opacity, { toValue: 0.4, duration: 700, useNativeDriver: true }),
      ]),
    );
    loop.start();
    return () => loop.stop();
  }, [opacity]);
  return <Animated.View style={{ width, height, borderRadius: 4, backgroundColor: theme.surfaceSecondary, opacity }} />;
}

const TooltipContext = createContext<{ show: (text: string) => void } | null>(null);

export function Tooltip({ label, children }: { label: string; children: ReactNode }) {
  const [open, setOpen] = useState(false);
  const theme = useTheme();
  return (
    <View>
      <Pressable onHoverIn={() => setOpen(true)} onHoverOut={() => setOpen(false)} onLongPress={() => setOpen(true)} onPressOut={() => setOpen(false)}>
        {children}
      </Pressable>
      {open ? (
        <View style={{
          position: 'absolute',
          bottom: 36,
          right: 0,
          maxWidth: 220,
          paddingHorizontal: 8,
          paddingVertical: 6,
          borderWidth: 1,
          borderColor: theme.border,
          backgroundColor: theme.background,
          borderRadius: 6,
          zIndex: 5,
        }}>
          <Text variant="meta">{label}</Text>
        </View>
      ) : null}
    </View>
  );
}

export function Dropdown({
  label,
  items,
}: {
  label: string;
  items: { label: string; onPress: () => void }[];
}) {
  const [open, setOpen] = useState(false);
  const theme = useTheme();
  return (
    <View>
      <Button label={label} variant="secondary" onPress={() => setOpen((value) => !value)} />
      {open ? (
        <View style={{
          marginTop: 6,
          borderWidth: 1,
          borderColor: theme.border,
          borderRadius: 6,
          backgroundColor: theme.background,
          overflow: 'hidden',
        }}>
          {items.map((item) => (
            <Pressable
              key={item.label}
              onPress={() => {
                setOpen(false);
                item.onPress();
              }}
              style={({ pressed }) => [{ paddingHorizontal: 12, paddingVertical: 10, backgroundColor: pressed ? theme.surface : theme.background }]}
            >
              <Text variant="label">{item.label}</Text>
            </Pressable>
          ))}
        </View>
      ) : null}
    </View>
  );
}

export function Modal({ visible, onClose, children }: { visible: boolean; onClose: () => void; children: ReactNode }) {
  const theme = useTheme();
  return (
    <NativeModal visible={visible} transparent animationType="fade" onRequestClose={onClose}>
      <Pressable onPress={onClose} style={{ flex: 1, backgroundColor: theme.name === 'dark' ? 'rgba(0,0,0,0.72)' : 'rgba(0,0,0,0.28)', alignItems: 'center', justifyContent: 'center', padding: 24 }}>
        <Pressable onPress={() => undefined} style={{ width: '100%', maxWidth: 440, borderWidth: 1, borderColor: theme.border, backgroundColor: theme.background, borderRadius: 8, padding: 20 }}>
          {children}
        </Pressable>
      </Pressable>
    </NativeModal>
  );
}

export function Dialog({
  visible,
  title,
  body,
  confirmLabel,
  onConfirm,
  onClose,
  danger,
}: {
  visible: boolean;
  title: string;
  body: string;
  confirmLabel: string;
  onConfirm: () => void;
  onClose: () => void;
  danger?: boolean;
}) {
  return (
    <Modal visible={visible} onClose={onClose}>
      <Text variant="heading">{title}</Text>
      <Text tone="muted" style={{ marginTop: 8 }}>{body}</Text>
      <View style={{ flexDirection: 'row', justifyContent: 'flex-end', gap: 8, marginTop: 20 }}>
        <Button label="Cancel" variant="ghost" onPress={onClose} />
        <Button label={confirmLabel} variant={danger ? 'danger' : 'primary'} onPress={onConfirm} />
      </View>
    </Modal>
  );
}

export function Sheet({ visible, onClose, children }: { visible: boolean; onClose: () => void; children: ReactNode }) {
  const theme = useTheme();
  return (
    <NativeModal visible={visible} transparent animationType="slide" onRequestClose={onClose}>
      <Pressable onPress={onClose} style={{ flex: 1, justifyContent: 'flex-end', backgroundColor: theme.name === 'dark' ? 'rgba(0,0,0,0.6)' : 'rgba(0,0,0,0.2)' }}>
        <Pressable onPress={() => undefined} style={{ borderTopWidth: 1, borderColor: theme.border, backgroundColor: theme.background, padding: 20, paddingBottom: 32, borderTopLeftRadius: 8, borderTopRightRadius: 8, maxHeight: '80%' }}>
          <ScrollView>{children}</ScrollView>
        </Pressable>
      </Pressable>
    </NativeModal>
  );
}

type ToastItem = { id: number; message: string };
const ToastContext = createContext<(message: string) => void>(() => undefined);

export function ToastProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<ToastItem[]>([]);
  const theme = useTheme();
  const push = (message: string) => {
    const id = Date.now();
    setItems((current) => [...current, { id, message }]);
    setTimeout(() => setItems((current) => current.filter((item) => item.id !== id)), 2400);
  };
  return (
    <ToastContext.Provider value={push}>
      {children}
      <View pointerEvents="none" style={{ position: 'absolute', top: 16, left: 0, right: 0, alignItems: 'center', gap: 8 }}>
        {items.map((item) => (
          <View key={item.id} style={{ borderWidth: 1, borderColor: theme.border, backgroundColor: theme.background, borderRadius: 6, paddingHorizontal: 12, paddingVertical: 8 }}>
            <Text variant="label">{item.message}</Text>
          </View>
        ))}
      </View>
    </ToastContext.Provider>
  );
}

export function useToast(): (message: string) => void {
  return useContext(ToastContext);
}

export function NavigationBar({
  items,
  active,
  onChange,
  vertical,
}: {
  items: { key: string; label: string; icon: ReactNode }[];
  active: string;
  onChange: (key: string) => void;
  vertical?: boolean;
}) {
  const theme = useTheme();
  return (
    <View style={{
      flexDirection: vertical ? 'column' : 'row',
      borderTopWidth: vertical ? 0 : StyleSheet.hairlineWidth,
      borderRightWidth: vertical ? StyleSheet.hairlineWidth : 0,
      borderColor: theme.border,
      backgroundColor: theme.background,
      paddingVertical: vertical ? 12 : 6,
      paddingHorizontal: vertical ? 10 : 8,
      gap: 4,
    }}>
      {items.map((item) => {
        const selected = item.key === active;
        return (
          <Pressable
            key={item.key}
            accessibilityRole="button"
            accessibilityLabel={item.label}
            onPress={() => onChange(item.key)}
            style={({ pressed }) => [{
              flex: vertical ? undefined : 1,
              flexDirection: vertical ? 'row' : 'column',
              alignItems: 'center',
              justifyContent: vertical ? 'flex-start' : 'center',
              gap: 8,
              paddingVertical: 8,
              paddingHorizontal: vertical ? 10 : 0,
              borderRadius: 6,
              backgroundColor: selected || pressed ? theme.surfaceSecondary : 'transparent',
            }]}
          >
            {item.icon}
            <Text variant="meta" tone={selected ? 'default' : 'muted'}>{item.label}</Text>
          </Pressable>
        );
      })}
    </View>
  );
}

export function StatusIndicator({ tone = 'neutral' }: { tone?: 'neutral' | 'success' | 'warning' | 'accent' | 'danger' }) {
  const theme = useTheme();
  const color = {
    neutral: theme.muted,
    success: theme.success,
    warning: theme.warning,
    accent: theme.accent,
    danger: theme.danger,
  }[tone];
  return <View style={{ width: 6, height: 6, borderRadius: 3, backgroundColor: color }} />;
}

export function ConnectionIndicator({ status }: { status: 'direct' | 'relay' | 'offline' | 'connecting' | 'present' }) {
  const label = {
    direct: 'Connected directly',
    present: 'On this bootstrap',
    relay: 'Distributed relay',
    offline: 'Recipient unavailable',
    connecting: 'Connecting',
  }[status];
  const tone = status === 'direct' ? 'success' : status === 'present' || status === 'relay' ? 'accent' : status === 'connecting' ? 'warning' : 'neutral';
  return (
    <View style={{ flexDirection: 'row', alignItems: 'center', gap: 6 }}>
      <StatusIndicator tone={tone} />
      <Text variant="meta" tone="muted">{label}</Text>
    </View>
  );
}

export function MessageBubble({
  body,
  outgoing,
  time,
  status,
}: {
  body: string;
  outgoing: boolean;
  time: string;
  status?: string;
}) {
  const theme = useTheme();
  return (
    <View style={{ alignItems: outgoing ? 'flex-end' : 'flex-start', marginBottom: 14, paddingHorizontal: 16 }}>
      <View style={{
        maxWidth: '82%',
        paddingHorizontal: 12,
        paddingVertical: 8,
        borderRadius: 8,
        backgroundColor: outgoing ? theme.inverse : theme.surface,
        borderWidth: outgoing ? 0 : 1,
        borderColor: theme.border,
      }}>
        <Text variant="body" tone={outgoing ? 'inverse' : 'default'}>{body}</Text>
      </View>
      <Text variant="meta" tone="muted" style={{ marginTop: 4 }}>
        {time}{status ? ` · ${status}` : ''}
      </Text>
    </View>
  );
}

export function EmptyState({
  title,
  body,
  action,
}: {
  title: string;
  body: string;
  action?: ReactNode;
}) {
  const theme = useTheme();
  return (
    <View style={{ flex: 1, alignItems: 'flex-start', justifyContent: 'center', paddingHorizontal: 28, paddingVertical: 48, gap: 12 }}>
      <View style={{ width: 28, height: 28, borderWidth: 1, borderColor: theme.border, borderRadius: 14, marginBottom: 4 }} />
      <Text variant="heading">{title}</Text>
      <Text tone="muted" style={{ maxWidth: 360 }}>{body}</Text>
      {action}
    </View>
  );
}

export { TooltipContext };
