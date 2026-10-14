// Bandwidth limit shared by several downloads. Each chunk takes its bytes from the bucket;
// when the bucket runs into debt, the caller waits until the debt is paid off. Callers that
// arrive later see a bigger debt and wait longer, so concurrent downloads share the rate.

import { setTimeout as sleep } from 'node:timers/promises';

export class ByteRate {
  /** @param {number} bytesPerSecond 0 = unlimited */
  constructor(bytesPerSecond, { burstSeconds = 0.25, clock = () => performance.now() } = {}) {
    this.rate = bytesPerSecond;
    this.clock = clock;
    this.burst = Math.max(64 * 1024, bytesPerSecond * burstSeconds);
    this.tokens = this.burst;
    this.at = clock();
  }

  get enabled() {
    return this.rate > 0;
  }

  /** Resolves when `bytes` may be sent. Rejects with an AbortError when `signal` aborts. */
  async take(bytes, signal) {
    if (!this.rate) return;
    const now = this.clock();
    this.tokens = Math.min(this.burst, this.tokens + ((now - this.at) / 1000) * this.rate);
    this.at = now;
    this.tokens -= bytes;
    if (this.tokens >= 0) return;
    try {
      await sleep((-this.tokens / this.rate) * 1000, undefined, { signal });
    } catch (error) {
      // A download that stops gives its unsent share back.
      this.tokens += bytes;
      throw error;
    }
  }
}
