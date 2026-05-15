import React, { useState, useEffect } from 'react';
import { FileText, Play, Clock, HardDrive, TrendingUp, CheckCircle, AlertCircle, RefreshCw, ExternalLink, Zap } from 'lucide-react';
// Auth fetch helper
function apiFetch(url, opts = {}) {
  const token = localStorage.getItem('abr_token');
  return fetch(url, { ...opts, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}), ...(opts.headers || {}) } });
}

const MODULE_ICONS = {
  'VMware.vSphere': '🖥️', 'VMware.ESXi': '🖥️', 'VMware.Horizon': '💻',
  'Veeam.VBR': '🔒', 'Zerto.ZVM': '♻️', 'HPE.OneView': '🟢',
  'NetApp.ONTAP': '🗄️', 'PureStorage.FlashArray': '⚡', 'Nutanix.PrismElement': '🔧',
  'Fortinet.FortiGate': '🔥', 'DellEMC.VxRail': '🔧', 'Microsoft.Azure': '☁️',
};

function fmt(bytes) {
  if (!bytes) return '0 B';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function fmtDate(d) {
  return new Date(d).toLocaleString('en-GB', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' });
}

function StatCard({ icon: Icon, label, value, sub, color = 'text-abr-accent' }) {
  return (
    <div className="bg-abr-surface border border-abr-border rounded-xl p-5">
      <div className="flex items-center justify-between mb-3">
        <span className="text-xs text-abr-sub uppercase tracking-widest">{label}</span>
        <div className={`w-8 h-8 rounded-lg flex items-center justify-center ${color === 'text-abr-accent' ? 'bg-abr-accent/10' : color === 'text-abr-success' ? 'bg-green-400/10' : color === 'text-abr-warn' ? 'bg-amber-400/10' : 'bg-purple-400/10'}`}>
          <Icon size={15} className={color} />
        </div>
      </div>
      <div className="text-3xl font-bold text-abr-text font-mono">{value}</div>
      {sub && <div className="text-xs text-abr-sub mt-1">{sub}</div>}
    </div>
  );
}

function MiniBarChart({ data, label }) {
  if (!data.length) return null;
  const max = Math.max(...data.map(d => d.count), 1);
  return (
    <div>
      <div className="text-xs text-abr-sub uppercase tracking-widest mb-3">{label}</div>
      <div className="flex items-end gap-1 h-20">
        {data.map((d, i) => (
          <div key={i} className="flex-1 flex flex-col items-center gap-1 group">
            <div className="relative w-full">
              <div className="w-full bg-abr-accent/20 rounded-sm transition-all duration-300 hover:bg-abr-accent/40"
                style={{ height: `${Math.max(4, (d.count / max) * 64)}px` }} />
              <div className="hidden group-hover:block absolute -top-6 left-1/2 -translate-x-1/2 text-xs bg-abr-muted border border-abr-border rounded px-1.5 py-0.5 whitespace-nowrap z-10">
                {d.count} report{d.count !== 1 ? 's' : ''}
              </div>
            </div>
            <span className="text-abr-sub" style={{ fontSize: '9px' }}>{d.label}</span>
          </div>
        ))}
      </div>
    </div>
  );
}

export default function MainDashboard({ onNavigate, user }) {
  const [reports, setReports]   = useState([]);
  const [modules, setModules]   = useState([]);
  const [schedules, setSchedules] = useState([]);
  const [loading, setLoading]   = useState(true);

  const load = () => {
    setLoading(true);
    Promise.all([
      apiFetch('/api/reports').then(r => r.ok ? r.json() : { reports: [] }).catch(() => ({ reports: [] })),
      apiFetch('/api/modules').then(r => r.ok ? r.json() : { modules: [] }).catch(() => ({ modules: [] })),
      apiFetch('/api/schedules').then(r => r.ok ? r.json() : { schedules: [] }).catch(() => ({ schedules: [] })),
    ]).then(([r, m, s]) => {
      setReports(r.reports || []);
      setModules(m.modules || []);
      setSchedules(s.schedules || []);
      setLoading(false);
    });
  };

  useEffect(load, []);

  // Compute stats
  const totalFiles    = reports.reduce((s, r) => s + r.files.length, 0);
  const totalSize     = reports.reduce((s, r) => s + r.files.reduce((ss, f) => ss + (f.size || 0), 0), 0);
  const installedMods = modules.filter(m => m.installed).length;
  const activeScheds  = schedules.filter(s => s.enabled).length;
  const recentReports = [...reports].slice(0, 6);
  const failedJobs    = reports.filter(r => r.files.length === 0).length;

  // Reports by module (pie-like breakdown)
  const byModule = reports.reduce((acc, r) => {
    acc[r.moduleId] = (acc[r.moduleId] || 0) + 1;
    return acc;
  }, {});
  const topModules = Object.entries(byModule).sort((a, b) => b[1] - a[1]).slice(0, 6);

  // Reports by day (last 7 days)
  const byDay = (() => {
    const days = [];
    for (let i = 6; i >= 0; i--) {
      const d = new Date(); d.setDate(d.getDate() - i);
      const key = d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short' });
      const dayStr = d.toISOString().slice(0, 10);
      const count = reports.filter(r => (r.createdAt || '').slice(0, 10) === dayStr).length;
      days.push({ label: key.split(' ')[0], count });
    }
    return days;
  })();

  // Next scheduled run
  const nextSched = schedules
    .filter(s => s.enabled && s.nextRun)
    .sort((a, b) => new Date(a.nextRun) - new Date(b.nextRun))[0];

  if (loading) return (
    <div className="h-full flex items-center justify-center gap-2 text-abr-sub">
      <RefreshCw size={16} className="animate-spin" /> Loading dashboard…
    </div>
  );

  return (
    <div className="h-full overflow-y-auto">
      {/* Header */}
      <div className="px-6 py-5 border-b border-abr-border">
        <div className="flex items-center justify-between">
          <div>
            <h1 className="text-base font-semibold text-abr-text flex items-center gap-2">
              <Zap size={16} className="text-abr-accent" /> Dashboard
            </h1>
            <p className="text-xs text-abr-sub mt-0.5">Welcome back, {user?.username} · {new Date().toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long' })}</p>
          </div>
          <button onClick={load} className="p-1.5 text-abr-sub hover:text-abr-text border border-abr-border rounded-lg transition-all">
            <RefreshCw size={13} />
          </button>
        </div>
      </div>

      <div className="p-6 space-y-6">
        {/* Stat cards */}
        <div className="grid grid-cols-4 gap-4">
          <StatCard icon={FileText}   label="Total Reports"      value={reports.length}   sub={`${totalFiles} files · ${fmt(totalSize)}`} color="text-abr-accent" />
          <StatCard icon={CheckCircle}label="Modules Installed"  value={installedMods}    sub={`of ${modules.length} available`}          color="text-abr-success" />
          <StatCard icon={Clock}      label="Active Schedules"   value={activeScheds}     sub={nextSched ? `Next: ${fmtDate(nextSched.nextRun)}` : 'No schedules'} color="text-abr-warn" />
          <StatCard icon={HardDrive}  label="Storage Used"       value={fmt(totalSize)}   sub={failedJobs ? `${failedJobs} failed job${failedJobs>1?'s':''}` : 'All jobs successful'} color="text-purple-400" />
        </div>

        {/* Charts row */}
        <div className="grid grid-cols-3 gap-4">
          {/* Activity chart */}
          <div className="col-span-2 bg-abr-surface border border-abr-border rounded-xl p-5">
            <MiniBarChart data={byDay} label="Reports generated — last 7 days" />
          </div>

          {/* By module breakdown */}
          <div className="bg-abr-surface border border-abr-border rounded-xl p-5">
            <div className="text-xs text-abr-sub uppercase tracking-widest mb-3">By Module</div>
            {topModules.length === 0 ? (
              <p className="text-xs text-abr-sub">No reports yet</p>
            ) : (
              <div className="space-y-2">
                {topModules.map(([mod, count]) => {
                  const pct = Math.round((count / reports.length) * 100);
                  return (
                    <div key={mod}>
                      <div className="flex items-center justify-between mb-0.5">
                        <span className="text-xs text-abr-text flex items-center gap-1.5">
                          <span>{MODULE_ICONS[mod] || '📄'}</span>{mod}
                        </span>
                        <span className="text-xs text-abr-sub font-mono">{count}</span>
                      </div>
                      <div className="h-1.5 bg-abr-muted rounded-full overflow-hidden">
                        <div className="h-full bg-abr-accent rounded-full" style={{ width: `${pct}%` }} />
                      </div>
                    </div>
                  );
                })}
              </div>
            )}
          </div>
        </div>

        {/* Bottom row: Recent reports + Scheduled jobs */}
        <div className="grid grid-cols-2 gap-4">
          {/* Recent reports */}
          <div className="bg-abr-surface border border-abr-border rounded-xl overflow-hidden">
            <div className="px-4 py-3 border-b border-abr-border flex items-center justify-between">
              <span className="text-xs font-medium text-abr-sub uppercase tracking-widest">Recent Reports</span>
              <button onClick={() => onNavigate('gallery')} className="text-xs text-abr-accent hover:text-blue-300 transition-colors">View all →</button>
            </div>
            <div className="divide-y divide-abr-border">
              {recentReports.length === 0 && (
                <div className="px-4 py-6 text-xs text-abr-sub text-center">No reports yet — run one from Modules</div>
              )}
              {recentReports.map(r => {
                const htmlFile = r.files.find(f => f.name.endsWith('.html'));
                return (
                  <div key={r.jobId} className="px-4 py-2.5 flex items-center gap-3 hover:bg-abr-muted/30 transition-colors">
                    <span className="text-base">{MODULE_ICONS[r.moduleId] || '📄'}</span>
                    <div className="flex-1 min-w-0">
                      <div className="text-xs font-medium text-abr-text truncate">{r.moduleId}</div>
                      <div className="text-xs text-abr-sub flex items-center gap-1.5">
                        <span className="font-mono">{r.target}</span>
                        <span>·</span>
                        <span>{fmtDate(r.createdAt)}</span>
                      </div>
                    </div>
                    {r.files.length === 0 ? (
                      <span className="text-xs text-abr-danger flex items-center gap-1"><AlertCircle size={10} />Failed</span>
                    ) : htmlFile ? (
                      <a href={htmlFile.url} target="_blank" rel="noreferrer"
                        className="text-xs text-abr-accent hover:text-blue-300 flex items-center gap-1 transition-colors">
                        Open <ExternalLink size={10} />
                      </a>
                    ) : null}
                  </div>
                );
              })}
            </div>
          </div>

          {/* Scheduled jobs */}
          <div className="bg-abr-surface border border-abr-border rounded-xl overflow-hidden">
            <div className="px-4 py-3 border-b border-abr-border flex items-center justify-between">
              <span className="text-xs font-medium text-abr-sub uppercase tracking-widest">Scheduled Jobs</span>
              <button onClick={() => onNavigate('scheduler')} className="text-xs text-abr-accent hover:text-blue-300 transition-colors">Manage →</button>
            </div>
            <div className="divide-y divide-abr-border">
              {schedules.length === 0 && (
                <div className="px-4 py-6 text-xs text-abr-sub text-center">No schedules — create one in the Scheduler</div>
              )}
              {schedules.slice(0, 5).map(s => (
                <div key={s.id} className="px-4 py-2.5 flex items-center gap-3 hover:bg-abr-muted/30 transition-colors">
                  <span className="text-base">{MODULE_ICONS[s.moduleId] || '📄'}</span>
                  <div className="flex-1 min-w-0">
                    <div className="text-xs font-medium text-abr-text truncate">{s.label || s.moduleId}</div>
                    <div className="text-xs text-abr-sub flex items-center gap-1.5">
                      <span className="capitalize">{s.frequency}</span>
                      <span>·</span>
                      <span>{s.nextRun ? fmtDate(s.nextRun) : '—'}</span>
                    </div>
                  </div>
                  <div className={`w-2 h-2 rounded-full ${s.enabled ? 'bg-abr-success' : 'bg-abr-sub'}`} />
                </div>
              ))}
            </div>
          </div>
        </div>

        {/* Quick actions */}
        <div className="bg-abr-surface border border-abr-border rounded-xl p-5">
          <div className="text-xs font-medium text-abr-sub uppercase tracking-widest mb-3">Quick Actions</div>
          <div className="flex gap-3 flex-wrap">
            {[
              { label: 'Run Report',     icon: Play,      page: 'modules',    color: 'bg-abr-accent/10 text-abr-accent border-abr-accent/20 hover:bg-abr-accent/20' },
              { label: 'View Reports',   icon: FileText,  page: 'gallery',    color: 'bg-green-400/10 text-green-400 border-green-400/20 hover:bg-green-400/20' },
              { label: 'Add Schedule',   icon: Clock,     page: 'scheduler',  color: 'bg-amber-400/10 text-amber-400 border-amber-400/20 hover:bg-amber-400/20' },
              { label: 'Manage Users',   icon: TrendingUp,page: 'users',      color: 'bg-purple-400/10 text-purple-400 border-purple-400/20 hover:bg-purple-400/20' },
            ].map(({ label, icon: Icon, page, color }) => (
              <button key={page} onClick={() => onNavigate(page)}
                className={`flex items-center gap-2 px-4 py-2 rounded-lg text-xs font-medium border transition-all ${color}`}>
                <Icon size={13} />{label}
              </button>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
