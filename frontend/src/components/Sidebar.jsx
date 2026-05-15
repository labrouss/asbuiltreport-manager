import React from 'react';
import { Home, LayoutDashboard, Settings2, Terminal, FolderOpen, Clock, Users, Wifi, WifiOff, Zap, LogOut } from 'lucide-react';

const NAV = [
  { id: 'home',      label: 'Dashboard', Icon: Home },
  { id: 'dashboard', label: 'Modules',   Icon: LayoutDashboard },
  { id: 'config',    label: 'Config',    Icon: Settings2 },
  { id: 'console',   label: 'Console',   Icon: Terminal },
  { id: 'gallery',   label: 'Reports',   Icon: FolderOpen },
  { id: 'scheduler', label: 'Scheduler', Icon: Clock },
  { id: 'users',     label: 'Users',     Icon: Users },
];

export default function Sidebar({ page, setPage, wsReady, user, onLogout }) {
  return (
    <aside className="w-16 flex flex-col items-center py-4 gap-1 border-r border-abr-border bg-abr-surface shrink-0">
      <div className="mb-6 flex items-center justify-center w-9 h-9 rounded-lg bg-abr-accent/10 border border-abr-accent/30">
        <Zap size={18} className="text-abr-accent" />
      </div>

      {NAV.map(({ id, label, Icon }) => (
        <button key={id} onClick={() => setPage(id)} title={label}
          className={`group relative flex items-center justify-center w-10 h-10 rounded-lg transition-all duration-150
            ${page === id ? 'bg-abr-accent/15 text-abr-accent' : 'text-abr-sub hover:text-abr-text hover:bg-abr-muted'}`}>
          <Icon size={18} />
          {page === id && <span className="absolute left-0 w-0.5 h-5 bg-abr-accent rounded-r-full" />}
          <span className="absolute left-14 hidden group-hover:block text-xs bg-abr-muted border border-abr-border text-abr-text px-2 py-1 rounded whitespace-nowrap z-50 pointer-events-none">
            {label}
          </span>
        </button>
      ))}

      <div className="mt-auto flex flex-col items-center gap-2">
        {/* User avatar */}
        <div title={user?.username} className="w-7 h-7 rounded-full bg-abr-accent/20 border border-abr-accent/30 flex items-center justify-center text-xs font-bold text-abr-accent">
          {user?.username?.[0]?.toUpperCase() || '?'}
        </div>
        {/* WS indicator */}
        <div title={wsReady ? 'Live' : 'Disconnected'}>
          {wsReady ? <Wifi size={13} className="text-abr-success" /> : <WifiOff size={13} className="text-abr-sub" />}
        </div>
        {/* Logout */}
        <button onClick={onLogout} title="Sign out"
          className="p-1.5 text-abr-sub hover:text-abr-danger rounded-lg transition-colors">
          <LogOut size={14} />
        </button>
      </div>
    </aside>
  );
}
