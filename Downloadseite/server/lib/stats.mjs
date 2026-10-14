// Download counter: completed downloads per day and platform, nothing about the people
// (data/downloads.json). Written at most every few seconds, atomically.

import fsp from 'node:fs/promises';
import path from 'node:path';
import { dayKey } from './limits.mjs';

const KEEP_DAYS = 400;

export async function createStats(dataDir, log) {
  const file = path.join(dataDir, 'downloads.json');
  let data = {};
  try {
    const parsed = JSON.parse(await fsp.readFile(file, 'utf8'));
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) data = parsed;
  } catch (error) {
    if (error.code !== 'ENOENT') log.warn('stats.read', { message: error.message });
  }

  let timer = null;
  let writing = Promise.resolve();

  async function write() {
    timer = null;
    const days = Object.keys(data).sort();
    for (const day of days.slice(0, Math.max(0, days.length - KEEP_DAYS))) delete data[day];
    const json = `${JSON.stringify(data, null, 2)}\n`;
    writing = writing.then(async () => {
      try {
        await fsp.mkdir(dataDir, { recursive: true });
        const temp = `${file}.${process.pid}.tmp`;
        await fsp.writeFile(temp, json, { mode: 0o640 });
        await fsp.rename(temp, file);
      } catch (error) {
        log.warn('stats.write', { message: error.message });
      }
    });
    return writing;
  }

  return {
    count(platform) {
      const day = dayKey();
      data[day] ??= {};
      data[day][platform] = (data[day][platform] ?? 0) + 1;
      if (!timer) {
        timer = setTimeout(write, 5000);
        timer.unref();
      }
    },
    async flush() {
      if (timer) {
        clearTimeout(timer);
        await write();
      }
      await writing;
    },
    snapshot: () => structuredClone(data),
  };
}
