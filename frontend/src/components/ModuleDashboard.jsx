import React, { useState, useEffect } from 'react';
// Auth fetch helper
function apiFetch(url, opts = {}) {
  const token = localStorage.getItem('abr_token');
  return fetch(url, { ...opts, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}), ...(opts.headers || {}) } });
}
import { Download, RefreshCw, CheckCircle, ArrowUpCircle, Search, Package } from 'lucide-react';

const CATEGORY_COLORS = {
  VMware:      'text-blue-400 bg-blue-400/10 border-blue-400/20',
  Backup:      'text-green-400 bg-green-400/10 border-green-400/20',
  Microsoft:   'text-cyan-400 bg-cyan-400/10 border-cyan-400/20',
  Storage:     'text-orange-400 bg-orange-400/10 border-orange-400/20',
  HCI:         'text-yellow-400 bg-yellow-400/10 border-yellow-400/20',
  Networking:  'text-purple-400 bg-purple-400/10 border-purple-400/20',
  Security:    'text-red-400 bg-red-400/10 border-red-400/20',
  DR:          'text-pink-400 bg-pink-400/10 border-pink-400/20',
  System:      'text-slate-400 bg-slate-400/10 border-slate-400/20',
  Cloud:       'text-sky-400 bg-sky-400/10 border-sky-400/20',
};

export default function ModuleDashboard({ onSelect }) {
  const [modules, setModules] = useState([]);
  const [loading, setLoading] = useState(true);
  const [installing, setInstalling] = useState({});
  const [search, setSearch] = useState('');
  const [filter, setFilter] = useState('all');

  const load = () => {
    setLoading(true);
    apiFetch('/api/modules')
      .then((r) => r.json())
      .then((d) => { setModules(d.modules || []); setLoading(false); })
      .catch(() => setLoading(false));
  };

  useEffect(load, []);

  const install = (mod) => {
    setInstalling((p) => ({ ...p, [mod.id]: true }));
    apiFetch(`/api/modules/${mod.id}/install`, { method: 'POST' })
      .then(() => setTimeout(() => { load(); setInstalling((p) => ({ ...p, [mod.id]: false })); }, 3000));
  };

  const filtered = modules
    .filter((m) => filter === 'all' || (filter === 'installed' ? m.installed : !m.installed))
    .filter((m) => m.name.toLowerCase().includes(search.toLowerCase()) || m.category.toLowerCase().includes(search.toLowerCase()));

  const installedCount = modules.filter((m) => m.installed).length;
  const updateCount = modules.filter((m) => m.updateAvailable).length;

  return (
    <div className="h-full flex flex-col">
      {/* Top Bar */}
      <div className="px-6 py-4 border-b border-abr-border flex items-center gap-4">
        <div>
          <h1 className="text-base font-semibold text-abr-text">Module Registry</h1>
          <p className="text-xs text-abr-sub mt-0.5">{installedCount}/{modules.length} installed{updateCount > 0 ? ` · ${updateCount} updates available` : ''}</p>
        </div>
        <div className="ml-auto flex items-center gap-3">
          <div className="relative">
            <Search size={14} className="absolute left-3 top-1/2 -translate-y-1/2 text-abr-sub" />
            <input
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Search modules…"
              className="bg-abr-surface border border-abr-border rounded-lg pl-8 pr-4 py-1.5 text-xs text-abr-text placeholder-abr-sub focus:outline-none focus:border-abr-accent w-52"
            />
          </div>
          <div className="flex border border-abr-border rounded-lg overflow-hidden text-xs">
            {['all', 'installed', 'available'].map((f) => (
              <button key={f} onClick={() => setFilter(f)}
                className={`px-3 py-1.5 capitalize transition-colors ${filter === f ? 'bg-abr-accent/15 text-abr-accent' : 'text-abr-sub hover:text-abr-text bg-abr-surface'}`}>
                {f}
              </button>
            ))}
          </div>
          <button onClick={load} className="p-1.5 rounded-lg border border-abr-border text-abr-sub hover:text-abr-text hover:border-abr-muted transition-all">
            <RefreshCw size={14} className={loading ? 'animate-spin' : ''} />
          </button>
        </div>
      </div>

      {/* Stats Bar */}
      <div className="px-6 py-3 flex gap-4 border-b border-abr-border">
        {[
          { label: 'Total', val: modules.length },
          { label: 'Installed', val: installedCount, cls: 'text-abr-success' },
          { label: 'Available', val: modules.length - installedCount, cls: 'text-abr-sub' },
          { label: 'Updates', val: updateCount, cls: updateCount > 0 ? 'text-abr-warn' : 'text-abr-sub' },
        ].map(({ label, val, cls = 'text-abr-text' }) => (
          <div key={label} className="flex items-center gap-2">
            <span className="text-xs text-abr-sub">{label}</span>
            <span className={`text-sm font-semibold font-mono ${cls}`}>{val}</span>
          </div>
        ))}
      </div>

      {/* Module Grid */}
      <div className="flex-1 overflow-y-auto p-6">
        {loading ? (
          <div className="flex items-center justify-center h-48 text-abr-sub text-sm gap-2">
            <RefreshCw size={16} className="animate-spin" /> Loading modules…
          </div>
        ) : (
          <div className="grid grid-cols-2 xl:grid-cols-3 gap-4">
            {filtered.map((mod) => (
              <ModuleCard
                key={mod.id}
                mod={mod}
                installing={installing[mod.id]}
                onSelect={onSelect}
                onInstall={install}
              />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function ModuleCard({ mod, installing, onSelect, onInstall }) {
  const catCls = CATEGORY_COLORS[mod.category] || 'text-abr-sub bg-abr-muted border-abr-border';

  return (
    <div className={`
      group relative bg-abr-surface border border-abr-border rounded-xl p-4
      hover:border-abr-accent/40 transition-all duration-200 cursor-pointer
      ${mod.installed ? 'hover:bg-abr-accent/5' : ''}
      animate-fade-in
    `}>
      {/* Status indicator */}
      <div className="absolute top-3 right-3 flex items-center gap-1.5">
        {mod.installed && !mod.updateAvailable && <CheckCircle size={14} className="text-abr-success" />}
        {mod.updateAvailable && <ArrowUpCircle size={14} className="text-abr-warn" />}
        {!mod.installed && <Package size={14} className="text-abr-sub" />}
      </div>

      {/* Icon + Name */}
      <div className="text-2xl mb-3">{mod.icon}</div>
      <h3 className="text-sm font-medium text-abr-text pr-6 leading-tight">{mod.name}</h3>
      <p className="text-xs text-abr-sub mt-1 line-clamp-2 leading-relaxed">{mod.description}</p>

      {/* Footer */}
      <div className="mt-4 flex items-center gap-2">
        <span className={`text-xs px-2 py-0.5 rounded-full border ${catCls}`}>{mod.category}</span>
        {mod.version && <span className="text-xs text-abr-sub font-mono">v{mod.version}</span>}
      </div>

      {/* Actions */}
      <div className="mt-3 flex gap-2">
        {mod.installed ? (
          <button
            onClick={() => onSelect(mod)}
            className="flex-1 py-1.5 rounded-lg text-xs bg-abr-accent/10 text-abr-accent border border-abr-accent/20 hover:bg-abr-accent/20 transition-all"
          >
            Configure & Run →
          </button>
        ) : (
          <button
            onClick={(e) => { e.stopPropagation(); onInstall(mod); }}
            disabled={installing}
            className="flex-1 py-1.5 rounded-lg text-xs bg-abr-muted text-abr-text border border-abr-border hover:border-abr-accent/40 hover:text-abr-accent transition-all flex items-center justify-center gap-1.5"
          >
            {installing ? <><RefreshCw size={12} className="animate-spin" /> Installing…</> : <><Download size={12} /> Install</>}
          </button>
        )}
      </div>
    </div>
  );
}
