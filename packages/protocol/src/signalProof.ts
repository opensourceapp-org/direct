import { utf8 } from '@direct/shared';

export const SIGNAL_PROOF_PREFIX = 'DIRECT-SIGNAL/1';

/** Bytes the device signs to prove it holds the DIRECT ID's signing key for this bootstrap nonce. */
export function signalProofMessage(nonce: string, directId: string): Uint8Array {
  return utf8(`${SIGNAL_PROOF_PREFIX}\n${nonce}\n${directId}`);
}
