const express = require('express');
const cors    = require('cors');
const { exec } = require('child_process');
const fs   = require('fs');
const path = require('path');
const http = require('http');
const { WebSocketServer } = require('ws');
const { loadSchedules, saveSchedules, nextRun, startScheduler } = require('./scheduler');
const {
  signJwt, hashPassword, verifyPassword, generateTotpSecret,
  verifyTotp, getTotpUri, loadUsers, saveUsers, getUser,
  validatePassword, requireAuth, seedDefaultAdmin,
} = require('./auth');

const app    = express();
const server = http.createServer(app);
const wss    = new WebSocketServer({ server });

app.use(cors());
app.use(express.json());

const REPORTS_DIR = process.env.REPORTS_DIR || '/var/www/reports';
const WORKER_URL  = process.env.WORKER_URL  || 'http://worker:8080';

// Ensure all required directories exist
[REPORTS_DIR, '/etc/asbuiltreport'].forEach(d => {
  if (!fs.existsSync(d)) { fs.mkdirSync(d, { recursive: true }); console.log(`[Server] Created directory: ${d}`); }
});

// WebSocket
wss.on('connection', (ws) => {
  console.log('[WS] Client connected');
  ws.on('message', (raw) => {
    try { const m = JSON.parse(raw); if (m.type === 'ping') ws.send(JSON.stringify({ type: 'pong' })); } catch (_) {}
  });
});

function broadcast(type, payload) {
  const msg = JSON.stringify({ type, payload, ts: Date.now() });
  wss.clients.forEach((c) => { if (c.readyState === 1) c.send(msg); });
}

// Stream newline-delimited text from a worker HTTP endpoint
function streamFromWorker(endpoint, body, onLine, onDone, onError) {
  const workerBase = new URL(WORKER_URL);
  const payload    = JSON.stringify(body);
  const opts = {
    hostname: workerBase.hostname,
    port:     workerBase.port || 8080,
    path:     endpoint,
    method:   'POST',
    headers:  { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) },
  };
  console.log(`[streamFromWorker] POST ${workerBase.hostname}:${workerBase.port || 8080}${endpoint}`);
  const req = http.request(opts, (res) => {
    console.log(`[streamFromWorker] Response status: ${res.statusCode} for ${endpoint}`);
    let buf = '';
    res.on('data', (chunk) => {
      buf += chunk.toString();
      const lines = buf.split('\n');
      buf = lines.pop();
      lines.forEach((l) => { if (l.trim()) onLine(l); });
    });
    res.on('end', () => { if (buf.trim()) onLine(buf); onDone(); });
  });
  req.on('error', (err) => onError(err.message));
  req.write(payload);
  req.end();
}

// Known modules registry — Linux-compatible modules only
const KNOWN_MODULES = [
  // ── VMware ─────────────────────────────────────────────────────────────────
  { id: 'VMware.vSphere',         name: 'VMware vSphere',             category: 'VMware',     icon: '🖥️', version: '2.0.0-beta1', description: 'vCenter, ESXi hosts, clusters, datastores and VMs.' },
  { id: 'VMware.ESXi',            name: 'VMware ESXi',                category: 'VMware',     icon: '🖥️', version: '1.1.4',       description: 'Standalone ESXi host configuration and hardware inventory.' },
  { id: 'VMware.Horizon',         name: 'VMware Horizon',             category: 'VMware',     icon: '💻', version: '1.1.6',       description: 'Horizon View pods, pools, farms and entitlements.' },
  { id: 'DellEMC.VxRail',        name: 'Dell EMC VxRail',            category: 'HCI',        icon: '🔧', version: '0.4.5',       description: 'VxRail cluster, nodes, networking and vSAN configuration.' },
  // ── Veeam ──────────────────────────────────────────────────────────────────
  { id: 'Veeam.VBR',             name: 'Veeam Backup & Replication', category: 'Backup',     icon: '🔒', version: '1.0.2',       description: 'Backup jobs, infrastructure, proxies and restore points.' },
  // ── Microsoft ──────────────────────────────────────────────────────────────
  { id: 'Microsoft.Azure',        name: 'Microsoft Azure',            category: 'Microsoft',  icon: '☁️', version: '0.2.0',       description: 'Azure subscriptions, resource groups, VMs and networking.' },
  { id: 'Microsoft.Intune',       name: 'Microsoft Intune',           category: 'Microsoft',  icon: '📱', version: '0.2.63',      description: 'Intune device compliance, config profiles, app management and security baselines.' },
  { id: 'Microsoft.EntraID',      name: 'Microsoft Entra ID',         category: 'Microsoft',  icon: '🔑', version: '0.1.21',      description: 'Entra ID (Azure AD) MFA, Conditional Access and identity security posture.' },
  { id: 'Microsoft.SharePoint',   name: 'Microsoft SharePoint Online',category: 'Microsoft',  icon: '📄', version: '0.1.0',       description: 'SharePoint Online sharing policies, compliance and storage quotas.' },
  { id: 'Microsoft.ExchangeOnline',name:'Microsoft Exchange Online',  category: 'Microsoft',  icon: '📧', version: '0.1.0',       description: 'Exchange Online transport rules, mail flow, anti-spam and DKIM/DMARC.' },
  { id: 'Microsoft.Purview',      name: 'Microsoft Purview',          category: 'Microsoft',  icon: '🛡️', version: '0.1.0',       description: 'Purview compliance configuration, DLP policies and information protection.' },
  // ── Storage ────────────────────────────────────────────────────────────────
  { id: 'NetApp.ONTAP',           name: 'NetApp ONTAP',               category: 'Storage',    icon: '🗄️', version: '0.6.13',      description: 'ONTAP clusters, SVMs, volumes, SnapMirror and S3.' },
  { id: 'PureStorage.FlashArray', name: 'Pure Storage FlashArray',    category: 'Storage',    icon: '⚡', version: '0.4.1',       description: 'FlashArray hosts, volumes, protection groups and replication.' },
  // ── HCI ────────────────────────────────────────────────────────────────────
  { id: 'Nutanix.PrismElement',   name: 'Nutanix Prism Element',      category: 'HCI',        icon: '🔧', version: '1.2.1',       description: 'Nutanix clusters, VMs, storage pools and protection domains.' },
  // ── Network / Security ─────────────────────────────────────────────────────
  { id: 'Fortinet.FortiGate',     name: 'Fortinet FortiGate',         category: 'Security',   icon: '🔥', version: '0.5.3',       description: 'FortiGate firewall policies, interfaces, VPNs and routing.' },
  { id: 'Aruba.ClearPass',        name: 'Aruba ClearPass',            category: 'Networking', icon: '📡', version: '0.1.1',       description: 'ClearPass policy manager, endpoints, services and auth sources.' },
  // ── DR / Replication ───────────────────────────────────────────────────────
  { id: 'Zerto.ZVM',             name: 'Zerto ZVM',                  category: 'DR',         icon: '♻️', version: '0.1.0-RC1',   description: 'Zerto ZVM virtual protection groups, VRAs, journals and failover plans.' },
  // ── VMware extras ─────────────────────────────────────────────────────────
  { id: 'VMware.RVTools', name: 'VMware RVTools Export', category: 'VMware', icon: '📊', version: '2.0', description: '27-tab RVTools replica — exports vInfo, vCPU, vMemory, vDisk, vNetwork, vHost, vCluster and more to Excel.' },
  // ── HPE ───────────────────────────────────────────────────────────────────
  { id: 'HPE.OneView',           name: 'HPE OneView',                category: 'Compute',    icon: '🟢', version: '10.00',       description: 'Server hardware, profiles, networks, enclosures and firmware via HPE OneView appliance.' },
  // ── System ─────────────────────────────────────────────────────────────────
  { id: 'System.Resources',      name: 'System Resources',           category: 'System',     icon: '📊', version: '0.1.3',       description: 'Cross-platform system resource documentation (CPU, memory, disk, network).' },
];

// Public version endpoint — use to confirm which build is running
app.get('/api/version', (req, res) => res.json({ version: '2.0.0', built: new Date().toISOString().slice(0,10), auth: true, scheduler: true }));

// ─── Protected API routes (require auth) ─────────────────────────────────────
app.get('/api/modules', requireAuth, async (req, res) => {
  try {
    const resp = await fetch(`${WORKER_URL}/installed-modules`).catch(() => null);
    const data = resp?.ok ? await resp.json() : { modules: [], versions: {} };
    // Defensive: handle both array and single-string response from worker
    const moduleArr = Array.isArray(data.modules) ? data.modules : (data.modules ? [data.modules] : []);
    const installed = new Set(moduleArr);
    res.json({ modules: KNOWN_MODULES.map((m) => ({ ...m, installed: installed.has(m.id), updateAvailable: false, version: data.versions?.[m.id] || null })) });
  } catch (_) {
    res.json({ modules: KNOWN_MODULES.map((m) => ({ ...m, installed: false })) });
  }
});

app.get('/api/health/dependencies', requireAuth, async (req, res) => {
  const runLocal = (cmd) => new Promise((resolve) => {
    exec(cmd, (err, stdout) => resolve({ ok: !err, version: stdout.trim() }));
  });
  let worker = {};
  try { const r = await fetch(`${WORKER_URL}/health`); if (r.ok) worker = await r.json(); } catch (_) {}
  const nodeDep = await runLocal('node --version');
  res.json({ dependencies: [
    { name: 'PowerShell 7',   required: true,  ok: !!worker.pwsh,              version: worker.pwsh || null },
    { name: 'Node.js',        required: true,  ok: nodeDep.ok,                 version: nodeDep.version },
    { name: 'Worker service', required: true,  ok: worker.status === 'ok',     version: worker.status === 'ok' ? `connected · pwsh ${worker.pwsh}` : null },
    { name: 'Graphviz',       required: false, ok: !!worker.graphviz,          version: worker.graphviz || null },
    { name: 'Pandoc',         required: false, ok: !!worker.pandoc,            version: worker.pandoc || null },
  ]});
});

app.get('/api/modules/:id/config', requireAuth, (req, res) => {
  const cfgPath = path.join('/etc/asbuiltreport', req.params.id, 'AsBuiltReport.json');
  if (fs.existsSync(cfgPath)) {
    res.json({ config: JSON.parse(fs.readFileSync(cfgPath, 'utf8')) });
  } else {
    res.json({ config: {
      Report: { Name: 'AsBuilt Report', Version: '1.0', Status: 'Released', ShowCoverPageImage: true, ShowTableOfContents: true, ShowHeaderFooter: true, ShowSectionNumbers: false },
      UserDefinedVariables: { Company: { FullName: '', ShortName: '', Contact: '', Email: '', Phone: '', Address: '' } },
      OutputFolderPath: REPORTS_DIR, Timestamp: false, Format: ['HTML'],
    }});
  }
});

app.post('/api/modules/:id/config', requireAuth, (req, res) => {
  const cfgDir = path.join('/etc/asbuiltreport', req.params.id);
  if (!fs.existsSync(cfgDir)) fs.mkdirSync(cfgDir, { recursive: true });
  fs.writeFileSync(path.join(cfgDir, 'AsBuiltReport.json'), JSON.stringify(req.body.config, null, 2));
  res.json({ ok: true });
});

app.post('/api/modules/:id/install', requireAuth, (req, res) => {
  const moduleId = req.params.id;
  broadcast('install:start', { moduleId });
  res.json({ ok: true, message: `Installing AsBuiltReport.${moduleId}...` });
  streamFromWorker('/install', { moduleId },
    (line) => broadcast('install:stdout', { moduleId, line }),
    ()     => broadcast('install:done',   { moduleId, exitCode: 0 }),
    (err)  => { broadcast('install:stderr', { moduleId, line: err }); broadcast('install:done', { moduleId, exitCode: 1 }); }
  );
});

app.post('/api/reports/run', requireAuth, (req, res) => {
  const { moduleId, target, credentials, options = {} } = req.body;
  const jobId      = `job_${Date.now()}`;
  const outputPath = path.join(REPORTS_DIR, jobId);
  fs.mkdirSync(outputPath, { recursive: true });
  // Save job metadata so gallery can display module/target without opening the folder
  const metaPath = path.join(outputPath, '.meta.json');
  fs.writeFileSync(metaPath, JSON.stringify({ jobId, moduleId, target, formats: options.formats || ['HTML'], startedAt: new Date().toISOString() }, null, 2));

  // Save job metadata so gallery can display module/target without opening the folder

  broadcast('report:start', { jobId, moduleId, target });
  res.json({ ok: true, jobId });
  streamFromWorker('/run-report',
    { moduleId, target, credentials, formats: options.formats || ['HTML'], outputPath, jobId },
    (line) => {
      broadcast('report:stdout', { jobId, line });
      if (line.includes(`::DONE::${jobId}`)) {
        try {
          const files = fs.readdirSync(outputPath).map((f) => ({ name: f, url: `/reports/${jobId}/${f}`, size: fs.statSync(path.join(outputPath, f)).size }));
          broadcast('report:done', { jobId, files });
        } catch (_) { broadcast('report:done', { jobId, files: [] }); }
      }
    },
    () => {},
    (err) => { broadcast('report:stderr', { jobId, line: err }); broadcast('report:error', { jobId, exitCode: 1 }); }
  );
});

app.use('/reports', express.static(REPORTS_DIR));

app.get('/api/reports', requireAuth, (req, res) => {
  if (!fs.existsSync(REPORTS_DIR)) return res.json({ reports: [] });
  const jobs = fs.readdirSync(REPORTS_DIR, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => {
      const jobPath = path.join(REPORTS_DIR, d.name);
      // Read metadata if available
      let meta = {};
      const metaFile = path.join(jobPath, '.meta.json');
      if (fs.existsSync(metaFile)) {
        try { meta = JSON.parse(fs.readFileSync(metaFile, 'utf8')); } catch (_) {}
      }
      // Infer module/target from report filename if no meta
      const files = fs.readdirSync(jobPath)
        .filter((f) => !f.startsWith('.'))
        .map((f) => { const s = fs.statSync(path.join(jobPath, f)); return { name: f, url: `/reports/${d.name}/${f}`, size: s.size, mtime: s.mtime }; });
      // Try to infer module from first filename e.g. "AsBuiltReport.Veeam.VBR.html"
      if (!meta.moduleId && files.length > 0) {
        const m = files[0].name.match(/AsBuiltReport\.(.+?)\./);
        if (m) meta.moduleId = m[1];
        const hpe = files[0].name.match(/HPEOneView/);
        if (hpe) meta.moduleId = 'HPE.OneView';
      }
      return {
        jobId:     d.name,
        moduleId:  meta.moduleId  || 'Unknown',
        target:    meta.target    || '—',
        formats:   meta.formats   || [],
        startedAt: meta.startedAt || fs.statSync(jobPath).mtime,
        files,
        createdAt: meta.startedAt || fs.statSync(jobPath).mtime,
      };
    })
    .sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
  res.json({ reports: jobs });
});

app.delete('/api/reports/:jobId', requireAuth, (req, res) => {
  const jobPath = path.join(REPORTS_DIR, req.params.jobId);
  if (fs.existsSync(jobPath)) fs.rmSync(jobPath, { recursive: true });
  res.json({ ok: true });
});

// ─── Scheduler API ───────────────────────────────────────────────────────────
app.get('/api/schedules', requireAuth, (req, res) => {
  res.json({ schedules: loadSchedules() });
});

app.post('/api/schedules', requireAuth, (req, res) => {
  const schedules = loadSchedules();
  const schedule = {
    id:          `sched_${Date.now()}`,
    enabled:     true,
    createdAt:   new Date().toISOString(),
    lastRun:     null,
    ...req.body,
  };
  schedule.nextRun = nextRun(schedule)?.toISOString() || null;
  schedules.push(schedule);
  saveSchedules(schedules);
  res.json({ ok: true, schedule });
});

app.put('/api/schedules/:id', requireAuth, (req, res) => {
  const schedules = loadSchedules();
  const idx = schedules.findIndex((s) => s.id === req.params.id);
  if (idx === -1) return res.status(404).json({ error: 'Not found' });
  schedules[idx] = { ...schedules[idx], ...req.body };
  schedules[idx].nextRun = nextRun(schedules[idx])?.toISOString() || null;
  saveSchedules(schedules);
  res.json({ ok: true, schedule: schedules[idx] });
});

app.delete('/api/schedules/:id', requireAuth, (req, res) => {
  const schedules = loadSchedules().filter((s) => s.id !== req.params.id);
  saveSchedules(schedules);
  res.json({ ok: true });
});


const PORT = process.env.PORT || 3001;

server.listen(PORT, () => {
  console.log(`[API] Listening on :${PORT}`);
  // Internal run function for the scheduler (mirrors POST /api/reports/run logic)
  function scheduleRunReport({ moduleId, target, credentials, options }) {
    const jobId      = `job_${Date.now()}`;
    const outputPath = path.join(REPORTS_DIR, jobId);
    fs.mkdirSync(outputPath, { recursive: true });
    broadcast('report:start', { jobId, moduleId, target, scheduled: true });
    const http = require('http');
    const workerBase = new URL(WORKER_URL);
    const payload = JSON.stringify({ moduleId, target, credentials, formats: options.formats || ['HTML'], outputPath, jobId });
    const req = http.request({ hostname: workerBase.hostname, port: workerBase.port || 8080, path: '/run-report', method: 'POST', headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(payload) } }, (res) => {
      let buf = '';
      res.on('data', (chunk) => { buf += chunk.toString(); buf.split('\n').forEach(l => { if (l.trim()) broadcast('report:stdout', { jobId, line: l }); }); buf = ''; });
      res.on('end', () => {
        try { const files = fs.readdirSync(outputPath).map(f => ({ name: f, url: `/reports/${jobId}/${f}`, size: fs.statSync(path.join(outputPath, f)).size })); broadcast('report:done', { jobId, files }); } catch (_) {}
      });
    });
    req.on('error', (err) => broadcast('report:error', { jobId, error: err.message }));
    req.write(payload); req.end();
  }
  startScheduler(scheduleRunReport, broadcast);
});

// ─── Auth routes ──────────────────────────────────────────────────────────────
// Seed default admin on startup
seedDefaultAdmin().catch(console.error);

// POST /api/auth/login  — step 1: username + password
app.post('/api/auth/login', async (req, res) => {
  const { username, password } = req.body;
  console.log(`[Login] Attempt: ${username}`);
  const user = getUser(username);
  if (!user) { console.log(`[Login] User not found: ${username}`); return res.status(401).json({ error: 'Invalid credentials' }); }
  console.log(`[Login] User found, verifying password...`);
  const ok = await verifyPassword(password, user.hash);
  console.log(`[Login] Password valid: ${ok}`);
  if (!ok) return res.status(401).json({ error: 'Invalid credentials' });
  // If 2FA enabled, return partial token requiring TOTP
  if (user.totpEnabled) {
    const partial = signJwt({ sub: user.username, step: 'totp' }, 0.083); // 5 min
    return res.json({ requires2fa: true, partialToken: partial, mustChange: user.mustChange });
  }
  const token = signJwt({ sub: user.username, role: user.role });
  res.json({ token, mustChange: user.mustChange, user: { username: user.username, role: user.role } });
});

// POST /api/auth/totp  — step 2: verify TOTP code
app.post('/api/auth/totp', (req, res) => {
  const { partialToken, code } = req.body;
  const payload = require('./auth').verifyJwt(partialToken);
  if (!payload || payload.step !== 'totp') return res.status(401).json({ error: 'Invalid or expired session' });
  const user = getUser(payload.sub);
  if (!user) return res.status(401).json({ error: 'User not found' });
  if (!verifyTotp(user.totpSecret, code)) return res.status(401).json({ error: 'Invalid 2FA code' });
  const token = signJwt({ sub: user.username, role: user.role });
  res.json({ token, mustChange: user.mustChange, user: { username: user.username, role: user.role } });
});

// GET /api/auth/me
app.get('/api/auth/me', requireAuth, (req, res) => {
  const user = getUser(req.user.sub);
  if (!user) return res.status(404).json({ error: 'User not found' });
  res.json({ username: user.username, role: user.role, totpEnabled: user.totpEnabled, mustChange: user.mustChange });
});

// POST /api/auth/change-password
app.post('/api/auth/change-password', requireAuth, async (req, res) => {
  const { currentPassword, newPassword } = req.body;
  const users = loadUsers();
  const user  = users.find(u => u.username === req.user.sub);
  if (!user) return res.status(404).json({ error: 'User not found' });
  const ok = await verifyPassword(currentPassword, user.hash);
  if (!ok) return res.status(401).json({ error: 'Current password incorrect' });
  const errors = validatePassword(newPassword);
  if (errors.length) return res.status(400).json({ error: 'Password too weak', details: errors });
  user.hash = await hashPassword(newPassword);
  user.mustChange = false;
  saveUsers(users);
  res.json({ ok: true });
});

// POST /api/auth/setup-2fa  — generate secret + QR URI
app.post('/api/auth/setup-2fa', requireAuth, (req, res) => {
  const users  = loadUsers();
  const user   = users.find(u => u.username === req.user.sub);
  if (!user) return res.status(404).json({ error: 'User not found' });
  const secret = generateTotpSecret();
  user.totpPending = secret; // not active until verified
  saveUsers(users);
  res.json({ secret, uri: getTotpUri(secret, user.username) });
});

// POST /api/auth/verify-2fa  — confirm TOTP then enable
app.post('/api/auth/verify-2fa', requireAuth, (req, res) => {
  const { code } = req.body;
  const users = loadUsers();
  const user  = users.find(u => u.username === req.user.sub);
  if (!user || !user.totpPending) return res.status(400).json({ error: 'No pending 2FA setup' });
  if (!verifyTotp(user.totpPending, code)) return res.status(400).json({ error: 'Invalid code — try again' });
  user.totpSecret  = user.totpPending;
  user.totpEnabled = true;
  delete user.totpPending;
  saveUsers(users);
  res.json({ ok: true });
});

// POST /api/auth/disable-2fa
app.post('/api/auth/disable-2fa', requireAuth, async (req, res) => {
  const { password } = req.body;
  const users = loadUsers();
  const user  = users.find(u => u.username === req.user.sub);
  if (!user) return res.status(404).json({ error: 'User not found' });
  const ok = await verifyPassword(password, user.hash);
  if (!ok) return res.status(401).json({ error: 'Password incorrect' });
  user.totpEnabled = false;
  user.totpSecret  = null;
  saveUsers(users);
  res.json({ ok: true });
});

// ── User management (admin only) ───────────────────────────────────────────────
const requireAdmin = [requireAuth, (req, res, next) => {
  // Check token role first, fall back to users file (handles old tokens without role)
  const role = req.user.role || (getUser(req.user.sub) || {}).role;
  if (role !== 'admin') return res.status(403).json({ error: 'Admin required' });
  next();
}];

app.get('/api/users', ...requireAdmin, (req, res) => {
  console.log(`[Users] GET /api/users — requested by ${req.user.sub} (role: ${req.user.role})`);
  const users = loadUsers().map(({ hash, totpSecret, totpPending, ...u }) => u);
  console.log(`[Users] Returning ${users.length} users`);
  res.json({ users });
});

app.post('/api/users', ...requireAdmin, async (req, res) => {
  const { username, password, role = 'user' } = req.body;
  if (!username || !password) return res.status(400).json({ error: 'username and password required' });
  const errors = validatePassword(password);
  if (errors.length) return res.status(400).json({ error: 'Password too weak', details: errors });
  const users = loadUsers();
  if (users.find(u => u.username === username)) return res.status(409).json({ error: 'Username already exists' });
  const newUser = {
    id: require('crypto').randomUUID(), username, role,
    hash: await hashPassword(password),
    totpSecret: null, totpEnabled: false,
    createdAt: new Date().toISOString(), mustChange: true,
  };
  users.push(newUser);
  saveUsers(users);
  const { hash, totpSecret, ...safe } = newUser;
  res.json({ ok: true, user: safe });
});

app.delete('/api/users/:username', ...requireAdmin, (req, res) => {
  if (req.params.username === req.user.sub) return res.status(400).json({ error: 'Cannot delete yourself' });
  const users = loadUsers().filter(u => u.username !== req.params.username);
  saveUsers(users);
  res.json({ ok: true });
});

app.put('/api/users/:username/role', ...requireAdmin, (req, res) => {
  const users = loadUsers();
  const user  = users.find(u => u.username === req.params.username);
  if (!user) return res.status(404).json({ error: 'User not found' });
  user.role = req.body.role;
  saveUsers(users);
  res.json({ ok: true });
});

app.post('/api/users/:username/reset-password', ...requireAdmin, async (req, res) => {
  const { newPassword } = req.body;
  const errors = validatePassword(newPassword);
  if (errors.length) return res.status(400).json({ error: 'Password too weak', details: errors });
  const users = loadUsers();
  const user  = users.find(u => u.username === req.params.username);
  if (!user) return res.status(404).json({ error: 'User not found' });
  user.hash = await hashPassword(newPassword);
  user.mustChange = true;
  saveUsers(users);
  res.json({ ok: true });
});

// ─── Serve React SPA (MUST be absolutely last — after ALL api routes) ────────
const path2 = require('path');
const FRONTEND_DIST = path2.join(__dirname, '../../frontend/dist');
if (require('fs').existsSync(FRONTEND_DIST)) {
  app.use(require('express').static(FRONTEND_DIST, {
    setHeaders: (res, fp) => { if (fp.endsWith('.html')) res.setHeader('Cache-Control', 'no-cache'); }
  }));
  app.get('*', (req, res) => {
    if (!req.path.startsWith('/api') && !req.path.startsWith('/reports'))
      res.sendFile(path2.join(FRONTEND_DIST, 'index.html'));
  });
}
