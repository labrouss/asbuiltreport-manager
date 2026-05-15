import React, { useState, useEffect } from 'react';
// Auth fetch helper
function apiFetch(url, opts = {}) {
  const token = localStorage.getItem('abr_token');
  return fetch(url, { ...opts, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}), ...(opts.headers || {}) } });
}
import { ArrowLeft, Save, Play, Eye, EyeOff, ChevronDown, ChevronRight, Loader, CheckCircle } from 'lucide-react';

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
export default function ConfigBuilder({ module: mod, onRun, onBack }) {
  const [config, setConfig] = useState(null);
  const [target, setTarget] = useState('');
  const [creds, setCreds] = useState({ username: '', password: '' });

  // Reset connection fields when module changes
  useEffect(() => { setTarget(''); setCreds({ username: '', password: '' }); }, [mod?.id]);
  const [formats, setFormats] = useState(['HTML']);
  const [saving, setSaving] = useState(false);
  const [saved, setSaved] = useState(false);

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
    // Trim target to avoid doubled values from autofill
    onRun({ moduleId: mod.id, target: target.trim(), credentials: creds, options: { formats } });
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

  return (
    <div className="h-full flex flex-col">
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
          <button onClick={run} disabled={!target || !creds.username || !creds.password}
            className="flex items-center gap-1.5 px-4 py-1.5 rounded-lg text-xs bg-abr-accent text-white hover:bg-blue-400 disabled:opacity-40 disabled:cursor-not-allowed transition-all">
            <Play size={12} /> Run Report
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
