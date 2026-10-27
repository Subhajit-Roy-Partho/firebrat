import { h, toast, skeleton, emptyState, cover, badge, stars, formatDuration } from "../ui.js";
import { listBooks } from "../data.js";
import { navigate } from "../router.js";

const CATEGORIES = ["fiction", "nonfiction", "science", "history", "poetry", "children", "education", "other"];
const LANGUAGES = ["en", "es", "fr", "de", "hi", "bn", "other"];
const LICENSES = ["public-domain", "cc0", "cc-by", "cc-by-sa"];
const SORTS = [
  ["new", "Newest"],
  ["top", "Top rated"],
  ["long", "Longest"],
];

function bookCard(b) {
  const avg = b.ratingCount ? b.ratingSum / b.ratingCount : 0;
  const license = (b.provenance && b.provenance.license) || b.license || "";
  const meta = `${formatDuration(b.totalDurationMs)} · ${b.sectionCount ?? "?"} sections`;
  return h("article", { class: "card" },
    cover(b),
    h("div", { class: "card-body" },
      h("h3", { class: "card-title" },
        h("a", { class: "card-link", href: "#/book/" + encodeURIComponent(b.id) }, b.title || "Untitled")),
      h("p", { class: "card-author" }, b.author || "Unknown author"),
      h("p", { class: "card-meta muted small" }, meta),
      stars({ value: avg, count: b.ratingCount || 0 }),
      license ? h("div", { class: "card-foot" }, badge(license, "license")) : null));
}

export default async function view(ctx) {
  const root = h("div", { class: "stack" });
  let category = "";
  let language = "";
  let license = "";
  let sort = "new";
  let q = (ctx.query && ctx.query.get("q")) || "";
  let cursor = null;
  let loading = false;

  // ——— hero ———
  const searchInput = h("input", {
    class: "input", type: "search", placeholder: "Search title, author, tag…",
    "aria-label": "Search books", value: q,
  });
  const hero = h("section", { class: "hero" },
    h("div", { class: "hero-inner" },
      h("div", { class: "hero-copy" },
        h("h1", { class: "hero-title" }, "Free, copyright-free audiobooks for everyone"),
        h("p", { class: "hero-sub" },
          "A library of public-domain and openly-licensed audiobooks. Stream in your browser, download for offline listening, or open in the Firebrat app."),
        h("div", { role: "search" }, searchInput),
        h("div", { class: "hero-actions" },
          h("a", { class: "btn btn-primary", href: "#books" }, "Browse books"),
          h("a", { class: "btn btn-ghost", href: "#/submit" }, "Submit a book")),
        h("div", { class: "row" },
          h("div", {},
            h("strong", {}, "🎧 Listen"),
            h("p", { class: "muted small" }, "Stream chapters free, right in your browser.")),
          h("div", {},
            h("strong", {}, "⬇ Download"),
            h("p", { class: "muted small" }, "Grab the package from the Internet Archive.")),
          h("div", {},
            h("strong", {}, "➕ Contribute"),
            h("p", { class: "muted small" }, "Share public-domain or openly-licensed audio."))))));
  root.append(hero);

  // ——— toolbar ———
  const chipsBox = h("div", { class: "chips", role: "group", "aria-label": "Filter by category" });
  const chipBtns = [];
  const allChip = h("button", {
    type: "button", class: "chip", "aria-pressed": "true",
    onclick: () => { category = ""; syncChips(); reload(); },
  }, "All");
  chipsBox.append(allChip);
  chipBtns.push([allChip, ""]);
  for (const c of CATEGORIES) {
    const btn = h("button", {
      type: "button", class: "chip", "aria-pressed": "false",
      onclick: () => { category = c; syncChips(); reload(); },
    }, c);
    chipsBox.append(btn);
    chipBtns.push([btn, c]);
  }
  function syncChips() {
    for (const [btn, val] of chipBtns) {
      btn.setAttribute("aria-pressed", String(val === category));
    }
  }

  const langLabel = h("label", { class: "label", for: "home-lang" }, "Language");
  const langSel = h("select", {
    class: "select", id: "home-lang", "aria-label": "Language",
    onchange: () => { language = langSel.value; reload(); },
  }, h("option", { value: "" }, "All languages"),
    ...LANGUAGES.map((l) => h("option", { value: l }, l)));
  const licLabel = h("label", { class: "label", for: "home-lic" }, "License");
  const licSel = h("select", {
    class: "select", id: "home-lic", "aria-label": "License",
    onchange: () => { license = licSel.value; reload(); },
  }, h("option", { value: "" }, "All licenses"),
    ...LICENSES.map((l) => h("option", { value: l }, l)));
  const sortLabel = h("label", { class: "label", for: "home-sort" }, "Sort");
  const sortSel = h("select", {
    class: "sort-select", id: "home-sort", "aria-label": "Sort books",
    onchange: () => { sort = sortSel.value; reload(); },
  }, ...SORTS.map(([v, label]) => h("option", { value: v, selected: v === "new" }, label)));

  const toolbar = h("div", { class: "toolbar" },
    chipsBox,
    h("div", { class: "field" }, langLabel, langSel),
    h("div", { class: "field" }, licLabel, licSel),
    h("div", { class: "field" }, sortLabel, sortSel));
  const browse = h("section", { class: "section", id: "books" },
    h("div", { class: "section-head" }, h("h2", {}, "Browse books")),
    toolbar);
  root.append(browse);

  // ——— grid + load more ———
  const grid = h("div", { class: "grid", "aria-live": "polite" });
  root.append(grid);
  const moreWrap = h("div", { class: "center" });
  const moreBtn = h("button", { class: "btn btn-ghost", type: "button", onclick: () => reload(false) }, "Load more");
  moreWrap.append(moreBtn);
  root.append(moreWrap);

  function renderItems(items, append) {
    if (!append) grid.replaceChildren();
    for (const b of items) grid.append(bookCard(b));
  }

  async function reload(reset = true) {
    if (loading) return;
    loading = true;
    try {
      if (reset) {
        cursor = null;
        grid.replaceChildren(skeleton(6));
      } else {
        moreBtn.disabled = true;
      }
      const { items, cursor: next } = await listBooks({
        category: category || undefined,
        language: language || undefined,
        license: license || undefined,
        sort,
        search: q,
        after: reset ? null : cursor,
        limit: 24,
      });
      cursor = next;
      renderItems(items, !reset);
      if (!reset && items.length === 0) {
        // nothing new; fall through to hide the button
      }
      if (!grid.children.length) {
        grid.replaceChildren(emptyState({
          icon: "📚",
          title: "No books found",
          body: "Try a different search or submit a book.",
          action: { label: "Submit a book", href: "#/submit" },
        }));
      }
      const hide = !cursor || (reset && items.length < 24);
      moreWrap.style.display = hide ? "none" : "";
    } catch (e) {
      toast(e.message || "Could not load books.", { kind: "err" });
      if (reset) {
        grid.replaceChildren(emptyState({
          icon: "📚",
          title: "Could not load books",
          body: "Check your connection and try again.",
          action: { label: "Submit a book", href: "#/submit" },
        }));
      }
    } finally {
      loading = false;
      moreBtn.disabled = false;
    }
  }

  let debounce = 0;
  searchInput.addEventListener("input", () => {
    q = searchInput.value;
    clearTimeout(debounce);
    debounce = setTimeout(() => reload(true), 400);
  });
  searchInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") {
      e.preventDefault();
      navigate("/?q=" + encodeURIComponent(searchInput.value.trim()));
    }
  });

  reload(true);
  return root;
}
