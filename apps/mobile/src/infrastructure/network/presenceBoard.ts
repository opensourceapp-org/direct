const DIRECT_ID = /^dir_[0-9A-HJKMNP-TV-Z]{16}$/;
const FRESH_MS = 12_000;
const MAIL_TTL_MS = 30_000;

export type PresencePeer = { peerId: string; bundle: string; at: number };
export type PresenceMail = { from: string; payload: string };

/**
 * In-memory public presence for one preview process.
 * Stores signed identity bundles and sealed payloads only. Nothing is written to disk.
 */
export class PresenceBoard {
  private readonly peers = new Map<string, { bundle: string; at: number }>();
  private readonly mail = new Map<string, { from: string; payload: string; at: number }[]>();

  constructor(private readonly now: () => number = () => Date.now()) {}

  hello(peerId: string, bundle: string): boolean {
    if (!DIRECT_ID.test(peerId)) return false;
    if (bundle.length < 32 || bundle.length > 8192) return false;
    if (!bundle.includes(`"directId":"${peerId}"`)) return false;
    this.peers.set(peerId, { bundle, at: this.now() });
    return true;
  }

  deliver(from: string, to: string, payload: string): boolean {
    if (!DIRECT_ID.test(from) || !DIRECT_ID.test(to) || from === to) return false;
    if (payload.length < 8 || payload.length > 96_000 || !/^[A-Za-z0-9_-]+$/.test(payload)) return false;
    const queued = this.mail.get(to) ?? [];
    queued.push({ from, payload, at: this.now() });
    while (queued.length > 40) queued.shift();
    this.mail.set(to, queued);
    return true;
  }

  pull(peerId: string): { peers: PresencePeer[]; mail: PresenceMail[] } {
    const now = this.now();
    for (const [id, row] of this.peers) {
      if (now - row.at > FRESH_MS) this.peers.delete(id);
    }
    const peers = [...this.peers.entries()]
      .filter(([id]) => id !== peerId)
      .map(([id, row]) => ({ peerId: id, bundle: row.bundle, at: row.at }));
    const queued = (this.mail.get(peerId) ?? []).filter((item) => now - item.at <= MAIL_TTL_MS);
    this.mail.delete(peerId);
    return { peers, mail: queued.map(({ from, payload }) => ({ from, payload })) };
  }
}
