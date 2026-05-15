import React, { useState, useEffect } from 'react';
import { Clock, Plus, Trash2, ToggleLeft, ToggleRight, RefreshCw, Calendar, Play, ChevronDown, Edit2 } from 'lucide-react';

function apiFetch(url, opts = {}) {
  const token = localStorage.getItem('abr_token');
  return fetch(url, {
    ...opts,
    headers: { 'Content-Type': 'application/json', ...(token ? { 'Authorization': 'Bearer ' + token } : {}), ...(opts.headers || {}) },
  });
}

const MODULES = [
  'VMware.vSphere','VMware.ESXi','VMware.Horizon','DellEMC.VxRail',
  'Veeam.VBR','NetApp.ONTAP','PureStorage.FlashArray','Nutanix.PrismElement',
  'Fortinet.FortiGate','Aruba.ClearPass','Zerto.ZVM','HPE.OneView',
  'Microsoft.Azure','Microsoft.Intune','Microsoft.EntraID','System.Resources',
];
const DAYS    = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
const FORMATS = ['HTML','Word','XML','Text'];

function fmtDate(iso) {
  if (!iso) return '—';
  return new Date(iso).toLocaleString('en-GB', { day:'2-digit', month:'short', year:'numeric', hour:'2-digit', minute:'2-digit' });
}

function FreqBadge({ frequency }) {
  const cls = { hourly:'text-purple-400 bg-purple-400/10 border-purple-400/20', daily:'text-blue-400 bg-blue-400/10 border-blue-400/20', weekly:'text-green-400 bg-green-400/10 border-green-400/20', monthly:'text-orange-400 bg-orange-400/10 border-orange-400/20' }[frequency] || 'text-abr-sub bg-abr-muted border-abr-border';
  return <span className={`text-xs px-2 py-0.5 rounded-full border capitalize ${cls}`}>{frequency}</span>;
}

// ── Schedule Form (used for both New and Edit) ────────────────────────────────
function ScheduleForm({ initial, onSave, onClose, title }) {
  const def = { moduleId:'Veeam.VBR', target:'', username:'', password:'', frequency:'daily', time:'06:00', dayOfWeek:1, dayOfMonth:1, minute:0, formats:['HTML'], label:'', ...initial };
  const [form, setForm] = useState(def);
  const set = (k, v) => setForm(p => ({ ...p, [k]: v }));
  const toggleFmt = (f) => set('formats', form.formats.includes(f) ? form.formats.filter(x => x !== f) : [...form.formats, f]);
  const inp = "w-full bg-abr-bg border border-abr-border rounded-lg px-3 py-2 text-xs text-abr-text font-mono placeholder-abr-sub focus:outline-none focus:border-abr-accent transition-colors";

  const save = () => {
    if (!form.target) return;
    // Only include password if it was changed (not placeholder)
    const payload = {
      moduleId:    form.moduleId,
      target:      form.target.trim(),
      label:       form.label || `${form.moduleId} — ${form.target}`,
      credentials: { username: form.username, ...(form.password && form.password !== '••••••••' ? { password: form.password } : {}) },
      options:     { formats: form.formats },
      frequency:   form.frequency,
      time:        form.time,
      dayOfWeek:   form.dayOfWeek,
      dayOfMonth:  form.dayOfMonth,
      minute:      form.minute,
    };
    onSave(payload);
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm">
      <div className="bg-abr-surface border border-abr-border rounded-xl w-full max-w-lg shadow-2xl animate-slide-up">
        <div className="px-5 py-4 border-b border-abr-border flex items-center gap-2">
          <Clock size={15} className="text-abr-accent" />
          <h2 className="text-sm font-semibold text-abr-text">{title}</h2>
          <button onClick={onClose} className="ml-auto text-abr-sub hover:text-abr-text text-xl leading-none">×</button>
        </div>
        <div className="p-5 space-y-4 overflow-y-auto max-h-[70vh]">
          {/* Label */}
          <div>
            <label className="block text-xs text-abr-sub mb-1.5">Label (optional)</label>
            <input className={inp} value={form.label} onChange={e => set('label', e.target.value)} placeholder="e.g. Weekly Veeam Report" />
          </div>
          {/* Module + Target */}
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-xs text-abr-sub mb-1.5">Module</label>
              <div className="relative">
                <select className={inp + ' appearance-none pr-7 cursor-pointer'} value={form.moduleId} onChange={e => set('moduleId', e.target.value)}>
                  {MODULES.map(m => <option key={m} value={m}>{m}</option>)}
                </select>
                <ChevronDown size={12} className="absolute right-2.5 top-1/2 -translate-y-1/2 text-abr-sub pointer-events-none" />
              </div>
            </div>
            <div>
              <label className="block text-xs text-abr-sub mb-1.5">Target Host / IP</label>
              <input className={inp} value={form.target} onChange={e => set('target', e.target.value)} placeholder="192.168.1.10" />
            </div>
          </div>
          {/* Credentials */}
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-xs text-abr-sub mb-1.5">Username</label>
              <input className={inp} value={form.username} onChange={e => set('username', e.target.value)} placeholder="admin" />
            </div>
            <div>
              <label className="block text-xs text-abr-sub mb-1.5">Password {initial?.id && <span className="text-abr-sub/60">(leave blank to keep)</span>}</label>
              <input className={inp} type="password" value={form.password} onChange={e => set('password', e.target.value)} placeholder={initial?.id ? '••••••••' : 'Password'} />
            </div>
          </div>
          {/* Frequency */}
          <div>
            <label className="block text-xs text-abr-sub mb-1.5">Frequency</label>
            <div className="flex gap-2 flex-wrap">
              {['hourly','daily','weekly','monthly'].map(f => (
                <button key={f} onClick={() => set('frequency', f)}
                  className={`px-3 py-1.5 rounded-lg text-xs border capitalize transition-all ${form.frequency === f ? 'bg-abr-accent/15 text-abr-accent border-abr-accent/30' : 'bg-abr-bg text-abr-sub border-abr-border hover:border-abr-muted'}`}>
                  {f}
                </button>
              ))}
            </div>
          </div>
          {/* Time options */}
          <div className="grid grid-cols-3 gap-3">
            {form.frequency !== 'hourly' && (
              <div className={form.frequency === 'daily' ? 'col-span-3' : ''}>
                <label className="block text-xs text-abr-sub mb-1.5">Time</label>
                <input className={inp} type="time" value={form.time} onChange={e => set('time', e.target.value)} />
              </div>
            )}
            {form.frequency === 'hourly' && (
              <div>
                <label className="block text-xs text-abr-sub mb-1.5">Minute</label>
                <input className={inp} type="number" min="0" max="59" value={form.minute} onChange={e => set('minute', +e.target.value)} />
              </div>
            )}
            {form.frequency === 'weekly' && (
              <div className="col-span-2">
                <label className="block text-xs text-abr-sub mb-1.5">Day of week</label>
                <div className="relative">
                  <select className={inp + ' appearance-none pr-7 cursor-pointer'} value={form.dayOfWeek} onChange={e => set('dayOfWeek', +e.target.value)}>
                    {DAYS.map((d, i) => <option key={i} value={i}>{d}</option>)}
                  </select>
                  <ChevronDown size={12} className="absolute right-2.5 top-1/2 -translate-y-1/2 text-abr-sub pointer-events-none" />
                </div>
              </div>
            )}
            {form.frequency === 'monthly' && (
              <div className="col-span-2">
                <label className="block text-xs text-abr-sub mb-1.5">Day of month</label>
                <input className={inp} type="number" min="1" max="28" value={form.dayOfMonth} onChange={e => set('dayOfMonth', +e.target.value)} />
              </div>
            )}
          </div>
          {/* Formats */}
          <div>
            <label className="block text-xs text-abr-sub mb-1.5">Output formats</label>
            <div className="flex gap-2">
              {FORMATS.map(f => (
                <button key={f} onClick={() => toggleFmt(f)}
                  className={`px-3 py-1.5 rounded-lg text-xs border transition-all ${form.formats.includes(f) ? 'bg-abr-accent/15 text-abr-accent border-abr-accent/30' : 'bg-abr-bg text-abr-sub border-abr-border hover:border-abr-muted'}`}>
                  {f}
                </button>
              ))}
            </div>
          </div>
        </div>
        <div className="px-5 py-4 border-t border-abr-border flex gap-2 justify-end">
          <button onClick={onClose} className="px-4 py-2 text-xs rounded-lg border border-abr-border text-abr-sub hover:text-abr-text transition-all">Cancel</button>
          <button onClick={save} disabled={!form.target || !form.username}
            className="px-4 py-2 text-xs rounded-lg bg-abr-accent text-white hover:bg-blue-400 disabled:opacity-40 transition-all flex items-center gap-1.5">
            <Clock size={12} /> {initial?.id ? 'Save Changes' : 'Create Schedule'}
          </button>
        </div>
      </div>
    </div>
  );
}

// ── Main Scheduler ────────────────────────────────────────────────────────────
export default function Scheduler() {
  const [schedules, setSchedules] = useState([]);
  const [loading, setLoading]     = useState(true);
  const [showNew, setShowNew]     = useState(false);
  const [editing, setEditing]     = useState(null); // schedule being edited

  const load = () => {
    setLoading(true);
    apiFetch('/api/schedules')
      .then(r => r.json())
      .then(d => { setSchedules(d.schedules || []); setLoading(false); })
      .catch(() => setLoading(false));
  };

  useEffect(load, []);

  const del = (id) => {
    if (!confirm('Delete this schedule?')) return;
    apiFetch(`/api/schedules/${id}`, { method: 'DELETE' }).then(load);
  };

  const toggle = (s) => {
    apiFetch(`/api/schedules/${s.id}`, { method: 'PUT', body: JSON.stringify({ enabled: !s.enabled }) }).then(load);
  };

  const runNow = (s) => {
    apiFetch('/api/reports/run', { method: 'POST', body: JSON.stringify({ moduleId: s.moduleId, target: s.target, credentials: s.credentials, options: s.options }) });
  };

  const createSchedule = (data) => {
    apiFetch('/api/schedules', { method: 'POST', body: JSON.stringify(data) })
      .then(() => { setShowNew(false); load(); });
  };

  const saveEdit = (data) => {
    // Merge credentials: keep stored password if not changed
    const merged = { ...data };
    if (!merged.credentials.password && editing.credentials?.password) {
      merged.credentials.password = editing.credentials.password;
    }
    apiFetch(`/api/schedules/${editing.id}`, { method: 'PUT', body: JSON.stringify(merged) })
      .then(() => { setEditing(null); load(); });
  };

  // Prefill edit form from existing schedule
  const openEdit = (s) => {
    setEditing({
      ...s,
      username:  s.credentials?.username || '',
      password:  '', // don't pre-fill password for security
      formats:   s.options?.formats || ['HTML'],
    });
  };

  return (
    <div className="h-full flex flex-col">
      {showNew && <ScheduleForm title="New Scheduled Report" onClose={() => setShowNew(false)} onSave={createSchedule} />}
      {editing  && <ScheduleForm title="Edit Schedule" initial={editing} onClose={() => setEditing(null)} onSave={saveEdit} />}

      {/* Header */}
      <div className="px-6 py-4 border-b border-abr-border flex items-center gap-4">
        <Clock size={16} className="text-abr-accent" />
        <div>
          <h1 className="text-sm font-semibold text-abr-text">Report Scheduler</h1>
          <p className="text-xs text-abr-sub">{schedules.length} scheduled · checks every 30 seconds</p>
        </div>
        <div className="ml-auto flex gap-2">
          <button onClick={load} className="p-1.5 text-abr-sub hover:text-abr-text border border-abr-border hover:border-abr-muted rounded-lg transition-all">
            <RefreshCw size={13} className={loading ? 'animate-spin' : ''} />
          </button>
          <button onClick={() => setShowNew(true)}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs bg-abr-accent text-white hover:bg-blue-400 transition-all">
            <Plus size={12} /> New Schedule
          </button>
        </div>
      </div>

      {/* Body */}
      <div className="flex-1 overflow-y-auto p-6">
        {loading && (
          <div className="flex items-center justify-center h-40 gap-2 text-abr-sub text-sm">
            <RefreshCw size={14} className="animate-spin" /> Loading schedules…
          </div>
        )}
        {!loading && schedules.length === 0 && (
          <div className="flex flex-col items-center justify-center h-40 gap-3 text-abr-sub">
            <Calendar size={36} className="opacity-20" />
            <p className="text-sm">No schedules yet</p>
            <p className="text-xs opacity-60">Click "New Schedule" to automate your reports</p>
          </div>
        )}
        {!loading && schedules.length > 0 && (
          <div className="space-y-3">
            {schedules.map(s => (
              <div key={s.id} className={`bg-abr-surface border rounded-xl overflow-hidden transition-all ${s.enabled ? 'border-abr-border' : 'border-abr-border opacity-60'}`}>
                <div className="px-4 py-3 flex items-center gap-3">
                  {/* Toggle */}
                  <button onClick={() => toggle(s)} title={s.enabled ? 'Disable' : 'Enable'}
                    className="shrink-0 text-abr-sub hover:text-abr-accent transition-colors">
                    {s.enabled
                      ? <ToggleRight size={20} className="text-abr-accent" />
                      : <ToggleLeft  size={20} />}
                  </button>

                  {/* Info */}
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 flex-wrap">
                      <span className="text-sm font-medium text-abr-text">{s.label || `${s.moduleId} — ${s.target}`}</span>
                      <FreqBadge frequency={s.frequency} />
                    </div>
                    <div className="flex items-center gap-4 mt-1 text-xs text-abr-sub flex-wrap">
                      <span className="font-mono">{s.target}</span>
                      <span>·</span>
                      <span>{s.options?.formats?.join(', ') || 'HTML'}</span>
                      <span>·</span>
                      <span className="flex items-center gap-1"><Clock size={10} />Next: {fmtDate(s.nextRun)}</span>
                      {s.lastRun && <><span>·</span><span>Last: {fmtDate(s.lastRun)}</span></>}
                    </div>
                  </div>

                  {/* Actions */}
                  <div className="flex items-center gap-1.5 shrink-0">
                    <button onClick={() => runNow(s)} title="Run now"
                      className="p-1.5 text-abr-sub hover:text-abr-accent border border-abr-border hover:border-abr-accent/40 rounded-lg transition-all">
                      <Play size={12} />
                    </button>
                    <button onClick={() => openEdit(s)} title="Edit schedule"
                      className="p-1.5 text-abr-sub hover:text-abr-accent border border-abr-border hover:border-abr-accent/40 rounded-lg transition-all">
                      <Edit2 size={12} />
                    </button>
                    <button onClick={() => del(s.id)} title="Delete schedule"
                      className="p-1.5 text-abr-sub hover:text-abr-danger border border-abr-border hover:border-abr-danger/40 rounded-lg transition-all">
                      <Trash2 size={12} />
                    </button>
                  </div>
                </div>

                {/* Detail bar */}
                <div className="px-4 py-2 bg-abr-bg border-t border-abr-border flex items-center gap-3 text-xs text-abr-sub font-mono">
                  <span className="text-abr-sub/60">ID</span><span>{s.id}</span>
                  <span className="mx-1 opacity-30">·</span>
                  <span className="text-abr-sub/60">Created</span><span>{fmtDate(s.createdAt)}</span>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}
