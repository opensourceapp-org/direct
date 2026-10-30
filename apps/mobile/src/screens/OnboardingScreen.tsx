import { useMemo, useState } from 'react';
import { Pressable, ScrollView, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { Button, Divider, Input, Sheet, Text, Wordmark } from '../components/ui/system';
import { useToast } from '../components/ui/system';
import { useDirect } from '../app/context';
import { useTheme } from '../theme/ThemeProvider';

const PRINCIPLES = [
  {
    title: 'Your identity belongs to you.',
    body: 'A cryptographic identity is created on this device. No phone number. No email address.',
  },
  {
    title: 'Your messages stay on your devices.',
    body: 'Messages are encrypted before they leave and stored locally. DIRECT does not keep a copy.',
  },
  {
    title: 'Nothing here depends on a messaging company.',
    body: 'When the other person is reachable, your devices talk directly. A distributed relay is optional, and it only ever sees ciphertext.',
  },
];

export function OnboardingScreen() {
  const theme = useTheme();
  const insets = useSafeAreaInsets();
  const direct = useDirect();
  const toast = useToast();
  const [step, setStep] = useState<'intro' | 'choose' | 'name' | 'phrase' | 'confirm' | 'restore'>('intro');
  const [privacy, setPrivacy] = useState(false);
  const [name, setName] = useState('');
  const [phrase, setPhrase] = useState<string[]>([]);
  const [checks, setChecks] = useState<{ index: number; value: string }[]>([]);
  const [restorePhrase, setRestorePhrase] = useState('');
  const [busy, setBusy] = useState(false);

  const preview = useMemo(() => (phrase.length ? phrase.join(' ') : ''), [phrase]);

  const startCreate = () => {
    const created = direct.beginCreate(name);
    const words = created.mnemonic.split(' ');
    const indexes = [2, 11, 20].map((index) => ({ index, value: '' }));
    setPhrase(words);
    setChecks(indexes);
    setStep('phrase');
  };

  const confirm = async () => {
    const mismatch = checks.some((check) => phrase[check.index] !== check.value.trim().toLowerCase());
    if (mismatch) {
      toast('Those words do not match the phrase.');
      return;
    }
    setBusy(true);
    try {
      await direct.confirmPending();
    } catch (error) {
      toast(error instanceof Error ? error.message : 'Identity could not be saved.');
    } finally {
      setBusy(false);
    }
  };

  const restore = async () => {
    setBusy(true);
    try {
      await direct.restore(restorePhrase, name);
    } catch (error) {
      toast(error instanceof Error ? error.message : 'That recovery phrase could not be restored.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <ScrollView style={{ flex: 1, backgroundColor: theme.background }} contentContainerStyle={{ paddingTop: insets.top + 28, paddingBottom: insets.bottom + 40, paddingHorizontal: 24 }}>
      <Wordmark />
      <Text tone="muted" style={{ marginTop: 8 }}>No Middlemen. Just Connection.</Text>

      {step === 'intro' ? (
        <View style={{ marginTop: 48, gap: 28, maxWidth: 560 }}>
          <Text variant="display">Private by architecture.</Text>
          <View>
            {PRINCIPLES.map((principle, index) => (
              <View key={principle.title}>
                <View style={{ paddingVertical: 18, gap: 6 }}>
                  <Text variant="meta" tone="muted">0{index + 1}</Text>
                  <Text variant="heading">{principle.title}</Text>
                  <Text tone="muted">{principle.body}</Text>
                </View>
                {index < PRINCIPLES.length - 1 ? <Divider /> : null}
              </View>
            ))}
          </View>
          <View style={{ flexDirection: 'row', gap: 8, alignItems: 'center' }}>
            <Button label="Continue" onPress={() => setStep('choose')} />
            <Button label="Privacy" variant="ghost" onPress={() => setPrivacy(true)} />
          </View>
        </View>
      ) : null}

      {step === 'choose' ? (
        <View style={{ marginTop: 48, gap: 16, maxWidth: 460 }}>
          <Text variant="title">Create an identity on this device.</Text>
          <Text tone="muted">DIRECT will not ask for a phone number or an email address.</Text>
          <View style={{ gap: 8, marginTop: 8 }}>
            <Button label="Create identity" onPress={() => setStep('name')} />
            <Button label="Restore identity" variant="secondary" onPress={() => setStep('restore')} />
          </View>
        </View>
      ) : null}

      {step === 'name' ? (
        <View style={{ marginTop: 48, gap: 16, maxWidth: 460 }}>
          <Text variant="title">What should people see?</Text>
          <Text tone="muted">This name travels with your public identity bundle. It is not an account.</Text>
          <Input value={name} onChangeText={setName} placeholder="Name" autoCapitalize="words" />
          <Button label="Generate identity" onPress={startCreate} disabled={!name.trim()} />
        </View>
      ) : null}

      {step === 'phrase' ? (
        <View style={{ marginTop: 40, gap: 16, maxWidth: 640 }}>
          <Text variant="title">Write this phrase down.</Text>
          <Text tone="muted">
            Twenty-four words restore your identity. Keep them offline. Anyone who has them can become this identity. DIRECT cannot recover them for you.
          </Text>
          <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
            {phrase.map((word, index) => (
              <View key={`${word}-${index}`} style={{ width: 140, borderWidth: 1, borderColor: theme.border, borderRadius: 6, paddingHorizontal: 10, paddingVertical: 8 }}>
                <Text variant="meta" tone="muted">{String(index + 1).padStart(2, '0')}</Text>
                <Text variant="label">{word}</Text>
              </View>
            ))}
          </View>
          <Button label="I wrote it down" onPress={() => setStep('confirm')} />
        </View>
      ) : null}

      {step === 'confirm' ? (
        <View style={{ marginTop: 48, gap: 16, maxWidth: 460 }}>
          <Text variant="title">Confirm the phrase.</Text>
          <Text tone="muted">Enter the requested words. This check stays on this device.</Text>
          {checks.map((check, position) => (
            <View key={check.index} style={{ gap: 6 }}>
              <Text variant="meta" tone="muted">Word {check.index + 1}</Text>
              <Input
                value={check.value}
                autoCapitalize="none"
                onChangeText={(value) => {
                  const next = [...checks];
                  next[position] = { ...check, value };
                  setChecks(next);
                }}
                placeholder="word"
              />
            </View>
          ))}
          <Button label={busy ? 'Saving…' : 'Save identity'} onPress={() => void confirm()} disabled={busy} />
          <Text variant="meta" tone="muted">{preview ? 'The phrase is held in memory until you confirm.' : ''}</Text>
        </View>
      ) : null}

      {step === 'restore' ? (
        <View style={{ marginTop: 48, gap: 16, maxWidth: 520 }}>
          <Text variant="title">Restore from a phrase.</Text>
          <Text tone="muted">Enter the 24 words in order. This replaces nothing until the phrase is valid, and only when this device has no identity yet.</Text>
          <Input value={name} onChangeText={setName} placeholder="Name" autoCapitalize="words" />
          <Input value={restorePhrase} onChangeText={setRestorePhrase} placeholder="word word word …" />
          <View style={{ flexDirection: 'row', gap: 8 }}>
            <Button label={busy ? 'Restoring…' : 'Restore'} onPress={() => void restore()} disabled={busy || !restorePhrase.trim()} />
            <Button label="Back" variant="ghost" onPress={() => setStep('choose')} />
          </View>
        </View>
      ) : null}

      <Sheet visible={privacy} onClose={() => setPrivacy(false)}>
        <Text variant="heading">How DIRECT handles privacy</Text>
        <View style={{ gap: 12, marginTop: 16 }}>
          <Text>Private keys stay in the device key store. They are not rendered in the interface and they are not written to logs.</Text>
          <Text>Message content is encrypted before transmission. A relay, when you turn one on, receives ciphertext only.</Text>
          <Text>There is no account server and no central message database. Delivery is acknowledged by the recipient’s device, not by a relay.</Text>
          <Pressable onPress={() => setPrivacy(false)}><Text tone="accent">Close</Text></Pressable>
        </View>
      </Sheet>
    </ScrollView>
  );
}
