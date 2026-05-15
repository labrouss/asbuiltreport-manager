import React, { useState } from 'react';
import { Zap, Eye, EyeOff, Shield, AlertCircle, Loader } from 'lucide-react';

export default function Login({ onLogin }) {
  const [step, setStep]         = useState('credentials'); // credentials | totp | changepass
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [showPass, setShowPass] = useState(false);
  const [totpCode, setTotpCode] = useState('');
  const [partialToken, setPartialToken] = useState('');
  const [newPass, setNewPass]   = useState('');
  const [newPass2, setNewPass2] = useState('');
  const [token, setToken]       = useState('');
  const [error, setError]       = useState('');
  const [loading, setLoading]   = useState(false);

  const inp = "w-full bg-abr-bg border border-abr-border rounded-lg px-3 py-2.5 text-sm text-abr-text font-mono placeholder-abr-sub focus:outline-none focus:border-abr-accent transition-colors";

  const login = async (e) => {
    e.preventDefault();
    setError(''); setLoading(true);
    try {
      const r = await fetch('/api/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username, password }) });
      const d = await r.json();
      if (!r.ok) { setError(d.error); return; }
      if (d.requires2fa) { setPartialToken(d.partialToken); setStep('totp'); return; }
      if (d.mustChange)  { setToken(d.token); setStep('changepass'); return; }
      onLogin(d.token, d.user);
    } catch (_) { setError('Connection error'); }
    finally { setLoading(false); }
  };

  const submitTotp = async (e) => {
    e.preventDefault();
    setError(''); setLoading(true);
    try {
      const r = await fetch('/api/auth/totp', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ partialToken, code: totpCode }) });
      const d = await r.json();
      if (!r.ok) { setError(d.error); return; }
      if (d.mustChange) { setToken(d.token); setStep('changepass'); return; }
      onLogin(d.token, d.user);
    } catch (_) { setError('Connection error'); }
    finally { setLoading(false); }
  };

  const changePassword = async (e) => {
    e.preventDefault();
    setError('');
    if (newPass !== newPass2) { setError('Passwords do not match'); return; }
    setLoading(true);
    try {
      const r = await fetch('/api/auth/change-password', { // token passed via Authorization header below
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${token}` },
        body: JSON.stringify({ currentPassword: password, newPassword: newPass }),
      });
      const d = await r.json();
      if (!r.ok) { setError(d.error || (d.details?.join(', '))); return; }
      // Re-login with new password
      const r2 = await fetch('/api/auth/login', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ username, password: newPass }) });
      const d2 = await r2.json();
      if (d2.token) onLogin(d2.token, d2.user);
    } catch (_) { setError('Connection error'); }
    finally { setLoading(false); }
  };

  return (
    <div className="h-screen w-screen flex items-center justify-center bg-abr-bg noise-bg">
      <div className="absolute inset-0 pointer-events-none"
        style={{ backgroundImage: 'linear-gradient(rgba(59,130,246,0.04) 1px, transparent 1px), linear-gradient(90deg, rgba(59,130,246,0.04) 1px, transparent 1px)', backgroundSize: '48px 48px' }} />

      <div className="relative z-10 w-full max-w-sm animate-slide-up">
        {/* Logo */}
        <div className="flex flex-col items-center mb-8">
          <div className="w-12 h-12 rounded-xl bg-abr-accent/10 border border-abr-accent/30 flex items-center justify-center mb-4">
            <Zap size={22} className="text-abr-accent" />
          </div>
          <h1 className="text-lg font-semibold text-abr-text">AsBuiltReport Manager</h1>
          <p className="text-xs text-abr-sub mt-1">
            {step === 'credentials' && 'Sign in to your account'}
            {step === 'totp'        && 'Two-factor authentication'}
            {step === 'changepass'  && 'Set a new password'}
          </p>
        </div>

        <div className="bg-abr-surface border border-abr-border rounded-xl overflow-hidden">
          {/* ── Credentials ── */}
          {step === 'credentials' && (
            <form onSubmit={login} className="p-6 space-y-4">
              <div>
                <label className="block text-xs text-abr-sub mb-1.5">Username</label>
                <input className={inp} value={username} onChange={e => setUsername(e.target.value)} placeholder="admin" autoFocus autoComplete="username" />
              </div>
              <div>
                <label className="block text-xs text-abr-sub mb-1.5">Password</label>
                <div className="relative">
                  <input className={inp + ' pr-10'} type={showPass ? 'text' : 'password'} value={password} onChange={e => setPassword(e.target.value)} placeholder="••••••••••••" autoComplete="current-password" />
                  <button type="button" onClick={() => setShowPass(!showPass)} className="absolute right-3 top-1/2 -translate-y-1/2 text-abr-sub hover:text-abr-text">
                    {showPass ? <EyeOff size={14} /> : <Eye size={14} />}
                  </button>
                </div>
              </div>
              {error && <p className="text-xs text-abr-danger flex items-center gap-1.5"><AlertCircle size={12} />{error}</p>}
              <button type="submit" disabled={loading || !username || !password}
                className="w-full py-2.5 rounded-lg text-sm bg-abr-accent text-white hover:bg-blue-400 disabled:opacity-40 disabled:cursor-not-allowed transition-all flex items-center justify-center gap-2">
                {loading ? <><Loader size={14} className="animate-spin" /> Signing in…</> : 'Sign In →'}
              </button>
            </form>
          )}

          {/* ── TOTP ── */}
          {step === 'totp' && (
            <form onSubmit={submitTotp} className="p-6 space-y-4">
              <div className="flex items-center gap-3 p-3 bg-abr-accent/10 border border-abr-accent/20 rounded-lg">
                <Shield size={16} className="text-abr-accent shrink-0" />
                <p className="text-xs text-abr-text">Enter the 6-digit code from your authenticator app.</p>
              </div>
              <div>
                <label className="block text-xs text-abr-sub mb-1.5">Authentication Code</label>
                <input className={inp + ' text-center text-xl tracking-[0.5em]'} value={totpCode}
                  onChange={e => setTotpCode(e.target.value.replace(/\D/g, '').slice(0, 6))}
                  placeholder="000000" maxLength={6} autoFocus inputMode="numeric" />
              </div>
              {error && <p className="text-xs text-abr-danger flex items-center gap-1.5"><AlertCircle size={12} />{error}</p>}
              <div className="flex gap-2">
                <button type="button" onClick={() => { setStep('credentials'); setError(''); }}
                  className="flex-1 py-2.5 rounded-lg text-sm border border-abr-border text-abr-sub hover:text-abr-text transition-all">← Back</button>
                <button type="submit" disabled={loading || totpCode.length !== 6}
                  className="flex-1 py-2.5 rounded-lg text-sm bg-abr-accent text-white hover:bg-blue-400 disabled:opacity-40 transition-all flex items-center justify-center gap-2">
                  {loading ? <Loader size={14} className="animate-spin" /> : 'Verify'}
                </button>
              </div>
            </form>
          )}

          {/* ── Change password (mustChange) ── */}
          {step === 'changepass' && (
            <form onSubmit={changePassword} className="p-6 space-y-4">
              <div className="p-3 bg-abr-warn/10 border border-abr-warn/20 rounded-lg">
                <p className="text-xs text-abr-warn">You must set a new password before continuing.</p>
              </div>
              <div>
                <label className="block text-xs text-abr-sub mb-1.5">New Password</label>
                <input className={inp} type="password" value={newPass} onChange={e => setNewPass(e.target.value)} placeholder="Min 12 chars, upper, lower, number, symbol" autoFocus />
              </div>
              <div>
                <label className="block text-xs text-abr-sub mb-1.5">Confirm Password</label>
                <input className={inp} type="password" value={newPass2} onChange={e => setNewPass2(e.target.value)} placeholder="Repeat new password" />
              </div>
              <ul className="text-xs text-abr-sub space-y-0.5 pl-1">
                {[['12+ characters', newPass.length >= 12],['Uppercase', /[A-Z]/.test(newPass)],['Lowercase', /[a-z]/.test(newPass)],['Number', /[0-9]/.test(newPass)],['Symbol', /[^A-Za-z0-9]/.test(newPass)]].map(([l, ok]) => (
                  <li key={l} className={`flex items-center gap-1.5 ${ok ? 'text-abr-success' : ''}`}>
                    <span>{ok ? '✓' : '○'}</span>{l}
                  </li>
                ))}
              </ul>
              {error && <p className="text-xs text-abr-danger flex items-center gap-1.5"><AlertCircle size={12} />{error}</p>}
              <button type="submit" disabled={loading || newPass.length < 12 || newPass !== newPass2}
                className="w-full py-2.5 rounded-lg text-sm bg-abr-accent text-white hover:bg-blue-400 disabled:opacity-40 transition-all flex items-center justify-center gap-2">
                {loading ? <Loader size={14} className="animate-spin" /> : 'Set Password & Continue →'}
              </button>
            </form>
          )}
        </div>
        <p className="text-center text-xs text-abr-sub mt-4">AsBuiltReport Manager · Enterprise Edition</p>
      </div>
    </div>
  );
}
