import {
  createBundle,
  createIdentityMaterial,
  createPeerCipher,
  decodeSecretList,
  deviceId,
  discoveryNodeId,
  encodeBundle,
  encodeSecretList,
  keysFromSeed,
  mnemonicForSeed,
  parseBundle,
  replaceAgreement,
  restoreFromMnemonic,
  rotateAgreementKey,
  toPublicIdentity,
} from '@direct/crypto';
import type { IdentityKeys, PublicBundle } from '@direct/crypto';
import { DeliveryEngine } from '@direct/protocol';
import type { ContactPublic, LocalIdentity } from '@direct/protocol';
import { createLogger, text, utf8 } from '@direct/shared';
import { KademliaTable, LocalTransport, TransportRouter, WebRTCTransport } from '@direct/transport';
import { openEncryptedDatabase } from '../infrastructure/persistence/database';
import { DirectRepository, publicKeyBytes, publicKeyMaterial } from '../infrastructure/persistence/repositories';
import type { ContactRecord, IdentityRecord } from '../infrastructure/persistence/repositories';
import { openBrowserBlobs, openBrowserVault } from '../infrastructure/keystore/indexedDb';
import type { KeyVault } from '@direct/crypto';
import { DirectBootstrap, resolveBootstrapUrl } from '../infrastructure/network/bootstrap';
import { browserPeerConnectionFactory } from '../infrastructure/network/browserRtc';
import { BrowserMesh } from '../infrastructure/network/browserMesh';
import { ChannelRelay } from '../infrastructure/network/channelRelay';
import { loadPreferences, savePreferences } from '../infrastructure/preferences';
import type { Preferences } from '../infrastructure/preferences';
import { useAppStore } from '../stores/appStore';
import type { IdentityView, NetworkView } from '../stores/appStore';

const RELAY_TTL_MS = 24 * 60 * 60 * 1000;

export class DirectController {
  private keys: IdentityKeys | null = null;
  private previous: Uint8Array[] = [];
  private pending: { keys: IdentityKeys; mnemonic: string; name: string } | null = null;
  private engine: DeliveryEngine | null = null;
  private unregister: (() => void) | null = null;
  private localLink: LocalTransport | null = null;
  private bootstrap: DirectBootstrap | null = null;
  private rtc: WebRTCTransport | null = null;
  private timer: ReturnType<typeof setInterval> | null = null;
  readonly mesh: BrowserMesh;
  readonly relay: ChannelRelay;
  readonly router: TransportRouter;
  readonly kad: KademliaTable;
  private readonly discovered = new Map<string, PublicBundle>();

  private constructor(
    readonly repo: DirectRepository,
    private readonly vault: KeyVault,
    private preferences: Preferences,
  ) {
    this.mesh = new BrowserMesh((bundle) => this.ingestBundle(bundle));
    this.relay = new ChannelRelay({
      enabled: preferences.relayEnabled,
      storage: preferences.relayStorage,
      ttlMs: RELAY_TTL_MS,
    });
    const local = new LocalTransport('pending', this.mesh);
    this.router = new TransportRouter({
      direct: [local],
      relay: this.relay,
      relayEnabled: preferences.relayEnabled,
    });
    this.kad = new KademliaTable(discoveryNodeId('direct-device'));
  }

  static async boot(wasmBinary: Uint8Array): Promise<DirectController> {
    const preferences = loadPreferences();
    const vault = await openBrowserVault();
    const blobs = await openBrowserBlobs();
    const database = await openEncryptedDatabase({ wasmBinary, vault, blobs });
    const repo = new DirectRepository(database);
    const controller = new DirectController(repo, vault, preferences);
    const seed = await vault.get('identity.seed');
    const record = repo.getIdentity();
    if (seed && record) {
      const agreement = await vault.get('identity.agreement');
      let keys = keysFromSeed(seed);
      if (agreement) keys = replaceAgreement(keys, agreement);
      controller.previous = decodeSecretList(await vault.get('identity.previous'));
      const device = text(await vault.get('identity.device') ?? utf8(record.deviceId));
      controller.activate(keys, { ...record, deviceId: device || record.deviceId });
    }
    controller.publish();
    controller.start();
    controller.refresh();
    return controller;
  }

  get prefs(): Preferences {
    return this.preferences;
  }

  beginCreate(displayName: string): { mnemonic: string; directId: string; fingerprint: string } {
    const name = displayName.trim().slice(0, 32);
    const created = createIdentityMaterial();
    this.pending = { keys: created.keys, mnemonic: created.mnemonic, name };
    const identity = toPublicIdentity(created.keys, name, 'pending');
    return { mnemonic: created.mnemonic, directId: identity.directId, fingerprint: identity.fingerprint };
  }

  cancelPending(): void {
    if (this.pending) {
      this.pending.keys.seed.fill(0);
      this.pending.keys.signingSecret.fill(0);
      this.pending.keys.agreementSecret.fill(0);
    }
    this.pending = null;
  }

  async confirmPending(): Promise<void> {
    if (!this.pending) throw new Error('There is no identity waiting to be saved.');
    const pending = this.pending;
    const device = deviceId();
    await this.persistIdentity(pending.keys, pending.name, device, []);
    this.pending = null;
    this.activate(pending.keys, this.requireRecord());
    this.publish();
    await this.repo.save();
    this.refresh();
  }

  async restore(mnemonic: string, displayName: string): Promise<void> {
    const keys = restoreFromMnemonic(mnemonic);
    const name = displayName.trim().slice(0, 32);
    const device = deviceId();
    await this.persistIdentity(keys, name, device, []);
    this.activate(keys, this.requireRecord());
    this.publish();
    await this.repo.save();
    this.refresh();
  }

  async revealMnemonic(): Promise<string> {
    if (!this.keys) throw new Error('No identity on this device.');
    return mnemonicForSeed(this.keys.seed);
  }

  async rotateAgreement(): Promise<void> {
    if (!this.keys) return;
    const record = this.requireRecord();
    const rotated = rotateAgreementKey(this.keys);
    const previous = [rotated.previousSecret, ...this.previous].slice(0, 3);
    await this.persistIdentity(rotated.keys, record.displayName, record.deviceId, previous, record.id);
    this.activate(rotated.keys, this.requireRecord());
    this.publish();
    await this.repo.save();
    this.refresh();
  }

  async rename(displayName: string): Promise<void> {
    if (!this.keys) return;
    const record = this.requireRecord();
    const name = displayName.trim().slice(0, 32);
    await this.persistIdentity(this.keys, name, record.deviceId, this.previous, record.id);
    this.activate(this.keys, this.requireRecord());
    this.publish();
    await this.repo.save();
    this.refresh();
  }

  async addBundle(serialized: string): Promise<void> {
    const bundle = parseBundle(serialized.trim());
    this.saveContact(bundle, false);
    await this.repo.save();
    this.refresh();
  }

  async addByDirectId(directId: string): Promise<void> {
    const id = directId.trim().replace(/^dir_/i, 'dir_').toUpperCase().replace(/^DIR_/, 'dir_');
    await this.mesh.sync();
    await this.waitForBootstrap();
    if (!this.discovered.has(id)) {
      const published = await this.bootstrap?.lookup(id);
      if (published) this.ingestBundle(published);
    }
    const bundle = this.discovered.get(id);
    if (!bundle) throw new Error('No phone on this bootstrap is publishing that DIRECT ID. Keep DIRECT open on both phones, on this same address or the same bootstrap URL. They do not need the same Wi-Fi.');
    this.saveContact(bundle, false);
    await this.repo.save();
    this.refresh();
  }

  async acceptRequest(directId: string): Promise<void> {
    const contact = this.repo.getContact(directId);
    if (!contact) return;
    this.repo.setContactAccepted(directId, true);
    await this.repo.save();
    await this.openConversation(directId);
  }

  async declineRequest(directId: string): Promise<void> {
    this.repo.blockContact(directId, Date.now());
    await this.repo.save();
    if (useAppStore.getState().openedDirectId === directId) {
      useAppStore.getState().setSnapshot({ openedDirectId: null });
    }
    this.refresh();
  }

  async setVerified(directId: string, verified: boolean): Promise<void> {
    this.repo.setContactVerified(directId, verified);
    await this.repo.save();
    this.refresh();
  }

  async block(directId: string): Promise<void> {
    this.repo.blockContact(directId, Date.now());
    await this.repo.save();
    this.refresh();
  }

  async removeContact(directId: string): Promise<void> {
    this.repo.removeContact(directId);
    await this.repo.save();
    this.refresh();
  }

  async send(directId: string, body: string): Promise<void> {
    const engine = this.engine;
    const saved = this.repo.getContact(directId);
    const contact = this.contactPublic(directId);
    if (!engine || !contact || !saved) throw new Error('That contact is not on this device.');
    if (!saved.accepted) throw new Error('Accept the message request before replying.');
    this.refreshPeer(directId, 'connecting');
    const fresh = this.discovered.get(directId);
    if (fresh && fresh.agreementKey !== saved.agreementPublic) {
      this.saveContact(fresh, saved.verified, saved.accepted);
    }
    try {
      await engine.sendText({ recipient: this.contactPublic(directId) ?? contact, body });
      await this.repo.save();
    } finally {
      this.refresh();
    }
  }

  async openConversation(directId: string): Promise<void> {
    const conversationId = `conv_${directId}`;
    this.repo.clearUnread(conversationId);
    const engine = this.engine;
    const contact = this.contactPublic(directId);
    if (engine && contact && this.repo.getContact(directId)?.accepted) {
      const unread = this.repo.listMessages(conversationId).filter((message) => message.direction === 'incoming' && message.status !== 'read');
      await engine.markRead(contact, unread.map((message) => message.id));
    }
    useAppStore.getState().setSnapshot({ openedDirectId: directId });
    await this.repo.save();
    this.refresh();
  }

  async wipeMessages(): Promise<void> {
    this.repo.wipeMessages();
    await this.repo.save();
    this.refresh();
  }

  async revokeCurrentDevice(): Promise<void> {
    const record = this.repo.getIdentity();
    if (!record) return;
    const device = this.repo.listDevices().find((item) => item.deviceId === record.deviceId);
    if (!device) return;
    this.repo.revokeDevice(device.id, Date.now());
    await this.repo.save();
    this.refresh();
  }

  updatePreferences(patch: Partial<Preferences>): void {
    this.preferences = { ...this.preferences, ...patch };
    if (!this.preferences.relayEnabled) this.preferences.relayStorage = false;
    this.relay.configure({ enabled: this.preferences.relayEnabled, storage: this.preferences.relayStorage });
    this.router.setRelayEnabled(this.preferences.relayEnabled);
    savePreferences(this.preferences);
    if (patch.signalingUrl !== undefined) this.bootstrap?.reconnect();
    if (this.preferences.relayEnabled) this.relay.attach(this.repo.getIdentity()?.directId ?? '');
    this.refresh();
  }

  refresh(): void {
    const record = this.repo.getIdentity();
    const contacts = this.repo.listContacts();
    const peerTransport: Record<string, 'direct' | 'relay' | 'offline' | 'connecting' | 'present'> = {};
    for (const contact of contacts) {
      peerTransport[contact.directId] = this.rtc?.isConnected(contact.directId)
        ? 'direct'
        : this.mesh.online(contact.directId)
          ? 'present'
          : this.preferences.relayEnabled && (this.relay.live(contact.directId) || this.preferences.relayStorage)
            ? 'relay'
            : 'offline';
    }
    const opened = useAppStore.getState().openedDirectId;
    const messages = { ...useAppStore.getState().messages };
    if (opened) messages[`conv_${opened}`] = this.repo.listMessages(`conv_${opened}`);
    for (const conversation of this.repo.listConversations()) {
      if (conversation.unread > 0 || conversation.id === `conv_${opened}`) {
        messages[conversation.id] = this.repo.listMessages(conversation.id);
      }
    }
    useAppStore.getState().setSnapshot({
      identity: record && this.keys ? this.view(record) : null,
      conversations: this.repo.listConversations(),
      contacts,
      messages,
      peerTransport,
      preferences: this.preferences,
      network: this.networkView(),
    });
  }

  private async persistIdentity(keys: IdentityKeys, name: string, device: string, previous: Uint8Array[], existingId?: string): Promise<void> {
    const identity = toPublicIdentity(keys, name || 'Member', device);
    await this.vault.set('identity.seed', keys.seed);
    await this.vault.set('identity.agreement', keys.agreementSecret);
    await this.vault.set('identity.device', utf8(device));
    await this.vault.set('identity.previous', encodeSecretList(previous));
    this.previous = previous;
    const record: IdentityRecord = {
      id: existingId ?? `id_${identity.directId}`,
      directId: identity.directId,
      did: identity.did,
      displayName: identity.displayName,
      agreementPublic: publicKeyMaterial(identity.agreementPublic),
      signingPublic: publicKeyMaterial(identity.signingPublic),
      agreementSignature: publicKeyMaterial(identity.agreementSignature),
      fingerprint: identity.fingerprint,
      deviceId: device,
      createdAt: Date.now(),
    };
    this.repo.transaction(() => {
      if (existingId || this.repo.getIdentity()) {
        this.repo.updateDisplayName(record.displayName);
        this.repo.updateIdentityKeys(record);
      } else {
        this.repo.insertIdentity(record);
        this.repo.insertDevice({
          id: `device_${device}`,
          identityId: record.id,
          deviceId: device,
          label: 'This device',
          publicKey: record.agreementPublic,
          createdAt: record.createdAt,
          revokedAt: null,
          lastSeenAt: record.createdAt,
        });
      }
    });
  }

  private activate(keys: IdentityKeys, record: IdentityRecord): void {
    this.keys = keys;
    this.unregister?.();
    this.rtc?.close();
    this.bootstrap?.stop();
    void this.localLink?.disconnect(record.directId);
    const local = new LocalTransport(record.directId, this.mesh);
    this.localLink = local;
    const bootstrap = new DirectBootstrap(() => resolveBootstrapUrl(this.preferences.signalingUrl));
    this.bootstrap = bootstrap;
    bootstrap.start(record.directId);
    const rtc = typeof RTCPeerConnection === 'undefined'
      ? null
      : new WebRTCTransport(record.directId, bootstrap, browserPeerConnectionFactory, 6_000);
    this.rtc = rtc;
    this.router.useDirect(rtc ? [rtc, local] : [local]);
    const identity = (): LocalIdentity | null => {
      if (!this.keys) return null;
      const current = this.repo.getIdentity();
      if (!current) return null;
      return {
        directId: current.directId,
        deviceId: current.deviceId,
        cipher: createPeerCipher(this.keys, this.previous),
      };
    };
    this.engine = new DeliveryEngine({
      store: this.repo,
      router: {
        send: async (peerId, payload) => {
          const result = await this.router.send(peerId, payload);
          const attempts = [...useAppStore.getState().network.attempts, {
            ok: result.kind !== 'queued',
            transport: result.kind,
            at: Date.now(),
          }].slice(-12);
          useAppStore.getState().setSnapshot({
            network: {
              ...useAppStore.getState().network,
              attempts,
              lastSuccess: result.kind === 'direct' && result.transport === 'webrtc' ? Date.now() : useAppStore.getState().network.lastSuccess,
              activeTransport: result.kind === 'direct'
                ? (result.transport === 'webrtc' ? 'WebRTC' : 'Sealed mailbox')
                : result.kind === 'relay' ? 'Distributed relay' : useAppStore.getState().network.activeTransport,
            },
          });
          return result;
        },
      },
      identity,
      contact: (directId) => this.contactPublic(directId),
      clock: { now: () => Date.now() },
      ids: { next: (prefix) => `${prefix}_${crypto.randomUUID().replaceAll('-', '')}` },
      logger: createLogger(),
      onChange: () => this.refresh(),
    });
    const receive = (peer: string, payload: Uint8Array) => {
      void this.acceptPayload(peer, payload);
    };
    const stopLocal = local.subscribe(receive);
    const stopRtc = rtc?.subscribe(receive);
    this.unregister = () => {
      stopLocal();
      stopRtc?.();
    };
    this.relay.subscribe((peer, payload) => {
      void this.acceptPayload(peer, payload);
    });
    this.relay.attach(record.directId);
    this.repo.touchDevice(record.deviceId, Date.now());
  }

  private publish(): void {
    const record = this.repo.getIdentity();
    if (!record || !this.keys) return;
    const identity = toPublicIdentity(this.keys, record.displayName, record.deviceId);
    const bundle = encodeBundle(createBundle(identity));
    this.mesh.publishBundle(bundle);
    this.bootstrap?.announce(bundle);
  }

  private start(): void {
    if (this.timer) clearInterval(this.timer);
    const tick = () => {
      if (!this.preferences.backgroundDelivery && document.visibilityState === 'hidden') return;
      void this.engine?.flush().then(() => this.repo.save());
      this.refresh();
    };
    this.timer = setInterval(tick, 2000);
    if (typeof document !== 'undefined') document.addEventListener('visibilitychange', tick);
    void this.engine?.flush();
  }

  private async acceptPayload(peer: string, payload: Uint8Array): Promise<void> {
    await this.noteSender(peer);
    await this.engine?.receive(payload, peer);
    await this.repo.save();
    this.refresh();
  }

  private async noteSender(peerId: string): Promise<void> {
    if (!peerId || peerId === 'relay' || peerId === this.repo.getIdentity()?.directId) return;
    if (this.repo.getContact(peerId)) return;
    if (!this.discovered.has(peerId)) await this.mesh.sync();
    if (!this.discovered.has(peerId)) {
      await this.waitForBootstrap();
      try {
        const published = await this.bootstrap?.lookup(peerId);
        if (published) this.ingestBundle(published);
      } catch {
        return;
      }
    }
    const bundle = this.discovered.get(peerId);
    if (!bundle) return;
    this.saveContact(bundle, false, false);
  }

  private saveContact(bundle: PublicBundle, verified: boolean, accepted = true): void {
    const self = this.repo.getIdentity();
    if (self && bundle.directId === self.directId) throw new Error('This DIRECT ID belongs to this device.');
    const existing = this.repo.getContact(bundle.directId);
    this.repo.upsertContact({
      id: existing?.id ?? `contact_${bundle.directId}`,
      directId: bundle.directId,
      did: bundle.did,
      displayName: bundle.name || bundle.directId,
      agreementPublic: bundle.agreementKey,
      signingPublic: bundle.signingKey,
      agreementSignature: bundle.agreementSig,
      fingerprint: bundle.fingerprint,
      deviceId: bundle.deviceId,
      verified: existing ? existing.verified && existing.fingerprint === bundle.fingerprint : verified,
      blocked: false,
      accepted: Boolean(accepted || existing?.accepted),
      createdAt: existing?.createdAt ?? Date.now(),
    });
    this.repo.recordSession(bundle.directId, bundle.agreementKey, Date.now());
  }

  private contactPublic(directId: string): ContactPublic | null {
    const contact = this.repo.getContact(directId);
    if (!contact) return null;
    return {
      directId: contact.directId,
      signingPublic: publicKeyBytes(contact.signingPublic),
      agreementPublic: publicKeyBytes(contact.agreementPublic),
    };
  }

  private view(record: IdentityRecord): IdentityView {
    return {
      directId: record.directId,
      did: record.did,
      deviceId: record.deviceId,
      displayName: record.displayName,
      fingerprint: record.fingerprint,
      bundle: encodeBundle(
        createBundle(
          toPublicIdentity(this.keys!, record.displayName, record.deviceId),
        ),
      ),
    };
  }

  private ingestBundle(serialized: string): void {
    try {
      const bundle = parseBundle(serialized);
      if (bundle.directId === this.repo.getIdentity()?.directId) return;
      this.discovered.set(bundle.directId, bundle);
      this.kad.add({
        id: discoveryNodeId(bundle.directId),
        peerId: bundle.directId,
        addrs: ['/direct/mesh'],
        lastSeen: Date.now(),
      });
      const existing = this.repo.getContact(bundle.directId);
      if (existing && existing.agreementPublic !== bundle.agreementKey) {
        this.saveContact(bundle, existing.verified, existing.accepted);
        void this.repo.save();
      }
    } catch {
      // Unsigned or altered discovery records are ignored.
    }
  }

  private networkView(): NetworkView {
    const connection = (navigator as Navigator & { connection?: { effectiveType?: string; type?: string } }).connection;
    const peers = this.mesh.knownPeers().length;
    const directPeers = this.repo.listContacts().filter((contact) => this.rtc?.isConnected(contact.directId)).length;
    const bootstrap = this.bootstrap;
    return {
      online: typeof navigator === 'undefined' ? true : navigator.onLine,
      directAvailable: this.rtc !== null || peers > 0,
      activeTransport: directPeers > 0 ? 'WebRTC' : peers > 0 ? 'Sealed mailbox' : 'Idle',
      discovery: !bootstrap ? 'Waiting for an identity' : bootstrap.state === 'open' ? 'Shared bootstrap' : 'Connecting to bootstrap',
      bootstrap: bootstrap?.state === 'open' ? bootstrap.currentUrl : bootstrap ? `Reconnecting · ${bootstrap.currentUrl || 'waiting for an address'}` : 'Not started',
      peers: Math.max(peers, directPeers),
      relay: !this.preferences.relayEnabled ? 'Off' : this.preferences.relayStorage ? 'On · temporary storage' : 'On · live only',
      lastSuccess: useAppStore.getState().network.lastSuccess,
      networkType: connection?.type || connection?.effectiveType || 'Unknown',
      attempts: useAppStore.getState().network.attempts.slice(-12),
      kadPeers: this.kad.size,
      libp2p: 'Interface ready. js-libp2p is not bundled: Hermes does not provide the Node APIs current kad-dht transports expect.',
    };
  }

  private waitForBootstrap(): Promise<void> {
    const started = Date.now();
    return new Promise((resolve) => {
      const timer = setInterval(() => {
        if (!this.bootstrap || this.bootstrap.state === 'open' || Date.now() - started > 3_000) {
          clearInterval(timer);
          resolve();
        }
      }, 50);
    });
  }

  private refreshPeer(directId: string, status: 'connecting'): void {
    useAppStore.getState().setSnapshot({
      peerTransport: { ...useAppStore.getState().peerTransport, [directId]: status },
    });
  }

  private requireRecord(): IdentityRecord {
    const record = this.repo.getIdentity();
    if (!record) throw new Error('Identity record was not saved.');
    return record;
  }
}

export async function bootDirect(wasmBinary: Uint8Array): Promise<DirectController> {
  const controller = await DirectController.boot(wasmBinary);
  useAppStore.getState().setBooting(false);
  return controller;
}
