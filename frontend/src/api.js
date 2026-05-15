// Central API helper — always injects auth token
export function apiFetch(url, opts = {}) {
  const token = localStorage.getItem('abr_token');
  return fetch(url, {
    ...opts,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { 'Authorization': `Bearer ${token}` } : {}),
      ...(opts.headers || {}),
    },
  });
}
