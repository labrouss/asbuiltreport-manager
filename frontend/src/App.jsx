import React, { useState, useEffect } from 'react';
// Auth fetch helper
function apiFetch(url, opts = {}) {
  const token = localStorage.getItem('abr_token');
  return fetch(url, { ...opts, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: 'Bearer ' + token } : {}), ...(opts.headers || {}) } });
}
import Login from './components/Login.jsx';
import Sidebar from './components/Sidebar.jsx';
import SetupWizard from './components/SetupWizard.jsx';
import MainDashboard from './components/MainDashboard.jsx';
import ModuleDashboard from './components/ModuleDashboard.jsx';
import ConfigBuilder from './components/ConfigBuilder.jsx';
import ExecutionConsole from './components/ExecutionConsole.jsx';
import ReportGallery from './components/ReportGallery.jsx';
import Scheduler from './components/Scheduler.jsx';
import UserManagement from './components/UserManagement.jsx';

export default function App() {
  const [token, setToken]           = useState(() => localStorage.getItem('abr_token'));
  const [user, setUser]             = useState(() => { try { return JSON.parse(localStorage.getItem('abr_user')); } catch { return null; } });
  const [page, setPage]             = useState('home');
  const [selectedModule, setSelectedModule] = useState(null);
  const [showSetup, setShowSetup]   = useState(false);
  const [wsReady, setWsReady]       = useState(false);
  const [logLines, setLogLines]     = useState([]);
  const [activeJob, setActiveJob]   = useState(null);
  const [runToast, setRunToast]     = useState(null);

  // Auth is handled per-component via apiFetch() from api.js

  // WebSocket
  useEffect(() => {
    if (!token) return;
    const socket = new WebSocket(`ws://${window.location.hostname}:${window.location.port || 3001}`);
    socket.onopen  = () => setWsReady(true);
    socket.onclose = () => setWsReady(false);
    socket.onmessage = (e) => {
      try {
        const msg = JSON.parse(e.data);
        if (msg.type === 'report:stdout' || msg.type === 'report:stderr')
          setLogLines(p => [...p, { text: msg.payload.line, type: msg.type === 'report:stderr' ? 'err' : 'info' }]);
        if (msg.type === 'report:start') { setActiveJob(msg.payload.jobId); } // no forced nav — user stays on current page
        if (msg.type === 'report:done')  { setActiveJob(null); }
        if (msg.type === 'install:stdout') setLogLines(p => [...p, { text: msg.payload.line, type: 'info' }]);
      } catch (_) {}
    };
    return () => socket.close();
  }, [token]);

  // Dependency check
  useEffect(() => {
    if (!token) return;
    apiFetch('/api/health/dependencies')
      .then(r => r.json())
      .then(d => { if (d.dependencies?.some(dep => dep.required && !dep.ok)) setShowSetup(true); })
      .catch(() => {});
  }, [token]);

  const handleLogin = (tok, usr) => {
    localStorage.setItem('abr_token', tok);
    localStorage.setItem('abr_user', JSON.stringify(usr));
    setToken(tok); setUser(usr);
  };

  const handleLogout = () => {
    localStorage.removeItem('abr_token'); localStorage.removeItem('abr_user');
    setToken(null); setUser(null); setPage('home');
  };

  const navigate = (p) => {
    if (p === 'modules') setPage('dashboard');
    else setPage(p);
  };

  if (!token) return <Login onLogin={handleLogin} />;
  if (showSetup) return <SetupWizard onComplete={() => setShowSetup(false)} />;

  const handleModuleSelect = (mod) => { setSelectedModule(mod); setPage('config'); };
  const handleRunReport = (params) => {
    setLogLines([]);
    apiFetch('/api/reports/run', { method: 'POST', body: JSON.stringify(params) });
    // Don't force navigate — show a toast instead so user can keep working
    setRunToast({ moduleId: params.moduleId, target: params.target });
    setTimeout(() => setRunToast(null), 4000);
  };

  return (
    <div className="flex h-screen w-screen overflow-hidden bg-abr-bg noise-bg">
      <Sidebar page={page} setPage={setPage} wsReady={wsReady} user={user} onLogout={handleLogout} activeJob={activeJob} />
      {/* Non-blocking run notification */}
      {runToast && (
        <div className="fixed bottom-6 right-6 z-50 flex items-center gap-3 bg-abr-surface border border-abr-accent/30 rounded-xl px-4 py-3 shadow-2xl animate-slide-up">
          <div className="w-2 h-2 rounded-full bg-abr-accent animate-pulse" />
          <div>
            <p className="text-xs font-medium text-abr-text">Report started</p>
            <p className="text-xs text-abr-sub">{runToast.moduleId} → {runToast.target}</p>
          </div>
          <button onClick={() => { setRunToast(null); setPage('console'); }}
            className="text-xs text-abr-accent hover:text-blue-300 ml-2 transition-colors">
            View →
          </button>
        </div>
      )}
      <main className="flex-1 overflow-hidden">
        {page === 'home'      && <MainDashboard onNavigate={navigate} user={user} />}
        {page === 'dashboard' && <ModuleDashboard onSelect={handleModuleSelect} />}
        {page === 'config'    && <ConfigBuilder module={selectedModule} onRun={handleRunReport} onBack={() => setPage('dashboard')} />}
        {page === 'console'   && <ExecutionConsole logLines={logLines} activeJob={activeJob} setLogLines={setLogLines} />}
        {page === 'gallery'   && <ReportGallery />}
        {page === 'scheduler' && <Scheduler />}
        {page === 'users'     && <UserManagement currentUser={user} />}
      </main>
    </div>
  );
}
