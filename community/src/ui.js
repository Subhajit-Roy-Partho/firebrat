/* Firebrat Community — tiny DOM helpers, toast, modal, stars, covers.
   Contract: h, toast, modal, stars, cover, badge, formatDuration,
   formatBytes, timeAgo, skeleton, emptyState, requireSignIn. */

import { currentUser, signInEmail, signInGoogle, signUpEmail } from "./firebase.js";

/** Build an element. props: class, on*, dataset, aria-*, boolean attrs. */
export function h(tag, props, ...children) {
  const el = document.createElement(tag);
  if (props) {
    for (const [k, v] of Object.entries(props)) {
      if (v == null || v === false) continue;
      if (k === "class") el.className = v;
      else if (k === "text") el.textContent = v;
      else if (k === "value") el.value = v;
      else if (k.startsWith("on") && typeof v === "function") {
        el.addEventListener(k.slice(2).toLowerCase(), v);
      } else if (k === "dataset" && typeof v === "object") {
        Object.assign(el.dataset, v);
      } else if (k.startsWith("aria-") || k === "role" || k === "for") {
        el.setAttribute(k === "for" ? "for" : k, String(v));
      } else if (v === true) {
        el.setAttribute(k, "");
      } else {
        el.setAttribute(k, String(v));
      }
    }
  }
  const push = (c) => {
    if (c == null || c === false) return;
    if (Array.isArray(c)) return c.forEach(push);
    el.append(c.nodeType ? c : document.createTextNode(String(c)));
  };
  children.forEach(push);
  return el;
}

function toastsEl() {
  let box = document.getElementById("toasts");
  if (!box) {
    box = h("div", { id: "toasts", "aria-live": "polite" });
    document.body.append(box);
  }
  return box;
}

/** Show a toast. kind: "ok" | "err" | "info". */
export function toast(msg, { kind = "info" } = {}) {
  const box = toastsEl();
  const el = h("div", {
    class: "toast " + (kind === "ok" ? "toast-ok" : kind === "err" ? "toast-err" : "toast-info"),
    role: kind === "err" ? "alert" : "status",
  }, String(msg));
  box.append(el);
  setTimeout(() => {
    el.style.opacity = "0";
    el.style.transition = "opacity 200ms";
    setTimeout(() => el.remove(), 220);
  }, 3600);
  return el;
}

/** Open a modal. actions: [{label, kind:'primary'|'ghost'|'danger', onClick(close)}]. Returns close(). */
export function modal({ title, body, actions = [] }) {
  const prevFocus = document.activeElement;
  const backdrop = h("div", { class: "modal-backdrop" });
  const dlg = h("div", { class: "modal", role: "dialog", "aria-modal": "true", "aria-label": title || "Dialog" });
  const head = h("div", { class: "modal-head" },
    h("h2", {}, title || ""),
    h("button", { class: "icon-btn", "aria-label": "Close dialog", onclick: () => close() }, "✕"));
  const bodyEl = h("div", { class: "modal-body" });
  if (body) {
    if (typeof body === "string") bodyEl.textContent = body;
    else if (Array.isArray(body)) body.forEach((b) => bodyEl.append(b.nodeType ? b : document.createTextNode(String(b))));
    else bodyEl.append(body.nodeType ? body : document.createTextNode(String(body)));
  }
  const foot = h("div", { class: "modal-foot" });
  function close() {
    backdrop.remove();
    document.removeEventListener("keydown", onKey, true);
    if (prevFocus && prevFocus.focus) prevFocus.focus();
  }
  for (const a of actions) {
    foot.append(h("button", {
      class: "btn " + (a.kind === "primary" ? "btn-primary" : a.kind === "danger" ? "btn-danger" : "btn-ghost"),
      onclick: () => (a.onClick ? a.onClick(close) : close()),
    }, a.label));
  }
  const onKey = (e) => { if (e.key === "Escape") close(); };
  document.addEventListener("keydown", onKey, true);
  backdrop.addEventListener("click", (e) => { if (e.target === backdrop) close(); });
  dlg.append(head, bodyEl);
  if (actions.length) dlg.append(foot);
  backdrop.append(dlg);
  document.body.append(backdrop);
  const first = dlg.querySelector("input, textarea, select, button.btn");
  if (first) first.focus();
  return close;
}

/** Star display (and optional interactive rater). value 0..5, count optional. */
export function stars({ value = 0, count = null, editable = false, onRate = null } = {}) {
  const wrap = h("span", { class: "stars", role: editable ? "radiogroup" : "img", "aria-label": `Rated ${value} out of 5${count != null ? ` from ${count} ratings` : ""}` });
  const rounded = Math.round(value);
  for (let i = 1; i <= 5; i++) {
    if (editable) {
      wrap.append(h("button", {
        type: "button",
        class: "star-btn" + (i <= rounded ? " on" : ""),
        "aria-label": `Rate ${i} star${i > 1 ? "s" : ""}`,
        onclick: () => onRate && onRate(i),
      }, "★"));
    } else {
      wrap.append(h("span", { class: "star" + (i <= rounded ? " on" : ""), "aria-hidden": "true" }, "★"));
    }
  }
  if (count != null && !editable) {
    wrap.append(h("span", { class: "muted small" }, ` ${Number(value).toFixed(1)} (${count})`));
  }
  return wrap;
}

const COVERS = [
  ["#4338ca", "#7c3aed"], ["#0f766e", "#4338ca"], ["#b45309", "#7c2d12"],
  ["#1d4ed8", "#0ea5e9"], ["#6d28d9", "#db2777"], ["#047857", "#65a30d"],
  ["#9a3412", "#b45309"], ["#4c1d95", "#1d4ed8"],
];

function hashStr(s) {
  let x = 0;
  for (let i = 0; i < s.length; i++) x = (x * 31 + s.charCodeAt(i)) >>> 0;
  return x;
}

/** Deterministic gradient cover with title initials. */
export function cover(book = {}, { size = "" } = {}) {
  const title = book.title || "Untitled";
  const words = title.trim().split(/\s+/).slice(0, 2);
  const initials = words.map((w) => (w[0] || "").toUpperCase()).join("") || "FB";
  const [a, b] = COVERS[hashStr(title + (book.author || "")) % COVERS.length];
  const el = h("div", {
    class: "cover" + (size === "lg" ? " cover-lg" : size === "mp" ? " mp-cover" : ""),
    style: `background:linear-gradient(135deg, ${a}, ${b})`,
    "aria-hidden": "true",
  }, initials);
  return el;
}

/** Small pill badge. kind: license | cat | status-* (published/disputed/removed). */
export function badge(text, kind = "") {
  const cls = "badge " + (
    kind === "license" ? "b-license"
    : kind === "cat" ? "b-cat"
    : kind === "published" ? "b-published"
    : kind === "disputed" ? "b-disputed"
    : kind === "removed" ? "b-removed"
    : "");
  return h("span", { class: cls }, text);
}

export function formatDuration(ms) {
  if (ms == null || isNaN(ms)) return "—";
  const totalMin = Math.round(ms / 60000);
  if (totalMin < 60) return `${totalMin} min`;
  const hh = Math.floor(totalMin / 60);
  const mm = totalMin % 60;
  return mm ? `${hh}h ${mm}m` : `${hh}h`;
}

export function formatBytes(n) {
  if (n == null || isNaN(n)) return "—";
  if (n < 1024) return `${n} B`;
  const units = ["KB", "MB", "GB"];
  let v = n / 1024;
  let u = 0;
  while (v >= 1024 && u < units.length - 1) { v /= 1024; u++; }
  return `${v >= 100 ? Math.round(v) : v.toFixed(1)} ${units[u]}`;
}

export function timeAgo(ts) {
  try {
    const d = ts && typeof ts.toDate === "function" ? ts.toDate() : new Date(ts);
    const s = Math.max(1, Math.floor((Date.now() - d.getTime()) / 1000));
    if (s < 60) return "just now";
    const m = Math.floor(s / 60);
    if (m < 60) return `${m}m ago`;
    const hh = Math.floor(m / 60);
    if (hh < 24) return `${hh}h ago`;
    const dd = Math.floor(hh / 24);
    if (dd < 30) return `${dd}d ago`;
    const mo = Math.floor(dd / 30);
    if (mo < 12) return `${mo}mo ago`;
    return `${Math.floor(mo / 12)}y ago`;
  } catch {
    return "";
  }
}

/** Skeleton placeholder list (cards). */
export function skeleton(n = 6) {
  const grid = h("div", { class: "grid", "aria-hidden": "true" });
  for (let i = 0; i < n; i++) {
    grid.append(h("div", { class: "skel-card" },
      h("div", { class: "cover shimmer", style: "background:var(--surface-2)" }),
      h("div", { class: "card-body" },
        h("div", { class: "skel shimmer", style: "height:1.1em;width:80%" }),
        h("div", { class: "skel shimmer", style: "height:.9em;width:55%" }))));
  }
  return grid;
}

/** Empty state with a clear next action. action: {label, href|onClick}. */
export function emptyState({ icon = "📚", title = "Nothing here yet", body = "", action = null } = {}) {
  const box = h("div", { class: "empty" },
    h("div", { class: "empty-icon", "aria-hidden": "true" }, icon),
    h("h3", {}, title),
    body ? h("p", { class: "muted" }, body) : null);
  if (action) {
    const btn = action.href
      ? h("a", { class: "btn btn-primary", href: action.href }, action.label)
      : h("button", { class: "btn btn-primary", onclick: action.onClick }, action.label);
    box.append(btn);
  }
  return box;
}

/** Resolve with the signed-in user, opening a sign-in modal first if needed. */
export function requireSignIn() {
  const u = currentUser();
  if (u) return Promise.resolve(u);
  return new Promise((resolve, reject) => {
    const email = h("input", { class: "input", type: "email", placeholder: "you@example.org", autocomplete: "email", "aria-label": "Email" });
    const pw = h("input", { class: "input", type: "password", placeholder: "Password", autocomplete: "current-password", "aria-label": "Password" });
    const name = h("input", { class: "input", type: "text", placeholder: "Display name (for new accounts)", autocomplete: "nickname", "aria-label": "Display name" });
    const err = h("p", { class: "error-text", role: "alert" });
    const close = modal({
      title: "Sign in",
      body: [err, email, pw, name, h("p", { class: "hint" }, "New here? Fill all three fields and choose Create account.")],
      actions: [
        { label: "Cancel", kind: "ghost", onClick: (c) => { c(); reject(new Error("Sign-in cancelled")); } },
        {
          label: "Create account", kind: "ghost",
          onClick: async () => {
            err.textContent = "";
            try {
              const u2 = await signUpEmail(email.value.trim(), pw.value, name.value.trim() || "Reader");
              close(); resolve(u2);
            } catch (e) { err.textContent = e.message || "Could not create account."; }
          },
        },
        {
          label: "Sign in", kind: "primary",
          onClick: async () => {
            err.textContent = "";
            try {
              const u2 = await signInEmail(email.value.trim(), pw.value);
              close(); resolve(u2);
            } catch (e) { err.textContent = e.message || "Could not sign in."; }
          },
        },
      ],
    });
    const gBtn = h("button", {
      class: "btn btn-ghost btn-block",
      onclick: async () => {
        err.textContent = "";
        try { const u2 = await signInGoogle(); close(); resolve(u2); }
        catch (e) { err.textContent = e.message || "Google sign-in failed."; }
      },
    }, "Continue with Google");
    document.querySelector(".modal-body")?.append(gBtn);
  });
}
