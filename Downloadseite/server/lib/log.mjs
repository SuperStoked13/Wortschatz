// One JSON object per line on stdout/stderr (journald and Docker collect and rotate it).
// Addresses are only logged shortened (see net.mjs anonymizeIp).

const LEVELS = { debug: 10, info: 20, warn: 30, error: 40, silent: 100 };

export function createLogger(level = 'info', { stdout = process.stdout, stderr = process.stderr } = {}) {
  const min = LEVELS[level] ?? LEVELS.info;
  const write = (name, msg, fields) => {
    if (LEVELS[name] < min) return;
    const line = JSON.stringify({ t: new Date().toISOString(), level: name, msg, ...fields });
    (LEVELS[name] >= LEVELS.warn ? stderr : stdout).write(`${line}\n`);
  };
  return {
    debug: (msg, fields) => write('debug', msg, fields),
    info: (msg, fields) => write('info', msg, fields),
    warn: (msg, fields) => write('warn', msg, fields),
    error: (msg, fields) => write('error', msg, fields),
  };
}
