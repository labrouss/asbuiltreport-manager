import React, { useState, useEffect } from 'react';
import { Users, Plus, Trash2, Shield, ShieldOff, Key, RefreshCw, AlertCircle, CheckCircle, Copy, Eye, EyeOff } from 'lucide-react';

function authFetch(url, opts) {
  var o = opts || {};
  var token = localStorage.getItem('abr_token');
  var headers = Object.assign({ 'Content-Type': 'application/json' }, token ? { 'Authorization': 'Bearer ' + token } : {}, o.headers || {});
  return fetch(url, Object.assign({}, o, { headers: headers }));
}

function PasswordStrength(props) {
  var p = props.password || '';
  var checks = [['12+ chars', p.length >= 12], ['Upper', /[A-Z]/.test(p)], ['Lower', /[a-z]/.test(p)], ['Number', /[0-9]/.test(p)], ['Symbol', /[^A-Za-z0-9]/.test(p)]];
  return React.createElement('div', { className: 'flex flex-wrap gap-1.5 mt-1.5' },
    checks.map(function(c) {
      return React.createElement('span', { key: c[0], className: 'text-xs px-1.5 py-0.5 rounded ' + (c[1] ? 'bg-green-400/10 text-green-400' : 'bg-abr-muted text-abr-sub') }, c[0]);
    })
  );
}

export default function UserManagement(props) {
  var [users, setUsers]   = useState([]);
  var [me, setMe]         = useState(null);
  var [loading, setLoading] = useState(true);
  var [error, setError]   = useState('');
  var [tab, setTab]       = useState('users');
  var [showAdd, setShowAdd] = useState(false);
  var [show2FA, setShow2FA] = useState(false);
  var [newUser, setNewUser] = useState({ username: '', password: '', role: 'user' });
  var [addError, setAddError] = useState('');
  var [adding, setAdding] = useState(false);
  var [changePw, setChangePw] = useState({ current: '', next: '', confirm: '' });
  var [pwError, setPwError] = useState('');
  var [pwOk, setPwOk]     = useState(false);
  var [totpSetup, setTotpSetup] = useState({ secret: '', uri: '', code: '', step: 'qr', error: '' });
  var [disable2faPass, setDisable2faPass] = useState('');
  var [msg2fa, setMsg2fa] = useState('');

  function load() {
    setLoading(true);
    setError('');
    authFetch('/api/auth/me')
      .then(function(r) { return r.ok ? r.json() : {}; })
      .then(function(mData) {
        setMe(mData);
        if (mData && mData.role === 'admin') {
          return authFetch('/api/users')
            .then(function(r) { return r.ok ? r.json() : r.json().then(function(e) { throw new Error(e.error || 'Failed'); }); })
            .then(function(d) { setUsers(d.users || []); })
            .catch(function(e) { setError(e.message); });
        } else {
          setError('Admin privileges required.');
        }
      })
      .catch(function(e) { setError(e.message); })
      .finally(function() { setLoading(false); });
  }

  useEffect(function() { load(); }, []);

  function deleteUser(username) {
    if (!confirm('Delete user "' + username + '"?')) return;
    authFetch('/api/users/' + username, { method: 'DELETE' }).then(load);
  }

  function addUser() {
    setAddError(''); setAdding(true);
    authFetch('/api/users', { method: 'POST', body: JSON.stringify(newUser) })
      .then(function(r) { return r.json().then(function(d) { return { ok: r.ok, d: d }; }); })
      .then(function(x) {
        if (!x.ok) { setAddError(x.d.error || (x.d.details || []).join(', ')); return; }
        setShowAdd(false); setNewUser({ username: '', password: '', role: 'user' }); load();
      })
      .catch(function(e) { setAddError(e.message); })
      .finally(function() { setAdding(false); });
  }

  function changePwSubmit() {
    setPwError(''); setPwOk(false);
    if (changePw.next !== changePw.confirm) { setPwError('Passwords do not match'); return; }
    authFetch('/api/auth/change-password', { method: 'POST', body: JSON.stringify({ currentPassword: changePw.current, newPassword: changePw.next }) })
      .then(function(r) { return r.json().then(function(d) { return { ok: r.ok, d: d }; }); })
      .then(function(x) {
        if (!x.ok) { setPwError(x.d.error || (x.d.details || []).join(', ')); return; }
        setPwOk(true); setChangePw({ current: '', next: '', confirm: '' });
        setTimeout(function() { setPwOk(false); }, 3000);
      })
      .catch(function(e) { setPwError(e.message); });
  }

  function setup2fa() {
    authFetch('/api/auth/setup-2fa', { method: 'POST' })
      .then(function(r) { return r.json(); })
      .then(function(d) { setTotpSetup(function(s) { return Object.assign({}, s, { secret: d.secret || '', uri: d.uri || '', step: 'qr', error: '' }); }); });
    setShow2FA(true);
  }

  function verify2fa() {
    authFetch('/api/auth/verify-2fa', { method: 'POST', body: JSON.stringify({ code: totpSetup.code }) })
      .then(function(r) { return r.json().then(function(d) { return { ok: r.ok, d: d }; }); })
      .then(function(x) {
        if (!x.ok) { setTotpSetup(function(s) { return Object.assign({}, s, { error: x.d.error }); }); return; }
        setShow2FA(false); load();
      });
  }

  function disable2fa() {
    authFetch('/api/auth/disable-2fa', { method: 'POST', body: JSON.stringify({ password: disable2faPass }) })
      .then(function(r) { return r.json().then(function(d) { return { ok: r.ok, d: d }; }); })
      .then(function(x) {
        if (!x.ok) { setMsg2fa(x.d.error); return; }
        setMsg2fa('2FA disabled'); setDisable2faPass(''); load();
        setTimeout(function() { setMsg2fa(''); }, 3000);
      });
  }

  var inp = 'w-full bg-abr-bg border border-abr-border rounded-lg px-3 py-2 text-sm font-mono text-abr-text focus:outline-none focus:border-abr-accent';
  var strong = newUser.password.length >= 12 && /[A-Z]/.test(newUser.password) && /[a-z]/.test(newUser.password) && /[0-9]/.test(newUser.password) && /[^A-Za-z0-9]/.test(newUser.password);
  var isAdmin = me && me.role === 'admin';

  return (
    <div className="h-full flex flex-col">
      {/* Add user modal */}
      {showAdd && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm">
          <div className="bg-abr-surface border border-abr-border rounded-xl w-full max-w-sm shadow-2xl">
            <div className="px-5 py-4 border-b border-abr-border flex items-center gap-2">
              <Plus size={15} className="text-abr-accent" />
              <h2 className="text-sm font-semibold text-abr-text">Add User</h2>
              <button onClick={() => setShowAdd(false)} className="ml-auto text-abr-sub text-xl">×</button>
            </div>
            <div className="p-5 space-y-4">
              <div><label className="block text-xs text-abr-sub mb-1">Username</label><input className={inp} value={newUser.username} onChange={e => setNewUser(p => ({...p, username: e.target.value}))} placeholder="jsmith" autoFocus /></div>
              <div>
                <label className="block text-xs text-abr-sub mb-1">Password</label>
                <input className={inp} type="password" value={newUser.password} onChange={e => setNewUser(p => ({...p, password: e.target.value}))} placeholder="Strong password" />
                <PasswordStrength password={newUser.password} />
              </div>
              <div><label className="block text-xs text-abr-sub mb-1">Role</label>
                <select className={inp + ' cursor-pointer'} value={newUser.role} onChange={e => setNewUser(p => ({...p, role: e.target.value}))}>
                  <option value="user">User</option><option value="admin">Admin</option>
                </select>
              </div>
              {addError && <p className="text-xs text-abr-danger">{addError}</p>}
              <div className="flex gap-2">
                <button onClick={() => setShowAdd(false)} className="flex-1 py-2 rounded-lg border border-abr-border text-abr-sub text-sm">Cancel</button>
                <button onClick={addUser} disabled={adding || !newUser.username || !strong}
                  className="flex-1 py-2 rounded-lg bg-abr-accent text-white text-sm disabled:opacity-40">
                  {adding ? 'Creating…' : 'Create User'}
                </button>
              </div>
            </div>
          </div>
        </div>
      )}

      {/* 2FA modal */}
      {show2FA && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/60 backdrop-blur-sm">
          <div className="bg-abr-surface border border-abr-border rounded-xl w-full max-w-sm shadow-2xl">
            <div className="px-5 py-4 border-b border-abr-border flex items-center gap-2">
              <Shield size={15} className="text-abr-accent" />
              <h2 className="text-sm font-semibold text-abr-text">Enable 2FA</h2>
              <button onClick={() => setShow2FA(false)} className="ml-auto text-abr-sub text-xl">×</button>
            </div>
            <div className="p-5 space-y-4">
              {totpSetup.step === 'qr' && <>
                {totpSetup.uri
                  ? <div className="flex flex-col items-center gap-2 p-4 bg-white rounded-xl"><img src={'https://api.qrserver.com/v1/create-qr-code/?size=160x160&data=' + encodeURIComponent(totpSetup.uri)} alt="QR" className="w-40 h-40" /><p className="text-xs text-gray-500">Scan with your authenticator app</p></div>
                  : <div className="h-40 flex items-center justify-center"><RefreshCw size={16} className="animate-spin text-abr-sub" /></div>
                }
                <div><label className="block text-xs text-abr-sub mb-1">Manual key</label><input readOnly className={inp + ' text-xs'} value={totpSetup.secret} /></div>
                <button onClick={() => setTotpSetup(s => ({...s, step: 'verify'}))} className="w-full py-2 rounded-lg bg-abr-accent text-white text-sm">Next →</button>
              </>}
              {totpSetup.step === 'verify' && <>
                <input value={totpSetup.code} onChange={e => setTotpSetup(s => ({...s, code: e.target.value.replace(/\D/g,'').slice(0,6)}))}
                  placeholder="000000" maxLength={6} autoFocus
                  className={inp + ' text-center text-xl tracking-[0.5em]'} />
                {totpSetup.error && <p className="text-xs text-abr-danger">{totpSetup.error}</p>}
                <div className="flex gap-2">
                  <button onClick={() => setTotpSetup(s => ({...s, step: 'qr'}))} className="flex-1 py-2 rounded-lg border border-abr-border text-abr-sub text-sm">← Back</button>
                  <button onClick={verify2fa} disabled={totpSetup.code.length !== 6} className="flex-1 py-2 rounded-lg bg-abr-accent text-white text-sm disabled:opacity-40">Verify</button>
                </div>
              </>}
            </div>
          </div>
        </div>
      )}

      {/* Header */}
      <div className="px-6 py-4 border-b border-abr-border flex items-center gap-3">
        <Users size={16} className="text-abr-accent" />
        <h1 className="text-sm font-semibold text-abr-text">Users & Security</h1>
        <div className="flex border border-abr-border rounded-lg overflow-hidden text-xs ml-2">
          {[['users','Users'],['profile','My Profile']].map(([v,l]) => (
            <button key={v} onClick={() => setTab(v)} className={`px-3 py-1.5 transition-colors ${tab===v ? 'bg-abr-accent/15 text-abr-accent' : 'bg-abr-surface text-abr-sub hover:text-abr-text'}`}>{l}</button>
          ))}
        </div>
        {tab === 'users' && isAdmin && (
          <button onClick={() => setShowAdd(true)} className="ml-auto flex items-center gap-1.5 px-3 py-1.5 text-xs rounded-lg bg-abr-accent text-white hover:bg-blue-400 transition-all">
            <Plus size={12} /> Add User
          </button>
        )}
      </div>

      {/* Content */}
      <div className="flex-1 overflow-y-auto p-6">
        {tab === 'users' && (
          <div className="bg-abr-surface border border-abr-border rounded-xl overflow-hidden">
            <table className="w-full">
              <thead><tr className="border-b border-abr-border">
                {['Username','Role','2FA','Created',''].map(h => <th key={h} className="text-left px-4 py-3 text-xs font-medium text-abr-sub uppercase tracking-wider">{h}</th>)}
              </tr></thead>
              <tbody className="divide-y divide-abr-border">
                {loading && <tr><td colSpan={5} className="px-4 py-8 text-center text-abr-sub text-sm"><RefreshCw size={14} className="animate-spin inline mr-2" />Loading…</td></tr>}
                {!loading && error && <tr><td colSpan={5} className="px-4 py-6 text-center"><p className="text-xs text-abr-danger">{error}</p><button onClick={load} className="mt-2 text-xs text-abr-accent">Retry</button></td></tr>}
                {!loading && !error && users.length === 0 && <tr><td colSpan={5} className="px-4 py-8 text-center text-abr-sub text-xs">No users found</td></tr>}
                {!loading && !error && users.map(u => (
                  <tr key={u.username} className="hover:bg-abr-muted/30 transition-colors">
                    <td className="px-4 py-3"><div className="flex items-center gap-2"><span className="text-sm text-abr-text font-mono">{u.username}</span>{u.mustChange && <span className="text-xs bg-abr-warn/10 text-abr-warn border border-abr-warn/20 px-1.5 py-0.5 rounded">must change pw</span>}</div></td>
                    <td className="px-4 py-3"><span className={`text-xs px-2 py-0.5 rounded-full border ${u.role==='admin'?'text-purple-400 bg-purple-400/10 border-purple-400/20':'text-abr-sub bg-abr-muted border-abr-border'}`}>{u.role}</span></td>
                    <td className="px-4 py-3">{u.totpEnabled ? <span className="flex items-center gap-1 text-xs text-abr-success"><Shield size={12}/>On</span> : <span className="flex items-center gap-1 text-xs text-abr-sub"><ShieldOff size={12}/>Off</span>}</td>
                    <td className="px-4 py-3 text-xs text-abr-sub font-mono">{u.createdAt ? new Date(u.createdAt).toLocaleDateString('en-GB') : '—'}</td>
                    <td className="px-4 py-3">{isAdmin && u.username !== me?.username && <button onClick={() => deleteUser(u.username)} className="p-1.5 text-abr-sub hover:text-abr-danger border border-abr-border hover:border-abr-danger/40 rounded-lg transition-all"><Trash2 size={12}/></button>}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {tab === 'profile' && me && (
          <div className="space-y-4 max-w-md">
            <div className="bg-abr-surface border border-abr-border rounded-xl p-5">
              <h3 className="text-xs font-semibold text-abr-sub uppercase tracking-widest mb-3">Account</h3>
              {[['Username', me.username],['Role', me.role],['2FA', me.totpEnabled ? 'Enabled ✓' : 'Disabled']].map(([l,v]) => (
                <div key={l} className="flex justify-between py-2 border-b border-abr-border/50 last:border-0">
                  <span className="text-xs text-abr-sub">{l}</span><span className="text-xs text-abr-text font-mono">{v}</span>
                </div>
              ))}
            </div>
            <div className="bg-abr-surface border border-abr-border rounded-xl p-5">
              <h3 className="text-xs font-semibold text-abr-sub uppercase tracking-widest mb-3">Two-Factor Authentication</h3>
              {!me.totpEnabled
                ? <button onClick={setup2fa} className="flex items-center gap-2 px-4 py-2 rounded-lg bg-abr-accent/10 text-abr-accent border border-abr-accent/20 text-xs"><Shield size={13}/>Enable 2FA</button>
                : <div className="space-y-3">
                    <p className="text-xs text-abr-success flex items-center gap-1.5"><CheckCircle size={12}/>2FA is active</p>
                    <div className="flex gap-2">
                      <input type="password" value={disable2faPass} onChange={e => setDisable2faPass(e.target.value)} placeholder="Password to disable" className={inp + ' flex-1 text-xs'} />
                      <button onClick={disable2fa} disabled={!disable2faPass} className="px-3 py-2 text-xs rounded-lg bg-abr-danger/10 text-abr-danger border border-abr-danger/20 disabled:opacity-40"><ShieldOff size={12}/></button>
                    </div>
                    {msg2fa && <p className={`text-xs ${msg2fa.includes('disabled') ? 'text-abr-success' : 'text-abr-danger'}`}>{msg2fa}</p>}
                  </div>
              }
            </div>
            <div className="bg-abr-surface border border-abr-border rounded-xl p-5">
              <h3 className="text-xs font-semibold text-abr-sub uppercase tracking-widest mb-3">Change Password</h3>
              <div className="space-y-3">
                {[['current','Current password'],['next','New password'],['confirm','Confirm new password']].map(([k,l]) => (
                  <div key={k}><label className="block text-xs text-abr-sub mb-1">{l}</label><input className={inp} type="password" value={changePw[k]} onChange={e => setChangePw(p => ({...p, [k]: e.target.value}))} /></div>
                ))}
                {pwError && <p className="text-xs text-abr-danger">{pwError}</p>}
                {pwOk    && <p className="text-xs text-abr-success">Password changed!</p>}
                <button onClick={changePwSubmit} disabled={!changePw.current || changePw.next.length < 12 || changePw.next !== changePw.confirm}
                  className="flex items-center gap-1.5 px-4 py-2 rounded-lg bg-abr-accent text-white text-xs disabled:opacity-40"><Key size={12}/>Change Password</button>
              </div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
