import { h, skeleton, emptyState, cover, badge, stars, formatDuration, requireSignIn } from "../ui.js";
import { listFavorites, getBook } from "../data.js";
import { currentUser } from "../firebase.js";

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

export default async function view() {
  const root = h("div", { class: "stack" });
  root.append(h("div", { class: "section-head" }, h("h1", {}, "My favorites")));

  if (!currentUser()) {
    root.append(emptyState({
      icon: "🔑",
      title: "Sign in to see favorites",
      body: "Save books to find them here.",
      action: {
        label: "Sign in",
        onClick: async () => {
          try {
            await requireSignIn();
            location.reload();
          } catch {
            // user cancelled; stay on the prompt
          }
        },
      },
    }));
    return root;
  }

  const grid = h("div", { class: "grid", "aria-live": "polite" });
  grid.append(skeleton(6));
  root.append(grid);

  try {
    const ids = await listFavorites();
    if (!ids.length) {
      grid.replaceChildren();
      grid.append(emptyState({
        icon: "♥",
        title: "No favorites yet",
        body: "Tap Save on any book to keep it here.",
        action: { label: "Browse books", href: "#/" },
      }));
      return root;
    }
    const results = await Promise.allSettled(ids.map((bookId) => getBook(bookId)));
    const books = results.filter((r) => r.status === "fulfilled").map((r) => r.value);
    grid.replaceChildren();
    if (!books.length) {
      grid.append(emptyState({
        icon: "♥",
        title: "No favorites yet",
        body: "Those saved books are no longer available.",
        action: { label: "Browse books", href: "#/" },
      }));
      return root;
    }
    for (const b of books) grid.append(bookCard(b));
  } catch (e) {
    grid.replaceChildren();
    grid.append(emptyState({
      icon: "♥",
      title: "Could not load favorites",
      body: e.message || "Check your connection and try again.",
      action: { label: "Browse books", href: "#/" },
    }));
  }
  return root;
}
