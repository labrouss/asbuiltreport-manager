// Authentication & User Management
const fs     = require('fs');
const path   = require('path');
const crypto = require('crypto');

const USERS_FILE      = '/etc/asbuiltreport/users.json';
const JWT_SECRET_FILE = '/etc/asbuiltreport/.jwt_secret';

// ── JWT secret ────────────────────────────────────────────────────────────────
function getJwtSecret() {
  try {
    const dir = path.dirname(JWT_SECRET_FILE);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    if (fs.existsSync(JWT_SECRET_FILE)) return fs.readFileSync(JWT_SECRET_FILE, 'utf8').trim();
    const secret = crypto.randomBytes(64).toString('hex');
    fs.writeFileSync(JWT_SECRET_FILE, secret, { mode: 0o600 });
    return secret;
  } catch (e) {
    // Fallback in-memory secret if filesystem not writable yet
    return crypto.randomBytes(64).toString('hex');
  }
}
const JWT_SECRET = getJwtSecret();

// ── JWT (no external deps) ────────────────────────────────────────────────────
function signJwt(payload, expiresInHours = 8) {
  const header = Buffer.from(JSON.stringify({ alg: 'HS256', typ: 'JWT' })).toString('base64url');
  const exp    = Math.floor(Date.now() / 1000) + expiresInHours * 3600;
  const body   = Buffer.from(JSON.stringify({ ...payload, exp, iat: Math.floor(Date.now() / 1000) })).toString('base64url');
  const sig    = crypto.createHmac('sha256', JWT_SECRET).update(`${header}.${body}`).digest('base64url');
  return `${header}.${body}.${sig}`;
}

function verifyJwt(token) {
  try {
    const [header, body, sig] = token.split('.');
    const expected = crypto.createHmac('sha256', JWT_SECRET).update(`${header}.${body}`).digest('base64url');
    if (sig !== expected) return null;
    const payload = JSON.parse(Buffer.from(body, 'base64url').toString());
    if (payload.exp < Math.floor(Date.now() / 1000)) return null;
    return payload;
  } catch (_) { return null; }
}

// ── Password hashing (PBKDF2) ─────────────────────────────────────────────────
async function hashPassword(password) {
  return new Promise((resolve, reject) => {
    const salt = crypto.randomBytes(32).toString('hex');
    crypto.pbkdf2(password, salt, 310000, 64, 'sha512', (err, key) => {
      if (err) reject(err);
      else resolve(`${salt}:${key.toString('hex')}`);
    });
  });
}

async function verifyPassword(password, hash) {
  return new Promise((resolve, reject) => {
    const [salt, key] = hash.split(':');
    crypto.pbkdf2(password, salt, 310000, 64, 'sha512', (err, dk) => {
      if (err) reject(err);
      else resolve(crypto.timingSafeEqual(Buffer.from(key, 'hex'), dk));
    });
  });
}

// ── TOTP (RFC 6238) ───────────────────────────────────────────────────────────
function generateTotpSecret() {
  return crypto.randomBytes(20).toString('hex').toUpperCase().substring(0, 32);
}

function base32Decode(str) {
  const alpha = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  let bits = 0, value = 0;
  const out = [];
  for (const c of str.toUpperCase().replace(/=/g, '')) {
    value = (value << 5) | alpha.indexOf(c);
    bits += 5;
    if (bits >= 8) { bits -= 8; out.push((value >>> bits) & 0xff); }
  }
  return Buffer.from(out);
}

function getTotpCode(secret, step) {
  const t = step ?? Math.floor(Date.now() / 1000 / 30);
  const buf = Buffer.alloc(8);
  buf.writeBigUInt64BE(BigInt(t));
  const hmac   = crypto.createHmac('sha1', base32Decode(secret)).update(buf).digest();
  const offset = hmac[hmac.length - 1] & 0xf;
  return ((hmac.readUInt32BE(offset) & 0x7fffffff) % 1000000).toString().padStart(6, '0');
}

function verifyTotp(secret, token) {
  const step = Math.floor(Date.now() / 1000 / 30);
  return [-1, 0, 1].some(d => getTotpCode(secret, step + d) === token);
}

function getTotpUri(secret, username, issuer = 'AsBuiltReport Manager') {
  return `otpauth://totp/${encodeURIComponent(issuer)}:${encodeURIComponent(username)}?secret=${secret}&issuer=${encodeURIComponent(issuer)}&algorithm=SHA1&digits=6&period=30`;
}

// ── User store ────────────────────────────────────────────────────────────────
function loadUsers() {
  try {
    if (fs.existsSync(USERS_FILE)) {
      const data = fs.readFileSync(USERS_FILE, 'utf8').trim();
      if (data) return JSON.parse(data);
    }
  } catch (e) {
    console.error('[Auth] Failed to load users.json:', e.message);
  }
  return [];
}

function saveUsers(users) {
  try {
    const dir = path.dirname(USERS_FILE);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(USERS_FILE, JSON.stringify(users, null, 2), { mode: 0o600 });
  } catch (e) {
    console.error('[Auth] Failed to save users.json:', e.message);
  }
}

function getUser(username) {
  return loadUsers().find(u => u.username === username);
}

function validatePassword(password) {
  const errors = [];
  if (password.length < 12)            errors.push('At least 12 characters');
  if (!/[A-Z]/.test(password))         errors.push('At least one uppercase letter');
  if (!/[a-z]/.test(password))         errors.push('At least one lowercase letter');
  if (!/[0-9]/.test(password))         errors.push('At least one number');
  if (!/[^A-Za-z0-9]/.test(password))  errors.push('At least one special character');
  return errors;
}

function requireAuth(req, res, next) {
  const auth = req.headers.authorization;
  if (!auth?.startsWith('Bearer ')) return res.status(401).json({ error: 'Unauthorized' });
  const payload = verifyJwt(auth.slice(7));
  if (!payload) return res.status(401).json({ error: 'Token expired or invalid' });
  req.user = payload;
  next();
}

async function seedDefaultAdmin() {
  const users = loadUsers();
  if (users.length === 0) {
    console.log('[Auth] No users found — creating default admin');
    const hash = await hashPassword('Admin@AsBuilt1!');
    const admin = {
      id:          crypto.randomUUID(),
      username:    'admin',
      hash,
      role:        'admin',
      totpSecret:  null,
      totpEnabled: false,
      createdAt:   new Date().toISOString(),
      mustChange:  true,
    };
    saveUsers([admin]);
    console.log('[Auth] Default admin created — username: admin  password: Admin@AsBuilt1!');
  } else {
    console.log(`[Auth] ${users.length} user(s) loaded from ${USERS_FILE}`);
  }
}

module.exports = {
  signJwt, verifyJwt, hashPassword, verifyPassword,
  generateTotpSecret, verifyTotp, getTotpUri,
  loadUsers, saveUsers, getUser, validatePassword,
  requireAuth, seedDefaultAdmin,
};
