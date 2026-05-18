import React, { useState, useEffect } from 'react';
import { ArrowLeft, Save, Play, Eye, EyeOff, ChevronDown, ChevronRight, Loader, CheckCircle, Clock, X } from 'lucide-react';
// Auth fetch helper
function apiFetch(url, opts = {}) {
  const token = localStorage.getItem('abr_token');
  return fetch(url, { ...opts, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}), ...(opts.headers || {}) } });
}

// ── Field Renderer ─────────────────────────────────────────────────────────────
function Field({ label, value, onChange, type = 'text', options, hint }) {
  const [show, setShow] = useState(false);
  const isPass = type === 'password';
  const isBool = type === 'boolean';
  const isSelect = type === 'select';

  if (isBool) return (
    <label className="flex items-center justify-between cursor-pointer group">
      <div>
        <span className="text-xs text-abr-text">{label}</span>
        {hint && <p className="text-xs text-abr-sub mt-0.5">{hint}</p>}
      </div>
      <div onClick={() => onChange(!value)}
        className={`relative w-10 h-5 rounded-full transition-colors duration-200 ${value ? 'bg-abr-accent' : 'bg-abr-muted border border-abr-border'}`}>
        <div className={`absolute top-0.5 w-4 h-4 rounded-full bg-white shadow transition-transform duration-200 ${value ? 'translate-x-5' : 'translate-x-0.5'}`} />
      </div>
    </label>
  );

  if (isSelect) return (
    <div>
      <label className="block text-xs text-abr-sub mb-1.5">{label}</label>
      <div className="relative">
        <select value={value} onChange={(e) => onChange(e.target.value)}
          className="w-full bg-abr-bg border border-abr-border rounded-lg px-3 py-2 text-xs text-abr-text focus:outline-none focus:border-abr-accent appearance-none pr-8">
          {options.map((o) => <option key={o} value={o}>{o}</option>)}
        </select>
        <ChevronDown size={12} className="absolute right-3 top-1/2 -translate-y-1/2 text-abr-sub pointer-events-none" />
      </div>
      {hint && <p className="text-xs text-abr-sub mt-1">{hint}</p>}
    </div>
  );

  return (
    <div>
      <label className="block text-xs text-abr-sub mb-1.5">{label}</label>
      <div className="relative">
        <input
          type={isPass && !show ? 'password' : 'text'}
          value={value || ''}
          onChange={(e) => onChange(e.target.value)}
          className="w-full bg-abr-bg border border-abr-border rounded-lg px-3 py-2 text-xs text-abr-text font-mono placeholder-abr-sub focus:outline-none focus:border-abr-accent transition-colors pr-8"
          placeholder={hint || label}
        />
        {isPass && (
          <button type="button" onClick={() => setShow(!show)}
            className="absolute right-3 top-1/2 -translate-y-1/2 text-abr-sub hover:text-abr-text">
            {show ? <EyeOff size={12} /> : <Eye size={12} />}
          </button>
        )}
      </div>
      {hint && !isPass && <p className="text-xs text-abr-sub mt-1">{hint}</p>}
    </div>
  );
}

// ── Section ────────────────────────────────────────────────────────────────────
function Section({ title, children, defaultOpen = true }) {
  const [open, setOpen] = useState(defaultOpen);
  return (
    <div className="border border-abr-border rounded-xl overflow-hidden">
      <button onClick={() => setOpen(!open)}
        className="w-full px-4 py-3 flex items-center gap-2 bg-abr-surface hover:bg-abr-muted transition-colors text-left">
        {open ? <ChevronDown size={14} className="text-abr-sub" /> : <ChevronRight size={14} className="text-abr-sub" />}
        <span className="text-xs font-medium text-abr-text uppercase tracking-widest">{title}</span>
      </button>
      {open && <div className="p-4 bg-abr-bg grid grid-cols-2 gap-4">{children}</div>}
    </div>
  );
}

// ── Main Config Builder ────────────────────────────────────────────────────────

// ── Quick Schedule Form (inline in ConfigBuilder) ────────────────────────────
function QuickScheduleForm({ moduleId, target, creds, formats, onSave, onClose }) {
  const [frequency, setFrequency] = useState('daily');
  const [time, setTime]           = useState('06:00');
  const [dayOfWeek, setDayOfWeek] = useState(1);
  const [dayOfMonth, setDayOfMonth] = useState(1);
  const [label, setLabel]         = useState('');
  const DAYS = ['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'];
  const inp = "w-full bg-abr-bg border border-abr-border rounded-lg px-3 py-2 text-xs font-mono text-abr-text focus:outline-none focus:border-abr-accent";

  const save = () => {
    onSave({
      moduleId, target: target.trim(),
      label: label || `${moduleId} — ${target}`,
      credentials: creds,
      options: { formats },
      frequency, time, dayOfWeek, dayOfMonth, minute: 0,
    });
  };

  return (
    <div className="p-5 space-y-4">
      <div>
        <label className="block text-xs text-abr-sub mb-1.5">Label (optional)</label>
        <input className={inp} value={label} onChange={e => setLabel(e.target.value)} placeholder={`${moduleId} — ${target}`} />
      </div>
      <div>
        <label className="block text-xs text-abr-sub mb-1.5">Frequency</label>
        <div className="flex gap-2 flex-wrap">
          {['hourly','daily','weekly','monthly'].map(f => (
            <button key={f} onClick={() => setFrequency(f)}
              className={`px-3 py-1.5 rounded-lg text-xs border capitalize transition-all ${frequency === f ? 'bg-abr-accent/15 text-abr-accent border-abr-accent/30' : 'bg-abr-bg text-abr-sub border-abr-border hover:border-abr-muted'}`}>
              {f}
            </button>
          ))}
        </div>
      </div>
      {frequency !== 'hourly' && (
        <div className="grid grid-cols-2 gap-3">
          <div>
            <label className="block text-xs text-abr-sub mb-1.5">Time</label>
            <input className={inp} type="time" value={time} onChange={e => setTime(e.target.value)} />
          </div>
          {frequency === 'weekly' && (
            <div>
              <label className="block text-xs text-abr-sub mb-1.5">Day</label>
              <select className={inp + ' cursor-pointer'} value={dayOfWeek} onChange={e => setDayOfWeek(+e.target.value)}>
                {DAYS.map((d,i) => <option key={i} value={i}>{d}</option>)}
              </select>
            </div>
          )}
          {frequency === 'monthly' && (
            <div>
              <label className="block text-xs text-abr-sub mb-1.5">Day of month</label>
              <input className={inp} type="number" min="1" max="28" value={dayOfMonth} onChange={e => setDayOfMonth(+e.target.value)} />
            </div>
          )}
        </div>
      )}
      <div className="p-3 bg-abr-muted/50 rounded-lg text-xs text-abr-sub space-y-1">
        <div className="flex justify-between"><span>Module</span><span className="text-abr-text font-mono">{moduleId}</span></div>
        <div className="flex justify-between"><span>Target</span><span className="text-abr-text font-mono">{target}</span></div>
        <div className="flex justify-between"><span>Formats</span><span className="text-abr-text">{formats.join(', ')}</span></div>
      </div>
      <div className="flex gap-2">
        <button onClick={onClose} className="flex-1 py-2 rounded-lg border border-abr-border text-abr-sub text-xs hover:text-abr-text transition-all">Cancel</button>
        <button onClick={save} className="flex-1 py-2 rounded-lg bg-abr-accent text-white text-xs hover:bg-blue-400 transition-all flex items-center justify-center gap-1.5">
          <Clock size={11} /> Save Schedule
        </button>
      </div>
    </div>
  );
}

export default function ConfigBuilder({ module: mod, onRun, onBack }) {
  const [config, setConfig] = useState(null);
  const [target, setTarget] = useState('');
  const [creds, setCreds] = useState({ username: '', password: '' });

  // Reset connection fields when module changes
  useEffect(() => { setTarget(''); setCreds({ username: '', password: '' }); }, [mod?.id]);
  const [formats, setFormats] = useState(['HTML']);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved]   = useState(false);
  const [showSchedule, setShowSchedule] = useState(false);

  useEffect(() => {
    if (!mod) return;
    apiFetch(`/api/modules/${mod.id}/config`)
      .then((r) => r.json())
      .then((d) => setConfig(d.config));
  }, [mod]);

  const updateConfig = (path, val) => {
    setConfig((prev) => {
      const next = JSON.parse(JSON.stringify(prev));
      const keys = path.split('.');
      let cur = next;
      for (let i = 0; i < keys.length - 1; i++) cur = cur[keys[i]];
      cur[keys[keys.length - 1]] = val;
      return next;
    });
  };

  const save = () => {
    setSaving(true);
    apiFetch(`/api/modules/${mod.id}/config`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ config }),
    }).then(() => { setSaving(false); setSaved(true); setTimeout(() => setSaved(false), 2000); });
  };

  const run = () => {
    save();
    // RVTools always outputs Excel; other modules use selected formats
    const runFormats = mod.id === 'VMware.RVTools' ? ['Excel'] : formats;
    onRun({ moduleId: mod.id, target: target.trim(), credentials: creds, options: { formats: runFormats } });
  };

  const toggleFormat = (f) => setFormats((prev) => prev.includes(f) ? prev.filter((x) => x !== f) : [...prev, f]);

  if (!mod) return (
    <div className="flex-1 flex items-center justify-center text-abr-sub text-sm">
      Select a module from the dashboard to configure it.
    </div>
  );

  if (!config) return (
    <div className="flex-1 flex items-center justify-center gap-2 text-abr-sub text-sm">
      <Loader size={16} className="animate-spin" /> Loading configuration…
    </div>
  );

  const saveSchedule = (schedData) => {
    apiFetch('/api/schedules', { method: 'POST', body: JSON.stringify(schedData) })
      .then(() => { setShowSchedule(false); setSaved(true); setTimeout(() => setSaved(false), 2000); });
  };

  return (
    <div className="h-full flex flex-col">
      {/* Quick Schedule Modal */}
      {showSchedule && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm">
          <div className="bg-abr-surface border border-abr-border rounded-xl w-full max-w-sm shadow-2xl animate-slide-up">
            <div className="px-5 py-4 border-b border-abr-border flex items-center gap-2">
              <Clock size={15} className="text-abr-accent" />
              <h2 className="text-sm font-semibold text-abr-text">Schedule This Report</h2>
              <button onClick={() => setShowSchedule(false)} className="ml-auto text-abr-sub hover:text-abr-text text-xl leading-none">×</button>
            </div>
            <QuickScheduleForm
              moduleId={mod.id} target={target} creds={creds} formats={formats}
              onSave={saveSchedule} onClose={() => setShowSchedule(false)}
            />
          </div>
        </div>
      )}
      {/* Top Bar */}
      <div className="px-6 py-4 border-b border-abr-border flex items-center gap-4">
        <button onClick={onBack} className="flex items-center gap-1.5 text-xs text-abr-sub hover:text-abr-text transition-colors">
          <ArrowLeft size={14} /> Modules
        </button>
        <div className="w-px h-4 bg-abr-border" />
        <span className="text-lg">{mod.icon}</span>
        <div>
          <h1 className="text-sm font-semibold text-abr-text">{mod.name}</h1>
          <p className="text-xs text-abr-sub">AsBuiltReport.{mod.id}</p>
        </div>
        <div className="ml-auto flex gap-2">
          <button onClick={save} disabled={saving}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs border border-abr-border text-abr-sub hover:text-abr-text hover:border-abr-muted transition-all">
            {saving ? <Loader size={12} className="animate-spin" /> : saved ? <CheckCircle size={12} className="text-abr-success" /> : <Save size={12} />}
            {saved ? 'Saved!' : 'Save Config'}
          </button>
          <button onClick={() => { save(); setShowSchedule(true); }} disabled={!target || !creds.username || !creds.password}
            className="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs border border-abr-border text-abr-sub hover:text-abr-accent hover:border-abr-accent/40 disabled:opacity-40 disabled:cursor-not-allowed transition-all">
            <Clock size={12} /> Schedule
          </button>
          <button onClick={run} disabled={!target || !creds.username || !creds.password}
            className="flex items-center gap-1.5 px-4 py-1.5 rounded-lg text-xs bg-abr-accent text-white hover:bg-blue-400 disabled:opacity-40 disabled:cursor-not-allowed transition-all">
            <Play size={12} /> Run Now
          </button>
        </div>
      </div>

      {/* Form Body */}
      <div className="flex-1 overflow-y-auto p-6 space-y-4">
        {/* Target + Credentials */}
        <Section title="Connection" defaultOpen>
          <div className="col-span-2">
            <Field label="Target Host / IP" value={target} onChange={setTarget} hint="e.g. vcenter.lab.local or 192.168.1.100" />
          </div>
          <Field label="Username" value={creds.username} onChange={(v) => setCreds((p) => ({ ...p, username: v }))} hint="domain\user or user@domain" />
          <Field label="Password" value={creds.password} onChange={(v) => setCreds((p) => ({ ...p, password: v }))} type="password" />
        </Section>

        {/* Report Metadata */}
        <Section title="Report Settings">
          <Field label="Report Name" value={config.Report?.Name} onChange={(v) => updateConfig('Report.Name', v)} />
          <Field label="Version" value={config.Report?.Version} onChange={(v) => updateConfig('Report.Version', v)} />
          <Field label="Status" value={config.Report?.Status} onChange={(v) => updateConfig('Report.Status', v)}
            type="select" options={['Released', 'Draft', 'Review', 'Deprecated']} />
          <Field label="Output Path" value={config.OutputFolderPath} onChange={(v) => updateConfig('OutputFolderPath', v)} hint="Absolute path on appliance" />
          <Field label="Add Timestamp" value={config.Timestamp} onChange={(v) => updateConfig('Timestamp', v)} type="boolean" />
          <Field label="Show Cover Image" value={config.Report?.ShowCoverPageImage} onChange={(v) => updateConfig('Report.ShowCoverPageImage', v)} type="boolean" />
          <Field label="Table of Contents" value={config.Report?.ShowTableOfContents} onChange={(v) => updateConfig('Report.ShowTableOfContents', v)} type="boolean" />
          <Field label="Section Numbers" value={config.Report?.ShowSectionNumbers} onChange={(v) => updateConfig('Report.ShowSectionNumbers', v)} type="boolean" />
        </Section>

        {/* Company Info */}
        <Section title="Company Branding" defaultOpen={false}>
          <Field label="Company Full Name" value={config.UserDefinedVariables?.Company?.FullName} onChange={(v) => updateConfig('UserDefinedVariables.Company.FullName', v)} />
          <Field label="Short Name / Acronym" value={config.UserDefinedVariables?.Company?.ShortName} onChange={(v) => updateConfig('UserDefinedVariables.Company.ShortName', v)} />
          <Field label="Contact Name" value={config.UserDefinedVariables?.Company?.Contact} onChange={(v) => updateConfig('UserDefinedVariables.Company.Contact', v)} />
          <Field label="Contact Email" value={config.UserDefinedVariables?.Company?.Email} onChange={(v) => updateConfig('UserDefinedVariables.Company.Email', v)} />
          <Field label="Phone" value={config.UserDefinedVariables?.Company?.Phone} onChange={(v) => updateConfig('UserDefinedVariables.Company.Phone', v)} />
          <div className="col-span-2">
            <Field label="Address" value={config.UserDefinedVariables?.Company?.Address} onChange={(v) => updateConfig('UserDefinedVariables.Company.Address', v)} />
          </div>
        </Section>

        {/* Output Formats */}
        <Section title="Output Formats">
          {mod.id === 'VMware.RVTools' && (
            <div className="col-span-2 flex items-center gap-2 p-3 bg-abr-accent/5 border border-abr-accent/20 rounded-lg text-xs text-abr-text">
              <span>📊</span>
              <span>RVTools export always generates a <strong>.xlsx</strong> file with 27 tabs — format selector does not apply.</span>
            </div>
          )}
          {mod.id !== 'VMware.RVTools' && (
            <div className="col-span-2 flex gap-3">
              {['HTML', 'Word', 'XML', 'Text'].map((f) => (
                <button key={f} onClick={() => toggleFormat(f)}
                  className={`px-4 py-2 rounded-lg text-xs font-medium border transition-all ${
                    formats.includes(f)
                      ? 'bg-abr-accent/15 text-abr-accent border-abr-accent/30'
                      : 'bg-abr-surface text-abr-sub border-abr-border hover:border-abr-muted'
                  }`}>
                  {f}
                </button>
              ))}
            </div>
          )}
        </Section>

        {/* Raw JSON Preview */}
        <Section title="Raw Configuration JSON" defaultOpen={false}>
          <div className="col-span-2">
            <pre className="text-xs text-abr-sub font-mono bg-abr-bg border border-abr-border rounded-lg p-4 overflow-x-auto max-h-64 overflow-y-auto">
              {JSON.stringify(config, null, 2)}
            </pre>
          </div>
        </Section>
      </div>
    </div>
  );
}
