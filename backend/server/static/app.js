// Firebrat server web UI — vanilla JS, no build step. Talks only to this
// same origin (same scheme/host/port), so no CORS configuration is needed.
let idToken = null;

async function authedFetch(path, opts = {}) {
  const headers = Object.assign({}, opts.headers || {});
  if (idToken) headers['Authorization'] = 'Bearer ' + idToken;
  const res = await fetch(path, Object.assign({}, opts, { headers }));
  if (!res.ok) {
    const text = await res.text().catch(() => res.statusText);
    throw new Error(res.status + ' ' + text.slice(0, 200));
  }
  const ct = res.headers.get('content-type') || '';
  return ct.includes('json') ? res.json() : res.text();
}

// ── Auth (Google via Firebase compat SDK; optional — reads stay open) ──
async function initAuth() {
  const whoami = document.getElementById('whoami');
  const signin = document.getElementById('signin');
  const signout = document.getElementById('signout');
  try {
    const cfg = await (await fetch('/firebase-config')).json();
    firebase.initializeApp(cfg);
    firebase.auth().onAuthStateChanged(async (user) => {
      if (user) {
        idToken = await user.getIdToken();
        whoami.textContent = 'Signed in as ' + (user.email || user.uid);
        signin.hidden = true;
        signout.hidden = false;
      } else {
        idToken = null;
        whoami.textContent = 'Not signed in (reads work; uploads need sign-in)';
        signin.hidden = false;
        signout.hidden = true;
      }
      loadJobs();
    });
    signin.onclick = () => {
      firebase.auth().signInWithPopup(new firebase.auth.GoogleAuthProvider())
        .catch((e) => alert('Sign-in failed: ' + e.message));
    };
    signout.onclick = () => firebase.auth().signOut();
  } catch (e) {
    whoami.textContent = 'Auth unavailable (' + e.message + ') — reads still work.';
    signin.hidden = true;
  }
}

// ── Health / settings ──
async function loadHealth() {
  try {
    await authedFetch('/health');
    document.getElementById('health').textContent = 'server reachable';
  } catch (e) {
    document.getElementById('health').textContent = 'server unreachable: ' + e.message;
  }
}

async function loadSettings() {
  const el = document.getElementById('settings');
  try {
    const s = await authedFetch('/settings');
    const presets = Object.entries(s.presets || {})
      .map(([k, v]) => `<option value="${k}"${k === s.local_model_preset ? ' selected' : ''}>${v.display}</option>`)
      .join('');
    const gpu = (s.gpu && s.gpu.present) ? s.gpu.gpus.join('; ') : 'none detected';
    el.innerHTML =
      `<p class="muted">GPU: ${gpu} · workers: ${s.max_concurrent_jobs} · auth: ${s.auth || ''}</p>` +
      `<form id="settingsform"><label>Local model preset <select id="preset">${presets}</select></label>` +
      `<label>Default provider <select id="defprov">` +
      `<option value="nanogpt"${s.default_provider === 'nanogpt' ? ' selected' : ''}>nano-gpt (cloud)</option>` +
      `<option value="local"${s.default_provider === 'local' ? ' selected' : ''}>local GPU model</option>` +
      `</select></label>` +
      `<label>Default chunk pages (0 = 10) <input type="number" id="defchunk" min="0" value="${s.default_chunk_pages || 0}"></label>` +
      `<button type="submit">Save (takes effect for new uploads; new weights need an LLM restart)</button></form>` +
      `<div id="settingsmsg" class="muted"></div>`;
    document.getElementById('settingsform').onsubmit = async (e) => {
      e.preventDefault();
      const msg = document.getElementById('settingsmsg');
      try {
        await authedFetch('/settings', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({
            local_model_preset: document.getElementById('preset').value,
            default_provider: document.getElementById('defprov').value,
            default_chunk_pages: parseInt(document.getElementById('defchunk').value || '0', 10),
          }),
        });
        msg.textContent = 'saved.';
      } catch (err) {
        msg.textContent = 'save failed (sign in first?): ' + err.message;
      }
    };
  } catch (e) {
    el.innerHTML = `<p class="muted">settings unavailable: ${e.message}</p>`;
  }
}

// ── Upload (parallel-safe: the server queues; workers run N at once) ──
document.getElementById('upload').addEventListener('submit', async (e) => {
  e.preventDefault();
  const msg = document.getElementById('uploadmsg');
  const file = document.getElementById('pdf').files[0];
  if (!file) { msg.textContent = 'pick a PDF first.'; return; }
  const fd = new FormData();
  fd.append('file', file);
  fd.append('title', document.getElementById('title').value);
  fd.append('provider', document.getElementById('provider').value);
  fd.append('chunk_pages', document.getElementById('chunk_pages').value || '0');
  msg.textContent = 'uploading ' + file.name + ' …';
  try {
    const headers = {};
    if (idToken) headers['Authorization'] = 'Bearer ' + idToken;
    const res = await fetch('/books/upload', { method: 'POST', headers, body: fd });
    if (!res.ok) throw new Error(res.status + ' ' + (await res.text()).slice(0, 200));
    const job = await res.json();
    msg.textContent = 'queued as ' + job.job_id + ' — watch it below.';
    loadJobs();
  } catch (err) {
    msg.textContent = 'upload failed (sign in first?): ' + err.message;
  }
});

// ── Jobs (poll; several can convert at once up to worker count) ──
async function loadJobs() {
  const tbody = document.querySelector('#jobs tbody');
  try {
    const jobs = await authedFetch('/jobs');
    tbody.innerHTML = jobs.length ? '' : '<tr><td colspan="5" class="muted">no jobs (sign in to see the queue)</td></tr>';
    for (const j of jobs) {
      const tr = document.createElement('tr');
      const stage = j.stage ? `${j.stage} ${j.progress != null ? Math.round(j.progress * 100) + '%' : ''}` : '—';
      tr.innerHTML =
        `<td>${j.title || j.book_id}</td><td>${j.state}</td><td>${stage}</td>` +
        `<td>${j.provider || 'nanogpt'}</td><td></td>`;
      const td = tr.lastChild;
      for (const [label, path] of [['Retry', 'retry'], ['Resume', 'resume']]) {
        const b = document.createElement('button');
        b.textContent = label;
        b.onclick = async () => {
          try {
            await authedFetch(`/jobs/${j.job_id}/${path}`, { method: 'POST' });
            loadJobs();
          } catch (err) { alert(label + ' failed: ' + err.message); }
        };
        td.appendChild(b);
        td.appendChild(document.createTextNode(' '));
      }
      tbody.appendChild(tr);
    }
  } catch (e) {
    tbody.innerHTML = `<tr><td colspan="5" class="muted">job queue needs sign-in (${e.message})</td></tr>`;
  }
}

// ── Books (open shelf) ──
async function loadBooks() {
  const el = document.getElementById('books');
  try {
    const books = await authedFetch('/books');
    el.innerHTML = books.length ? '' : '<p class="muted">no books yet — convert one above.</p>';
    for (const b of books) {
      const div = document.createElement('div');
      div.className = 'book';
      div.innerHTML =
        `<div class="row"><strong>${b.title || b.book_id}</strong>` +
        `<span class="muted">${b.section_count || 0} sections</span>` +
        `<a href="/books/${b.book_id}/download">download .zip</a> ` +
        `<button>delete</button></div>`;
      div.querySelector('button').onclick = async () => {
        if (!confirm('Delete ' + b.book_id + ' from the server? Irreversible.')) return;
        try {
          await authedFetch('/books/' + b.book_id, { method: 'DELETE' });
          loadBooks();
        } catch (err) { alert('delete failed (sign in first?): ' + err.message); }
      };
      el.appendChild(div);
    }
  } catch (e) {
    el.innerHTML = `<p class="muted">could not list books: ${e.message}</p>`;
  }
}

initAuth();
loadHealth();
loadSettings();
loadBooks();
loadJobs();
setInterval(loadJobs, 5000);
setInterval(loadBooks, 30000);
