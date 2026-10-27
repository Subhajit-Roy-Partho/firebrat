import "./style.css";
/* Firebrat Community — app shell + boot.
   Builds header (<main id="outlet">, footer, mini-player), registers
   routes -> dynamic import('./views/<name>.js'), theme toggle, auth
   menu, service-worker registration (https only), router start. */

import { navigate, route, start } from "./router.js";
import { currentUser, isAdmin, onUser, signOut } from "./firebase.js";
import { h } from "./ui.js";
import { requireSignIn } from "./ui.js";
import { mountMiniPlayer } from "./player.js";

const THEME_KEY = "firebrat.theme.v1";

function effectiveTheme() {
  try {
    const saved = localStorage.getItem(THEME_KEY);
    if (saved === "light" || saved === "dark") return saved;
  } catch {}
  return matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function applyTheme(t) {
  document.documentElement.dataset.theme = t;
  const btn = document.getElementById("theme-btn");
  if (btn) {
    btn.textContent = t === "dark" ? "☀" : "☾";
    btn.setAttribute("aria-label", t === "dark" ? "Switch to light theme" : "Switch to dark theme");
  }
}

/* ——— header ——— */
function buildHeader() {
  const header = h("header", { class: "site-header glass" });
  const inner = h("div", { class: "wrap header-inner" });

  const brand = h("a", { class: "brand", href: "#/", "aria-label": "Firebrat Community home" },
    h("span", { class: "logo-mark", "aria-hidden": "true" }, "F"),
    h("span", { class: "logo-word" }, "Firebrat ", h("span", {}, "Community")));

  const nav = h("nav", { class: "main-nav", "aria-label": "Main" },
    h("a", { href: "#/" }, "Home"),
    h("a", { href: "#/favorites" }, "Favorites"),
    h("a", { href: "#/about" }, "About"));

  const search = h("input", {
    class: "input", type: "search", placeholder: "Search title, author, tag…",
    "aria-label": "Search books",
  });
  search.addEventListener("keydown", (e) => {
    if (e.key === "Enter") navigate("/?q=" + encodeURIComponent(search.value.trim()));
  });
  const searchBox = h("div", { class: "searchbar", role: "search" }, search);

  const submitBtn = h("a", { class: "btn btn-primary btn-sm", href: "#/submit" }, "+ Submit");

  const themeBtn = h("button", {
    id: "theme-btn", class: "icon-btn theme-btn",
    "aria-label": "Toggle theme",
    onclick: () => {
      const next = effectiveTheme() === "dark" ? "light" : "dark";
      try { localStorage.setItem(THEME_KEY, next); } catch {}
      applyTheme(next);
    },
  }, "☾");

  // Account menu (sign in / out, favorites, admin link).
  const menuWrap = h("div", { class: "account-wrap" });
  const acctBtn = h("button", {
    class: "icon-btn account-btn", "aria-label": "Account menu",
    "aria-haspopup": "menu", "aria-expanded": "false",
  }, "👤");
  const menu = h("div", { class: "account-menu", role: "menu", hidden: true });
  menuWrap.append(acctBtn, menu);

  acctBtn.onclick = () => {
    const open = menu.hidden;
    menu.hidden = !open;
    acctBtn.setAttribute("aria-expanded", String(open));
  };
  document.addEventListener("click", (e) => {
    if (!menu.hidden && !menuWrap.contains(e.target)) {
      menu.hidden = true;
      acctBtn.setAttribute("aria-expanded", "false");
    }
  });

  async function renderMenu(user) {
    menu.replaceChildren();
    if (!user) {
      menu.append(
        h("div", { class: "menu-head" }, h("div", { class: "small muted" }, "You're browsing as a guest.")),
        h("button", {
          class: "menu-item", role: "menuitem",
          onclick: async () => { menu.hidden = true; try { await requireSignIn(); } catch {} },
        }, "🔑 Sign in"),
      );
      acctBtn.textContent = "👤";
      return;
    }
    acctBtn.textContent = (user.displayName || user.email || "U").trim()[0].toUpperCase();
    menu.append(
      h("div", { class: "menu-head" },
        h("div", {}, user.displayName || "Reader"),
        h("div", { class: "small muted" }, user.email || "")),
      h("a", { class: "menu-item", role: "menuitem", href: "#/favorites" }, "♥ My favorites"),
    );
    try {
      if (await isAdmin()) {
        menu.append(h("a", { class: "menu-item", role: "menuitem", href: "#/admin" }, "🛠 Admin"));
      }
    } catch {}
    menu.append(h("button", {
      class: "menu-item", role: "menuitem",
      onclick: async () => { menu.hidden = true; try { await signOut(); } catch {} },
    }, "⏻ Sign out"));
  }

  onUser((u) => renderMenu(u || currentUser()));
  renderMenu(currentUser());

  inner.append(brand, nav, searchBox, submitBtn, themeBtn, menuWrap);
  header.append(inner);
  return header;
}

/* ——— footer ——— */
function buildFooter() {
  const foot = h("footer", { class: "site-footer" });
  const wrap = h("div", { class: "wrap" });
  const grid = h("div", { class: "foot-grid" });
  const col = (title, links) => h("div", { class: "foot-col" },
    h("h3", {}, title),
    ...links.map(([label, href]) => h("a", { class: "foot-link", href }, label)));

  grid.append(
    col("Explore", [
      ["Home", "#/"],
      ["Submit a book", "#/submit"],
      ["My favorites", "#/favorites"],
      ["About the library", "#/about"],
    ]),
    col("Legal & safety", [
      ["Copyright & takedown", "#/legal/takedown"],
      ["Terms of use", "#/legal/terms"],
      ["Privacy", "#/legal/privacy"],
      ["Report a bug", "#/report-bug"],
    ]),
    col("Project", [
      ["Copyright policy", "#/legal/copyright"],
      ["Open in Firebrat app", "#/about"],
      ["Internet Archive", "https://archive.org/"],
    ]),
  );
  const bottom = h("div", { class: "foot-bottom" },
    h("span", {}, "Firebrat Community — a public-domain audiobook library."),
    h("span", { class: "spacer" }),
    h("span", {}, "Books stream from the Internet Archive. Please respect rights holders."),
  );
  wrap.append(grid, bottom);
  foot.append(wrap);
  return foot;
}

/* ——— routes (one dynamic import per view) ——— */
const view = (name) => async (ctx) => (await import(`./views/${name}.js`)).default(ctx);

route("/", view("home"));
route("/book/:id", view("book"));
route("/submit", view("submit"));
route("/about", view("about"));
route("/legal/:doc", view("legal"));
route("/report-bug", view("report-bug"));
route("/admin", view("admin"));
route("/favorites", view("favorites"));

/* ——— boot ——— */
function boot() {
  document.body.prepend(buildHeader());
  const outlet = h("main", { id: "outlet", class: "wrap page" });
  document.body.append(outlet);
  document.body.append(buildFooter());
  const mp = h("div", { id: "mini-player" });
  document.body.append(mp);
  mountMiniPlayer(mp);

  applyTheme(effectiveTheme());
  start(outlet);

  // Service worker: https only (GitHub Pages), never on plain http dev.
  try {
    if ("serviceWorker" in navigator && location.protocol === "https:") {
      const base = (import.meta.env && import.meta.env.BASE_URL) || "/firebrat/community/";
      const swUrl = base.endsWith("/") ? base + "sw.js" : base + "/sw.js";
      navigator.serviceWorker.register(swUrl).catch(() => {});
    }
  } catch {}
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot, { once: true });
} else {
  boot();
}
