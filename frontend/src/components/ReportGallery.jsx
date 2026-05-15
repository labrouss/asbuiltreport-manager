import React, { useState, useEffect } from 'react';
// Auth fetch helper
function apiFetch(url, opts = {}) {
  const token = localStorage.getItem('abr_token');
  return fetch(url, { ...opts, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}), ...(opts.headers || {}) } });
}
import { FolderOpen, FileText, File, Trash2, ExternalLink, RefreshCw, Calendar, HardDrive, ChevronDown, ChevronRight, Layers } from 'lucide-react';

const MODULE_META = {
  'VMware.vSphere':         { icon: '🖥️', color: 'text-blue-400',   bg: 'bg-blue-400/10',   border: 'border-blue-400/20' },
  'VMware.ESXi':            { icon: '🖥️', color: 'text-blue-400',   bg: 'bg-blue-400/10',   border: 'border-blue-400/20' },
  'VMware.Horizon':         { icon: '💻', color: 'text-indigo-400', bg: 'bg-indigo-400/10', border: 'border-indigo-400/20' },
  'Veeam.VBR':             { icon: '🔒', color: 'text-green-400',  bg: 'bg-green-400/10',  border: 'border-green-400/20' },
  'Zerto.ZVM':             { icon: '♻️', color: 'text-pink-400',   bg: 'bg-pink-400/10',   border: 'border-pink-400/20' },
  'HPE.OneView':           { icon: '🟢', color: 'text-emerald-400',bg: 'bg-emerald-400/10',border: 'border-emerald-400/20' },
  'NetApp.ONTAP':           { icon: '🗄️', color: 'text-orange-400', bg: 'bg-orange-400/10', border: 'border-orange-400/20' },
  'PureStorage.FlashArray': { icon: '⚡', color: 'text-yellow-400', bg: 'bg-yellow-400/10', border: 'border-yellow-400/20' },
  'Nutanix.PrismElement':   { icon: '🔧', color: 'text-yellow-400', bg: 'bg-yellow-400/10', border: 'border-yellow-400/20' },
  'Fortinet.FortiGate':     { icon: '🔥', color: 'text-red-400',    bg: 'bg-red-400/10',    border: 'border-red-400/20' },
  'DellEMC.VxRail':        { icon: '🔧', color: 'text-cyan-400',   bg: 'bg-cyan-400/10',   border: 'border-cyan-400/20' },
  'Microsoft.Azure':        { icon: '☁️', color: 'text-sky-400',    bg: 'bg-sky-400/10',    border: 'border-sky-400/20' },
};

function getModuleMeta(moduleId) {
  return MODULE_META[moduleId] || { icon: '📄', color: 'text-abr-sub', bg: 'bg-abr-muted', border: 'border-abr-border' };
}

function fmt(bytes) {
  if (!bytes) return '0 B';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}

function fmtDate(d) {
  return new Date(d).toLocaleString('en-GB', { day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}

function FileIcon({ name }) {
  const ext = name.split('.').pop().toLowerCase();
  if (ext === 'html') return <FileText size={14} className="text-abr-accent shrink-0" />;
  if (ext === 'pdf')  return <FileText size={14} className="text-red-400 shrink-0" />;
  if (ext === 'docx') return <FileText size={14} className="text-blue-400 shrink-0" />;
  return <File size={14} className="text-abr-sub shrink-0" />;
}

function ReportCard({ job, onDelete }) {
  const [open, setOpen] = useState(false);
  const meta = getModuleMeta(job.moduleId);

  return (
    <div className={`border rounded-xl overflow-hidden transition-all duration-200 ${open ? 'border-abr-accent/30' : 'border-abr-border'} bg-abr-surface`}>
      {/* Card Header */}
      <div onClick={() => setOpen(!open)}
        className="px-4 py-3 flex items-center gap-3 cursor-pointer hover:bg-abr-muted/50 transition-colors">

        {/* Module icon badge */}
        <div className={`w-9 h-9 rounded-lg flex items-center justify-center text-lg shrink-0 ${meta.bg} border ${meta.border}`}>
          {meta.icon}
        </div>

        {/* Module + target */}
        <div className="flex-1 min-w-0">
          <div className="flex items-center gap-2 flex-wrap">
            <span className="text-sm font-medium text-abr-text">{job.moduleId}</span>
            <span className={`text-xs px-2 py-0.5 rounded-full border font-mono ${meta.bg} ${meta.color} ${meta.border}`}>
              {job.target}
            </span>
          </div>
          <div className="flex items-center gap-3 mt-1 text-xs text-abr-sub">
            <span className="flex items-center gap-1"><Calendar size={10} />{fmtDate(job.createdAt)}</span>
            <span className="flex items-center gap-1"><HardDrive size={10} />{job.files.length} file{job.files.length !== 1 ? 's' : ''}</span>
            <span>{fmt(job.files.reduce((s, f) => s + (f.size || 0), 0))}</span>
          </div>
        </div>

        {/* Actions */}
        <div className="flex items-center gap-1.5 shrink-0">
          {/* Quick-open first HTML file */}
          {job.files.find(f => f.name.endsWith('.html')) && (
            <a href={job.files.find(f => f.name.endsWith('.html')).url}
              target="_blank" rel="noreferrer"
              onClick={e => e.stopPropagation()}
              className="flex items-center gap-1 px-2.5 py-1.5 text-xs rounded-lg bg-abr-accent/10 text-abr-accent border border-abr-accent/20 hover:bg-abr-accent/20 transition-all">
              Open <ExternalLink size={10} />
            </a>
          )}
          <button onClick={(e) => { e.stopPropagation(); onDelete(job.jobId); }}
            className="p-1.5 text-abr-sub hover:text-abr-danger border border-abr-border hover:border-abr-danger/40 rounded-lg transition-all">
            <Trash2 size={12} />
          </button>
          <div className="text-abr-sub">
            {open ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
          </div>
        </div>
      </div>

      {/* Expanded file list */}
      {open && job.files.length > 0 && (
        <div className="border-t border-abr-border divide-y divide-abr-border/50">
          {job.files.map((file) => (
            <div key={file.name} className="px-4 py-2 flex items-center gap-3 bg-abr-bg hover:bg-abr-surface/50 transition-colors">
              <span className="w-9 shrink-0" />
              <FileIcon name={file.name} />
              <span className="flex-1 text-xs text-abr-text font-mono truncate">{file.name}</span>
              <span className="text-xs text-abr-sub shrink-0">{fmt(file.size)}</span>
              <a href={file.url} target="_blank" rel="noreferrer"
                className="flex items-center gap-1 text-xs text-abr-accent hover:text-blue-300 transition-colors shrink-0 ml-1 group">
                Open <ExternalLink size={10} className="group-hover:translate-x-0.5 transition-transform" />
              </a>
            </div>
          ))}
        </div>
      )}
      {open && job.files.length === 0 && (
        <div className="border-t border-abr-border px-4 py-3 text-xs text-abr-sub bg-abr-bg">
          No report files — job may have failed.
        </div>
      )}
    </div>
  );
}

export default function ReportGallery() {
  const [reports, setReports]   = useState([]);
  const [loading, setLoading]   = useState(true);
  const [groupBy, setGroupBy]   = useState('module'); // 'module' | 'date' | 'none'
  const [filter, setFilter]     = useState('all');

  const load = () => {
    setLoading(true);
    apiFetch('/api/reports')
      .then(r => r.json())
      .then(d => { setReports(d.reports || []); setLoading(false); })
      .catch(() => setLoading(false));
  };

  useEffect(load, []);

  const del = (jobId) => {
    if (!confirm('Delete this report?')) return;
    apiFetch(`/api/reports/${jobId}`, { method: 'DELETE' }).then(load);
  };

  const clearEmpty = () => {
    const empty = reports.filter(r => r.files.length === 0);
    if (!empty.length) return alert('No empty report folders found.');
    if (!confirm(`Delete ${empty.length} empty report folder(s)?`)) return;
    Promise.all(empty.map(r => apiFetch(`/api/reports/${r.jobId}`, { method: 'DELETE' }))).then(load);
  };

  const clearAll = () => {
    if (!reports.length) return;
    if (!confirm(`Delete ALL ${reports.length} report jobs? This cannot be undone.`)) return;
    Promise.all(reports.map(r => apiFetch(`/api/reports/${r.jobId}`, { method: 'DELETE' }))).then(load);
  };

  const filtered = reports.filter(r => filter === 'all' || r.moduleId === filter);
  const totalSize = reports.reduce((s, r) => s + r.files.reduce((ss, f) => ss + (f.size || 0), 0), 0);
  const modules = [...new Set(reports.map(r => r.moduleId))].sort();

  // Group reports
  const grouped = (() => {
    if (groupBy === 'none') return { 'All Reports': filtered };
    if (groupBy === 'module') {
      return filtered.reduce((acc, r) => {
        const key = r.moduleId;
        if (!acc[key]) acc[key] = [];
        acc[key].push(r);
        return acc;
      }, {});
    }
    if (groupBy === 'date') {
      return filtered.reduce((acc, r) => {
        const key = new Date(r.createdAt).toLocaleDateString('en-GB', { day: '2-digit', month: 'long', year: 'numeric' });
        if (!acc[key]) acc[key] = [];
        acc[key].push(r);
        return acc;
      }, {});
    }
  })();

  return (
    <div className="h-full flex flex-col">
      {/* Header */}
      <div className="px-6 py-4 border-b border-abr-border flex items-center gap-3 flex-wrap">
        <FolderOpen size={16} className="text-abr-accent shrink-0" />
        <div>
          <h1 className="text-sm font-semibold text-abr-text">Report Gallery</h1>
          <p className="text-xs text-abr-sub">{reports.length} jobs · {reports.reduce((s,r)=>s+r.files.length,0)} files · {fmt(totalSize)}</p>
        </div>
        <div className="ml-auto flex items-center gap-2 flex-wrap">
          {/* Filter by module */}
          <select value={filter} onChange={e => setFilter(e.target.value)}
            className="bg-abr-surface border border-abr-border rounded-lg px-2.5 py-1.5 text-xs text-abr-text focus:outline-none focus:border-abr-accent">
            <option value="all">All modules</option>
            {modules.map(m => <option key={m} value={m}>{m}</option>)}
          </select>
          {/* Group by */}
          <div className="flex border border-abr-border rounded-lg overflow-hidden text-xs">
            {[['module','By Module'],['date','By Date'],['none','All']].map(([v,l]) => (
              <button key={v} onClick={() => setGroupBy(v)}
                className={`px-3 py-1.5 transition-colors ${groupBy===v ? 'bg-abr-accent/15 text-abr-accent' : 'bg-abr-surface text-abr-sub hover:text-abr-text'}`}>
                {l}
              </button>
            ))}
          </div>
          <button onClick={clearEmpty} className="flex items-center gap-1.5 px-3 py-1.5 text-xs rounded-lg border border-abr-border text-abr-sub hover:text-abr-warn hover:border-abr-warn/40 transition-all">
            <Trash2 size={11} /> Clear Empty
          </button>
          <button onClick={clearAll} className="flex items-center gap-1.5 px-3 py-1.5 text-xs rounded-lg border border-abr-border text-abr-sub hover:text-abr-danger hover:border-abr-danger/40 transition-all">
            <Trash2 size={11} /> Clear All
          </button>
          <button onClick={load} className="p-1.5 text-abr-sub hover:text-abr-text border border-abr-border rounded-lg transition-all">
            <RefreshCw size={13} className={loading ? 'animate-spin' : ''} />
          </button>
        </div>
      </div>

      {/* Content */}
      <div className="flex-1 overflow-y-auto p-6 space-y-6">
        {loading && (
          <div className="flex items-center justify-center h-40 gap-2 text-abr-sub text-sm">
            <RefreshCw size={14} className="animate-spin" /> Loading reports…
          </div>
        )}
        {!loading && reports.length === 0 && (
          <div className="flex flex-col items-center justify-center h-40 gap-3 text-abr-sub">
            <FolderOpen size={36} className="opacity-20" />
            <p className="text-sm">No reports yet</p>
            <p className="text-xs opacity-60">Run a report from the Config page to see it here</p>
          </div>
        )}
        {!loading && Object.entries(grouped).map(([group, jobs]) => (
          <div key={group}>
            {groupBy !== 'none' && (
              <div className="flex items-center gap-2 mb-3">
                {groupBy === 'module' && (
                  <span className={`text-lg`}>{getModuleMeta(group).icon}</span>
                )}
                {groupBy === 'date' && <Calendar size={13} className="text-abr-sub" />}
                <span className="text-xs font-semibold text-abr-text uppercase tracking-widest">{group}</span>
                <span className="text-xs text-abr-sub">({jobs.length})</span>
                <div className="flex-1 h-px bg-abr-border ml-1" />
              </div>
            )}
            <div className="space-y-2">
              {jobs.map(job => <ReportCard key={job.jobId} job={job} onDelete={del} />)}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}
