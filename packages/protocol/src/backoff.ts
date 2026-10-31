const DEFAULT_BASE_MS = 1000;
const DEFAULT_CAP_MS = 5 * 60 * 1000;

export function nextDelayMs(attempt: number, random: () => number = Math.random): number {
  const exponent = Math.max(0, attempt - 1);
  const exponential = Math.min(DEFAULT_CAP_MS, DEFAULT_BASE_MS * 2 ** exponent);
  const jitter = random() * exponential * 0.2;
  return Math.round(exponential + jitter);
}
