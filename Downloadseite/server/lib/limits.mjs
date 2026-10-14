// In-memory limits: request rates, download counts, temporary blocks, parallel
// downloads and a daily traffic budget. Every map is bounded, so a flood of new
// addresses cannot exhaust the memory.

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

/**
 * Penalty points per key that fade away over `decayMs` (a full threshold per window).
 * Reaching the threshold blocks the key for `banMs`.
 */
export class PenaltyBox {
  constructor({ threshold, decayMs, banMs, maxKeys = 50_000, clock = Date.now }) {
    this.threshold = threshold;
    this.decayMs = decayMs;
    this.banMs = banMs;
    this.clock = clock;
    this.scores = new LruMap(maxKeys);
    this.bans = new LruMap(maxKeys);
  }

  /** Adds points; returns true when this blocked the key. */
  add(key, points) {
    const now = this.clock();
    const entry = this.scores.get(key) ?? { score: 0, at: now };
    entry.score = Math.max(0, entry.score - ((now - entry.at) / this.decayMs) * this.threshold) + points;
    entry.at = now;
    if (entry.score >= this.threshold) {
      this.scores.delete(key);
      this.bans.set(key, now + this.banMs);
      return true;
    }
    this.scores.set(key, entry);
    return false;
  }

  /** Milliseconds the key stays blocked (0 = not blocked). */
  blockedFor(key) {
    const until = this.bans.get(key);
    if (until === undefined) return 0;
    const left = until - this.clock();
    if (left <= 0) {
      this.bans.delete(key);
      return 0;
    }
    return left;
  }

  get blockedCount() {
    return this.bans.size;
  }

  sweep() {
    const now = this.clock();
    for (const [key, until] of this.bans) if (until <= now) this.bans.delete(key);
    for (const [key, entry] of this.scores) {
      if (entry.score - ((now - entry.at) / this.decayMs) * this.threshold <= 0) this.scores.delete(key);
    }
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

/** Seconds until midnight in Zurich (rounded up, at least 60). */
export function secondsUntilTomorrow(time = Date.now()) {
  const today = dayKey(time);
  let probe = time;
  // Step forward in 10-minute steps until the date changes, then refine to the minute.
  while (dayKey(probe) === today) probe += 10 * 60_000;
  probe -= 10 * 60_000;
  while (dayKey(probe) === today) probe += 60_000;
  return Math.max(60, Math.ceil((probe - time) / 1000));
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
