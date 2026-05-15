import React, { useState, useEffect } from 'react';
import { CheckCircle, XCircle, Loader, AlertTriangle, Zap, RefreshCw } from 'lucide-react';

export default function SetupWizard({ onComplete }) {
  const [deps, setDeps] = useState([]);
  const [loading, setLoading] = useState(true);

  const check = () => {
    setLoading(true);
    fetch('/api/health/dependencies', { headers: { 'Authorization': 'Bearer ' + (localStorage.getItem('abr_token') || '') } })
      .then((r) => r.json())
      .then((d) => { setDeps(d.dependencies || []); setLoading(false); })
      .catch(() => { setLoading(false); });
  };

  useEffect(check, []);

  const allRequired = deps.filter((d) => d.required).every((d) => d.ok);
  const workerOffline = deps.some((d) => d.name === 'Worker service' && !d.ok);

  return (
    <div className="h-screen w-screen flex items-center justify-center bg-abr-bg noise-bg">
      {/* Grid lines */}
      <div className="absolute inset-0 pointer-events-none"
        style={{
          backgroundImage: 'linear-gradient(rgba(59,130,246,0.04) 1px, transparent 1px), linear-gradient(90deg, rgba(59,130,246,0.04) 1px, transparent 1px)',
          backgroundSize: '48px 48px'
        }} />

      <div className="relative z-10 w-full max-w-lg animate-slide-up">
        {/* Header */}
        <div className="flex items-center gap-3 mb-8">
          <div className="w-10 h-10 rounded-xl bg-abr-accent/10 border border-abr-accent/30 flex items-center justify-center">
            <Zap size={20} className="text-abr-accent" />
          </div>
          <div>
            <h1 className="text-lg font-semibold text-abr-text">AsBuiltReport Manager</h1>
            <p className="text-xs text-abr-sub">Appliance Dependency Check</p>
          </div>
        </div>

        {/* Dep Cards */}
        <div className="bg-abr-surface border border-abr-border rounded-xl overflow-hidden">
          <div className="px-4 py-3 border-b border-abr-border flex items-center justify-between">
            <span className="text-xs font-medium text-abr-sub uppercase tracking-widest">System Dependencies</span>
            <button onClick={check} className="text-abr-sub hover:text-abr-text transition-colors">
              <RefreshCw size={14} className={loading ? 'animate-spin' : ''} />
            </button>
          </div>

          <div className="divide-y divide-abr-border">
            {loading && (
              <div className="px-4 py-8 flex items-center justify-center gap-2 text-abr-sub text-sm">
                <Loader size={16} className="animate-spin" /> Checking dependencies…
              </div>
            )}
            {!loading && deps.map((dep) => (
              <div key={dep.name} className="px-4 py-3 flex items-center gap-3">
                {dep.ok
                  ? <CheckCircle size={16} className="text-abr-success shrink-0" />
                  : dep.required
                    ? <XCircle size={16} className="text-abr-danger shrink-0" />
                    : <AlertTriangle size={16} className="text-abr-warn shrink-0" />}
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2">
                    <span className="text-sm text-abr-text">{dep.name}</span>
                    {dep.required && !dep.ok && (
                      <span className="text-xs bg-abr-danger/10 text-abr-danger border border-abr-danger/20 px-1.5 py-0.5 rounded">Required</span>
                    )}
                    {!dep.required && (
                      <span className="text-xs bg-abr-muted text-abr-sub border border-abr-border px-1.5 py-0.5 rounded">Optional</span>
                    )}
                  </div>
                  {dep.ok && dep.version && (
                    <p className="text-xs text-abr-sub font-mono mt-0.5 truncate">{dep.version}</p>
                  )}
                  {!dep.ok && (
                    <p className="text-xs text-abr-sub mt-0.5">
                      {dep.required ? 'Install required before proceeding.' : 'Optional — some features may be unavailable.'}
                    </p>
                  )}
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* Install Hint */}
        {!loading && !allRequired && (
          <div className="mt-4 p-4 bg-abr-danger/5 border border-abr-danger/20 rounded-xl">
            <p className="text-xs text-abr-danger font-mono mb-2">
              {workerOffline ? 'Worker container not ready yet — wait ~60s then refresh.' : 'Missing required dependencies. Install with:'}
            </p>
            <pre className="text-xs text-abr-sub bg-abr-bg rounded-lg p-3 overflow-x-auto">{`# Install PowerShell 7
wget -q https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb
sudo dpkg -i packages-microsoft-prod.deb
sudo apt-get update && sudo apt-get install -y powershell

# Install Graphviz (optional)
sudo apt-get install -y graphviz`}</pre>
          </div>
        )}

        {/* CTA */}
        <div className="mt-6 flex gap-3">
          <button
            onClick={onComplete}
            disabled={!allRequired}
            className={`flex-1 py-2.5 rounded-lg text-sm font-medium transition-all duration-150 ${
              allRequired
                ? 'bg-abr-accent text-white hover:bg-blue-400'
                : 'bg-abr-muted text-abr-sub cursor-not-allowed'
            }`}
          >
            {allRequired ? 'Launch Manager →' : 'Resolve Required Dependencies'}
          </button>
          {!allRequired && (
            <button onClick={onComplete} className="px-4 py-2.5 rounded-lg text-sm text-abr-sub hover:text-abr-text border border-abr-border hover:border-abr-muted transition-all">
              Skip
            </button>
          )}
        </div>
      </div>
    </div>
  );
}
