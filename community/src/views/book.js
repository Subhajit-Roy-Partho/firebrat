import { h, toast, modal, stars, cover, badge, formatDuration, timeAgo, emptyState, skeleton, requireSignIn } from "../ui.js";
import { getBook, getMyRating, rateBook, listComments, addComment, deleteComment, reportItem, reportBug, toggleFavorite, listFavorites, listBooks } from "../data.js";
import { authorKey, avgRating, compareEditions, workKey } from "../works.js";
import { downloadUrl } from "../ia.js";
import { playBook, onChange, locFromBook } from "../player.js";
import { currentUser } from "../firebase.js";

const COMMENT_REASONS = ["offensive", "spam", "harassment", "misleading", "other"];
const BUG_KINDS = ["bug", "error", "feedback"];

function openReportModal({ kind, bookId, commentId }) {
  const reasonSel = h("select", { class: "select", "aria-label": "Reason" },
    ...COMMENT_REASONS.map((r) => h("option", { value: r }, r)));
  const details = h("textarea", { class: "textarea", "aria-label": "Details (optional)", placeholder: "Details (optional)" });
  const body = h("div", { class: "stack" },
    h("label", { class: "label" }, kind === "book" ? "Report this book" : "Report this comment",
      reasonSel),
    h("label", { class: "label" }, "Details", details));
  modal({
    title: kind === "book" ? "Report this book" : "Report comment",
    body,
    actions: [
      { label: "Cancel", kind: "ghost" },
      {
        label: "Submit report", kind: "primary",
        onClick: async (close) => {
          try {
            await requireSignIn();
            await reportItem({ kind, bookId, commentId, reason: reasonSel.value, details: details.value });
            toast("Thanks — your report was recorded.", { kind: "ok" });
            close();
          } catch (e) {
            toast(e.message || "Could not submit report.", { kind: "err" });
          }
        },
      },
    ],
  });
}

function openBugModal(bookId) {
  const kindSel = h("select", { class: "select", "aria-label": "Issue type" },
    ...BUG_KINDS.map((k) => h("option", { value: k }, k)));
  const msg = h("textarea", { class: "textarea", "aria-label": "Describe the problem", placeholder: "Describe the problem" });
  const body = h("div", { class: "stack" },
    h("label", { class: "label" }, "Issue type", kindSel),
    h("label", { class: "label" }, "Message", msg));
  modal({
    title: "Report a problem with this book",
    body,
    actions: [
      { label: "Cancel", kind: "ghost" },
      {
        label: "Send", kind: "primary",
        onClick: async (close) => {
          try {
            await requireSignIn();
            await reportBug({ kind: kindSel.value, bookId, page: location.hash, message: msg.value });
            toast("Thanks — your report was recorded.", { kind: "ok" });
            close();
          } catch (e) {
            toast(e.message || "Could not send report.", { kind: "err" });
          }
        },
      },
    ],
  });
}

export default async function view(ctx) {
  const id = ctx.params.id;
  const root = h("div", { class: "stack" });

  let book;
  try {
    book = await getBook(id);
  } catch (e) {
    root.append(emptyState({
      icon: "🔎",
      title: "Book not found",
      body: "This book may have been removed.",
      action: { label: "Home", href: "#/" },
    }));
    return root;
  }

  const avg = book.ratingCount ? book.ratingSum / book.ratingCount : 0;
  let myRating = null;
  if (currentUser()) {
    try {
      myRating = await getMyRating(id);
    } catch {
      myRating = null;
    }
  }

  // Chapters come from the book doc — never fetched cross-origin.
  // Older docs may predate the chapters field; those simply show no player.
  const chapters = Array.isArray(book.chapters) ? book.chapters : [];
  let loc = null;
  try {
    if (!book.archiveId) throw new Error("No archive copy linked yet.");
    loc = locFromBook(book);
  } catch {
    loc = null;
  }
  const playable = !!(book.archiveId && loc && chapters.length);

  // ——— disputed banner ———
  if (book.status === "disputed") {
    root.append(h("div", { class: "section" },
      badge("Under review", "disputed"),
      h("p", { class: "muted small" }, "This book is under review following a copyright notice.")));
  }

  // ——— hero ———
  const starBox = h("span", {});
  function paintStars(value) {
    const user = currentUser();
    starBox.replaceChildren(stars({
      value,
      count: book.ratingCount || 0,
      editable: !!user,
      onRate: async (v) => {
        try {
          await requireSignIn();
          const prev = myRating;
          await rateBook(id, v);
          myRating = v;
          if (prev == null) book.ratingCount = (book.ratingCount || 0) + 1;
          book.ratingSum = (book.ratingSum || 0) + v - (prev || 0);
          toast("Thanks for rating.", { kind: "ok" });
          paintStars(v);
        } catch (e) {
          toast(e.message || "Could not save rating.", { kind: "err" });
        }
      },
    }));
  }
  paintStars(myRating ?? avg);

  let saved = false;
  try {
    if (currentUser()) saved = (await listFavorites()).includes(id);
  } catch {
    saved = false;
  }
  const favBtn = h("button", {
    class: "btn btn-ghost btn-sm", type: "button",
    "aria-pressed": String(saved), "aria-label": "Save to favorites",
  }, saved ? "♥ Saved" : "♡ Save");
  favBtn.addEventListener("click", async () => {
    try {
      await requireSignIn();
      const now = await toggleFavorite(id);
      saved = now;
      favBtn.textContent = now ? "♥ Saved" : "♡ Save";
      favBtn.setAttribute("aria-pressed", String(now));
      toast(now ? "Saved to favorites." : "Removed from favorites.", { kind: "ok" });
    } catch (e) {
      toast(e.message || "Could not update favorites.", { kind: "err" });
    }
  });

  const license = (book.provenance && book.provenance.license) || book.license || "";
  const statusKind = book.status === "published" ? "published" : book.status === "disputed" ? "disputed" : "removed";
  const heroEl = h("div", { class: "book-hero" },
    h("div", { class: "book-cover-col" }, cover(book, { size: "lg" })),
    h("div", { class: "book-info" },
      h("h1", {}, book.title || "Untitled"),
      h("p", { class: "muted" }, book.author || "Unknown author"),
      h("p", { class: "muted small" }, book.submitterName ? `Submitted by ${book.submitterName}` : "Submitted by a community member"),
      h("div", { class: "row" }, starBox, favBtn),
      h("div", { class: "row" },
        license ? badge(license, "license") : null,
        book.category ? badge(book.category, "cat") : null,
        book.status ? badge(book.status, statusKind) : null),
      book.description ? h("p", {}, book.description) : null,
      h("p", { class: "muted small" },
        `${formatDuration(book.totalDurationMs)} · ${book.sectionCount ?? chapters.length ?? "?"} sections · ${book.language || "—"}`)));
  root.append(heroEl);

  // ——— other versions of this book + more by the author (same grouping rule as the home page) ———
  const relatedBox = h("div", { class: "stack" });
  root.append(relatedBox);
  void (async () => {
    try {
      const { items } = await listBooks({ sort: "new", limit: 100 });
      const mine = workKey(book);
      const others = items.filter((b) => b.id !== id);
      const versions = mine ? others.filter((b) => workKey(b) === mine).sort(compareEditions) : [];
      const ak = authorKey(book.author);
      const more = ak ? others.filter((b) => authorKey(b.author) === ak && workKey(b) !== mine).sort(compareEditions) : [];
      const row = (b) => h("li", { class: "edition" },
        h("a", { class: "edition-link", href: "#/book/" + encodeURIComponent(b.id) },
          h("span", { class: "edition-main" },
            h("span", { class: "edition-who" }, b.title || "Untitled"),
            h("span", { class: "muted small" },
              (b.submitterName ? `Submitted by ${b.submitterName}` : "Submitted by a community member") +
              ` · ${formatDuration(b.totalDurationMs)}`)),
          h("span", { class: "edition-side" }, stars({ value: avgRating(b), count: b.ratingCount || 0 }))));
      if (versions.length) {
        relatedBox.append(h("section", { class: "section" },
          h("div", { class: "section-head" }, h("h2", {}, "Other versions of this book")),
          h("ul", { class: "editions" }, ...versions.map(row))));
      }
      if (more.length) {
        relatedBox.append(h("section", { class: "section" },
          h("div", { class: "section-head" }, h("h2", {}, `More by ${book.author}`)),
          h("ul", { class: "editions" }, ...more.slice(0, 8).map(row))));
      }
    } catch { /* related lists are optional */ }
  })();

  // ——— provenance ———
  const prov = book.provenance || {};
  const models = Array.isArray(prov.models) ? prov.models.filter(Boolean).join(", ") : "";
  function provRow(label, value) {
    return h("div", { class: "prov-row" },
      h("strong", {}, label + ": "),
      h("span", {}, value || "—"));
  }
  const provCard = h("section", { class: "prov-card" },
    h("h2", {}, "How this audio was made"),
    provRow("Generation", prov.generation),
    provRow("Engine", prov.narrationEngine),
    provRow("Models", models),
    provRow("Notes", prov.pipelineNotes),
    prov.sourceUrl
      ? h("div", { class: "prov-row" }, h("strong", {}, "Source work: "),
        h("a", { href: prov.sourceUrl, target: "_blank", rel: "noopener" }, prov.sourceTitle || prov.sourceUrl))
      : provRow("Source work", prov.sourceTitle),
    prov.licenseUrl
      ? h("div", { class: "prov-row" }, h("strong", {}, "License: "),
        h("a", { href: prov.licenseUrl, target: "_blank", rel: "noopener" }, prov.license || "—"))
      : provRow("License", prov.license),
    h("div", { class: "prov-row" }, h("span", { class: "muted small" }, "Submitter attested no copyright issue.")));
  root.append(provCard);

  // ——— actions ———
  const actions = h("div", { class: "row" });
  if (playable) {
    try {
      actions.append(h("a", {
        class: "btn btn-primary", href: downloadUrl(book.archiveId, loc),
        download: "", target: "_blank", rel: "noopener",
      }, book.packageKind === "folder" ? "Download (full item)" : "Download"));
    } catch {
      actions.append(h("p", { class: "muted small" }, "Audio preview unavailable."));
    }
  } else {
    actions.append(h("p", { class: "muted small" },
      "Audio preview unavailable." +
      (!chapters.length ? " This listing has no chapter list yet." : "")));
  }
  actions.append(h("a", { class: "btn btn-ghost", href: `firebrat://community/book/${encodeURIComponent(id)}` }, "Open in Firebrat app"));
  actions.append(h("button", {
    class: "btn btn-ghost", type: "button",
    onclick: async () => {
      const url = location.origin + location.pathname + "#/book/" + encodeURIComponent(id);
      try {
        if (navigator.share) await navigator.share({ title: book.title, url });
        else { await navigator.clipboard.writeText(url); toast("Link copied", { kind: "ok" }); }
      } catch { /* user dismissed the share sheet */ }
    },
  }, "Share"));
  actions.append(h("span", { class: "muted small" }, "or ",
    h("a", { href: "#/book/" + encodeURIComponent(id) }, "open this page")));
  if (book.archiveId) {
    actions.append(h("a", {
      class: "btn btn-ghost", target: "_blank", rel: "noopener",
      href: "https://archive.org/details/" + encodeURIComponent(book.archiveId),
    }, "View on Internet Archive"));
  }
  root.append(actions);

  // ——— chapters ———
  const chapSection = h("section", { class: "section" },
    h("div", { class: "section-head" }, h("h2", {}, "Chapters")));
  if (chapters.length) {
    const list = h("ol", { class: "chapter-list", "aria-live": "polite" });
    const items = [];
    chapters.forEach((c, i) => {
      const li = h("li", { class: "chapter" });
      const btn = h("button", {
        class: "chapter-play", type: "button",
        "aria-label": `Play chapter ${i + 1}: ${c.title || `Chapter ${i + 1}`}`,
        onclick: () => {
          try {
            playBook(book, i);
          } catch (e) {
            toast(e.message || "Could not play.", { kind: "err" });
          }
        },
      },
        h("span", { class: "chapter-num" }, String(i + 1)),
        h("span", { class: "chapter-title" }, c.title || `Chapter ${i + 1}`),
        h("span", { class: "chapter-dur" }, formatDuration(c.durationMs)));
      li.append(btn);
      list.append(li);
      items.push(li);
    });
    try {
      onChange((snap) => {
        items.forEach((li, i) => {
          const active = snap && snap.book && snap.book.id === id && snap.sectionIndex === i;
          li.className = active ? "chapter is-active" : "chapter";
        });
      });
    } catch {}
    chapSection.append(list);
  } else {
    chapSection.append(h("p", { class: "muted small" }, "Audio preview unavailable."));
  }
  root.append(chapSection);

  // ——— comments ———
  const commentsSection = h("section", { class: "section" },
    h("div", { class: "section-head" }, h("h2", {}, "Comments")));
  const commentList = h("div", { class: "stack", "aria-live": "polite" });
  commentsSection.append(commentList);

  function renderComment(c) {
    const el = h("div", { class: "comment" },
      h("div", { class: "comment-head" },
        h("strong", {}, c.name || "Reader"),
        h("span", { class: "muted small" }, " · " + timeAgo(c.createdAt))),
      h("p", { class: "comment-body" }, c.text || ""));
    const acts = h("div", { class: "comment-actions" });
    const me = currentUser();
    if (me && c.uid && c.uid === me.uid) {
      acts.append(h("button", {
        class: "btn btn-ghost btn-sm", type: "button",
        onclick: async () => {
          try {
            await deleteComment(id, c.id);
            toast("Comment deleted.", { kind: "ok" });
            el.remove();
          } catch (e) {
            toast(e.message || "Could not delete comment.", { kind: "err" });
          }
        },
      }, "Delete"));
    }
    acts.append(h("button", {
      class: "btn btn-ghost btn-sm", type: "button",
      onclick: () => openReportModal({ kind: "comment", bookId: id, commentId: c.id }),
    }, "Report"));
    el.append(acts);
    return el;
  }

  async function loadComments() {
    commentList.replaceChildren(skeleton(2));
    try {
      const { items } = await listComments(id, { limit: 20 });
      commentList.replaceChildren();
      if (!items.length) {
        commentList.append(h("p", { class: "muted small" }, "No comments yet. Be the first to share your thoughts."));
      }
      for (const c of items) commentList.append(renderComment(c));
    } catch (e) {
      commentList.replaceChildren();
      commentList.append(h("p", { class: "muted small" }, "Comments unavailable: " + (e.message || "error")));
    }
  }

  const commentBox = h("textarea", {
    class: "textarea", id: "book-comment", "aria-label": "Write a comment", placeholder: "Share your thoughts…",
  });
  const commentForm = h("div", { class: "comment-form" },
    h("label", { class: "label", for: "book-comment" }, "Add a comment"),
    commentBox,
    h("button", {
      class: "btn btn-primary", type: "button",
      onclick: async () => {
        try {
          await requireSignIn();
          const text = commentBox.value.trim();
          await addComment(id, text);
          commentBox.value = "";
          toast("Comment posted.", { kind: "ok" });
          await loadComments();
        } catch (e) {
          toast(e.message || "Could not post comment.", { kind: "err" });
        }
      },
    }, "Post comment"));
  commentsSection.append(commentForm);
  root.append(commentsSection);
  loadComments();

  // ——— footer links ———
  const foot = h("div", { class: "row" },
    h("button", {
      class: "btn btn-ghost btn-sm", type: "button",
      onclick: async () => {
        try {
          await requireSignIn();
        } catch (e) {
          toast(e.message || "You need to sign in.", { kind: "err" });
          return;
        }
        openBugModal(id);
      },
    }, "Report a problem with this book"),
    h("a", { class: "btn btn-ghost btn-sm", href: "#/legal/takedown?book=" + encodeURIComponent(id) }, "Copyright concern / takedown"),
    h("button", {
      class: "btn btn-ghost btn-sm", type: "button",
      onclick: async () => {
        try {
          await requireSignIn();
        } catch (e) {
          toast(e.message || "You need to sign in.", { kind: "err" });
          return;
        }
        openReportModal({ kind: "book", bookId: id });
      },
    }, "Report this book"));
  root.append(foot);

  return root;
}
