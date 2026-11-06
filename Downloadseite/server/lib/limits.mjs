// In-memory limits: request and byte rates, parallel downloads and daily traffic.
// Every map is bounded, so a flood of new addresses cannot exhaust the memory.

/** A Map that forgets its oldest entry once it holds `maxSize` keys. */
export class LruMap extends Map {
  constructor(maxSize) {
    super();
    this.maxSize = maxSize;
  }

  set(key, value) {
    if (super.has(key)) super.delete(key);
    else if (this.size >= this.maxSize) super.delete(this.keys().next().value);
    return super.set(key, value);
  }
}

/** Token bucket per key: `capacity` requests at once, then `perSecond` on average. */
export class TokenBucket {
  constructor({ capacity, perSecond, maxKeys = 50_000, clock = Date.now }) {
    this.capacity = capacity;
    this.perSecond = perSecond;
    this.clock = clock;
    this.buckets = new LruMap(maxKeys);
  }

  take(key, cost = 1) {
    const now = this.clock();
    const bucket = this.buckets.get(key) ?? { tokens: this.capacity, at: now };
    bucket.tokens = Math.min(this.capacity, bucket.tokens + ((now - bucket.at) / 1000) * this.perSecond);
    bucket.at = now;
    let result;
    if (bucket.tokens >= cost) {
      bucket.tokens -= cost;
      result = { ok: true, retryAfter: 0 };
    } else {
      result = { ok: false, retryAfter: Math.max(1, Math.ceil((cost - bucket.tokens) / this.perSecond)) };
    }
    this.buckets.set(key, bucket);
    return result;
  }

  /** What take() would answer right now, without taking anything. */
  peek(key, cost = 1) {
    const bucket = this.buckets.get(key);
    const tokens = bucket ? Math.min(this.capacity, bucket.tokens + ((this.clock() - bucket.at) / 1000) * this.perSecond) : this.capacity;
    if (tokens >= cost) return { ok: true, retryAfter: 0 };
    return { ok: false, retryAfter: Math.max(1, Math.ceil((cost - tokens) / this.perSecond)) };
  }

  /** Takes `amount` whatever is left, for costs known only afterwards: the bucket may go into debt. */
  spend(key, amount) {
    const now = this.clock();
    const bucket = this.buckets.get(key) ?? { tokens: this.capacity, at: now };
    bucket.tokens = Math.min(this.capacity, bucket.tokens + ((now - bucket.at) / 1000) * this.perSecond) - amount;
    bucket.at = now;
    this.buckets.set(key, bucket);
  }

  /** Drops buckets that have refilled completely (they behave like new ones). */
  sweep() {
    const now = this.clock();
    for (const [key, bucket] of this.buckets) {
      if (bucket.tokens + ((now - bucket.at) / 1000) * this.perSecond >= this.capacity) this.buckets.delete(key);
    }
  }
}

/**
 * At most `limit` events per key within a sliding window, estimated from two fixed
 * windows (the current one and the share of the previous one that still overlaps).
 * Three numbers per key, however many events: the memory stays small under a flood.
 */
export class WindowCounter {
  constructor({ limit, windowMs, maxKeys = 50_000, clock = Date.now }) {
    this.limit = limit;
    this.windowMs = windowMs;
    this.clock = clock;
    this.counts = new LruMap(maxKeys);
  }

  #state(key, now) {
    const start = Math.floor(now / this.windowMs) * this.windowMs;
    const state = this.counts.get(key) ?? { start, current: 0, previous: 0 };
    if (state.start !== start) {
      state.previous = start - state.start === this.windowMs ? state.current : 0;
      state.current = 0;
      state.start = start;
    }
    return state;
  }

  /** Whether one more event is allowed now (does not record it). */
  check(key) {
    const now = this.clock();
    const state = this.#state(key, now);
    const elapsed = (now - state.start) / this.windowMs;
    const estimate = state.current + state.previous * (1 - elapsed);
    if (estimate + 1 <= this.limit) return { ok: true, retryAfter: 0 };
    const room = this.limit - 1; // what may already be counted when one more event comes
    let waitMs;
    if (state.current <= room && state.previous > 0) {
      // Still in this window, as soon as enough of the previous window's share has faded.
      waitMs = (1 - (room - state.current) / state.previous) * this.windowMs - (now - state.start);
    } else {
      // In the next window, once enough of this window's share has faded there.
      const fade = state.current > 0 ? Math.max(0, 1 - room / state.current) : 0;
      waitMs = state.start + this.windowMs - now + fade * this.windowMs;
    }
    return { ok: false, retryAfter: Math.max(1, Math.ceil(waitMs / 1000)) };
  }

  record(key, amount = 1) {
    const now = this.clock();
    const state = this.#state(key, now);
    state.current += amount;
    this.counts.set(key, state);
  }

  sweep() {
    const now = this.clock();
    for (const [key, state] of this.counts) {
      if (now - state.start >= 2 * this.windowMs) this.counts.delete(key);
    }
  }
}

/** A daily allowance per key (bytes per address and day, Swiss time); 0 = unlimited. */
export class DailyQuota {
  constructor({ limit, maxKeys = 50_000, clock = Date.now }) {
    this.limit = limit;
    this.clock = clock;
    this.used = new LruMap(maxKeys);
  }

  #entry(key) {
    const day = dayKey(this.clock());
    const entry = this.used.get(key);
    return entry && entry.day === day ? entry : { day, amount: 0 };
  }

  allows(key) {
    return !this.limit || this.#entry(key).amount < this.limit;
  }

  add(key, amount) {
    if (!this.limit || !amount) return;
    const entry = this.#entry(key);
    entry.amount += amount;
    this.used.set(key, entry);
  }

  sweep() {
    const day = dayKey(this.clock());
    for (const [key, entry] of this.used) if (entry.day !== day) this.used.delete(key);
  }
}

/** Parallel downloads: at most `perKey` per address and `total` overall. */
export class ConcurrencyGate {
  constructor({ perKey, total }) {
    this.perKey = perKey;
    this.total = total;
    this.active = 0;
    this.byKey = new Map();
  }

  /** Whether `enter(key)` would succeed right now. */
  hasRoom(key) {
    return this.active < this.total && (this.byKey.get(key) ?? 0) < this.perKey;
  }

  /** A release function, or null when the gate is full. */
  enter(key) {
    const mine = this.byKey.get(key) ?? 0;
    if (this.active >= this.total || mine >= this.perKey) return null;
    this.active += 1;
    this.byKey.set(key, mine + 1);
    let released = false;
    return () => {
      if (released) return;
      released = true;
      this.active -= 1;
      const left = (this.byKey.get(key) ?? 1) - 1;
      if (left <= 0) this.byKey.delete(key);
      else this.byKey.set(key, left);
    };
  }
}

const dayFormat = new Intl.DateTimeFormat('en-CA', {
  timeZone: 'Europe/Zurich',
  year: 'numeric',
  month: '2-digit',
  day: '2-digit',
});

/** "2026-10-14" in Swiss time. */
export function dayKey(time = Date.now()) {
  return dayFormat.format(time);
}

/** Bytes sent per day (Swiss time); 0 = no budget. */
export class DailyBudget {
  constructor({ bytesPerDay, clock = Date.now }) {
    this.bytesPerDay = bytesPerDay;
    this.clock = clock;
    this.day = dayKey(clock());
    this.used = 0;
  }

  #roll() {
    const today = dayKey(this.clock());
    if (today !== this.day) {
      this.day = today;
      this.used = 0;
    }
  }

  allows() {
    if (!this.bytesPerDay) return true;
    this.#roll();
    return this.used < this.bytesPerDay;
  }

  add(bytes) {
    this.#roll();
    this.used += bytes;
  }
}

/**
 * The slowest a running download may get before it is cut off (bytes per second, 0 = no check).
 * Normally `floor`, or half a fair share of the bandwidth if that is less. When the slots run
 * short, half a fair share counts even if that is more: holding a slot then costs real bandwidth.
 */
export function downloadFloor({ floor, laneRate, perDownload, active, slots }) {
  if (!floor) return 0;
  let minimum = floor;
  if (laneRate) {
    const halfShare = (laneRate / Math.max(1, active)) * 0.5;
    minimum = active >= slots * 0.75 ? halfShare : Math.min(floor, halfShare);
  }
  return perDownload ? Math.min(minimum, perDownload * 0.5) : minimum;
}
