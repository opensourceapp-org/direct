import { nextDelayMs } from './backoff';

test('retry delay grows exponentially and then caps', () => {
  expect(nextDelayMs(1, () => 0)).toBe(1000);
  expect(nextDelayMs(2, () => 0)).toBe(2000);
  expect(nextDelayMs(3, () => 0)).toBe(4000);
  expect(nextDelayMs(20, () => 0)).toBe(5 * 60 * 1000);
  expect(nextDelayMs(1, () => 1)).toBe(1200);
});
