import { createLogger } from './log';

test('logs omit secrets, plaintext, and raw keys', () => {
  const entries: unknown[] = [];
  const logger = createLogger((entry) => entries.push(entry));
  logger.info('message.sent', {
    messageId: 'msg_123',
    plaintext: 'meet at the north gate',
    signingSecret: new Uint8Array([1, 2, 3, 4]),
    mnemonic: 'abandon abandon abandon',
    status: 'pending',
  });
  const serialized = JSON.stringify(entries);
  expect(serialized).toContain('msg_123');
  expect(serialized).toContain('pending');
  expect(serialized).not.toContain('north gate');
  expect(serialized).not.toContain('abandon');
  expect(serialized).not.toContain('"1,2,3,4"');
});
