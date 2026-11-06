// Client addresses: which proxy to trust, the real client IP, a rate-limit key per
// client, and the shortened form that goes into logs.

import net from 'node:net';

const LOOPBACK = [
  ['127.0.0.0', 8, 'ipv4'],
  ['::1', 128, 'ipv6'],
];

const PRIVATE = [
  ...LOOPBACK,
  ['10.0.0.0', 8, 'ipv4'],
  ['172.16.0.0', 12, 'ipv4'],
  ['192.168.0.0', 16, 'ipv4'],
  ['fc00::', 7, 'ipv6'],
  ['fe80::', 10, 'ipv6'],
];

/** "1.2.3.4", "::ffff:1.2.3.4", "[::1]", "fe80::1%en0" → canonical address or "". */
export function normalizeIp(value) {
  if (!value) return '';
  let ip = String(value).trim();
  if (ip.startsWith('[')) {
    const end = ip.indexOf(']');
    if (end === -1) return '';
    ip = ip.slice(1, end);
  }
  const zone = ip.indexOf('%');
  if (zone !== -1) ip = ip.slice(0, zone);
  if (/^::ffff:/i.test(ip) && net.isIPv4(ip.slice(7))) ip = ip.slice(7);
  return net.isIP(ip) ? ip.toLowerCase() : '';
}

/**
 * The proxies whose X-Forwarded-For header is believed.
 * "loopback" (Caddy on the same machine), "private" (Docker networks), "none",
 * or a comma-separated list of addresses and CIDR ranges.
 */
export function buildTrust(spec) {
  const list = new net.BlockList();
  const value = String(spec || 'loopback').trim().toLowerCase();
  if (value === 'none') return list;
  const add = ([address, prefix, type]) => list.addSubnet(address, prefix, type);
  if (value === 'loopback') {
    LOOPBACK.forEach(add);
    return list;
  }
  if (value === 'private') {
    PRIVATE.forEach(add);
    return list;
  }
  for (const part of value.split(',').map((p) => p.trim()).filter(Boolean)) {
    if (part === 'loopback') {
      LOOPBACK.forEach(add);
      continue;
    }
    if (part === 'private') {
      PRIVATE.forEach(add);
      continue;
    }
    const [address, bits] = part.split('/');
    const ip = normalizeIp(address);
    if (!ip) throw new Error(`TRUST_PROXY: "${part}" ist keine gültige Adresse.`);
    const type = net.isIPv6(ip) ? 'ipv6' : 'ipv4';
    const max = type === 'ipv6' ? 128 : 32;
    const prefix = bits === undefined ? max : Number(bits);
    if (!Number.isInteger(prefix) || prefix < 0 || prefix > max) {
      throw new Error(`TRUST_PROXY: "${part}" hat eine ungültige Präfixlänge.`);
    }
    list.addSubnet(ip, prefix, type);
  }
  return list;
}

function isTrusted(trust, ip) {
  return trust.check(ip, net.isIPv6(ip) ? 'ipv6' : 'ipv4');
}

/**
 * The client's address. X-Forwarded-For only counts when the direct peer is a trusted
 * proxy; the list is then read from the right, and the first untrusted entry wins
 * (entries further left could be made up by the client).
 */
export function clientIp(req, trust) {
  const peer = normalizeIp(req.socket?.remoteAddress);
  if (!peer || !isTrusted(trust, peer)) return peer;
  const header = req.headers['x-forwarded-for'];
  if (!header) return peer;
  const hops = String(header).split(',');
  let leftmost = peer;
  for (let i = hops.length - 1; i >= 0; i--) {
    const ip = normalizeIp(hops[i]);
    if (!ip) return peer;
    if (!isTrusted(trust, ip)) return ip;
    leftmost = ip;
  }
  return leftmost;
}

/** The eight groups of an IPv6 address, each four hex digits. */
export function expandIpv6(ip) {
  let s = ip.toLowerCase();
  let embedded = null;
  const lastColon = s.lastIndexOf(':');
  if (s.indexOf('.', lastColon) !== -1) {
    const o = s.slice(lastColon + 1).split('.').map(Number);
    embedded = [((o[0] << 8) | o[1]).toString(16), ((o[2] << 8) | o[3]).toString(16)];
    s = `${s.slice(0, lastColon + 1)}0:0`;
  }
  let groups;
  const gap = s.indexOf('::');
  if (gap === -1) {
    groups = s.split(':');
  } else {
    const left = s.slice(0, gap) ? s.slice(0, gap).split(':') : [];
    const right = s.slice(gap + 2) ? s.slice(gap + 2).split(':') : [];
    groups = [...left, ...Array(8 - left.length - right.length).fill('0'), ...right];
  }
  if (embedded) {
    groups[6] = embedded[0];
    groups[7] = embedded[1];
  }
  return groups.map((g) => g.padStart(4, '0'));
}

/**
 * The key for limits and link binding: the IPv4 address, or the /56 network of an
 * IPv6 address. A household usually gets a /56 or /48 and can switch between its /64s at
 * will, so a /64 key would let one connection pose as hundreds of addresses.
 */
export function ipKey(ip) {
  if (!ip) return 'unknown';
  if (net.isIPv6(ip)) {
    const groups = expandIpv6(ip);
    return `${groups.slice(0, 3).join(':')}:${groups[3].slice(0, 2)}00::/56`;
  }
  return ip;
}

/**
 * The wider key for password guesses: a whole IPv6 /48 counts as one, because rotating through
 * its 256 /56s is free and each would otherwise get its own allowance of guesses.
 */
export function networkKey(ip) {
  return net.isIPv6(ip) ? `${expandIpv6(ip).slice(0, 3).join(':')}::/48` : ipKey(ip);
}

const LOOPBACK_LIST = (() => {
  const list = new net.BlockList();
  LOOPBACK.forEach(([address, prefix, type]) => list.addSubnet(address, prefix, type));
  return list;
})();

/** 127.0.0.0/8 or ::1. */
export function isLoopback(ip) {
  return Boolean(ip) && LOOPBACK_LIST.check(ip, net.isIPv6(ip) ? 'ipv6' : 'ipv4');
}

/** Shortened address for logs: 203.0.113.0 or 2001:db8:1::. */
export function anonymizeIp(ip) {
  if (net.isIPv4(ip)) return ip.replace(/\.\d+$/, '.0');
  if (net.isIPv6(ip)) {
    return `${expandIpv6(ip)
      .slice(0, 3)
      .map((g) => g.replace(/^0+(?=.)/, ''))
      .join(':')}::`;
  }
  return '-';
}
