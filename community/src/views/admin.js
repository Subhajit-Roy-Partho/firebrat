/* Firebrat Community — admin view: tabs for takedowns / reports / bugs /
   books with disable-restore, hide-comment, and resolve actions.
   Contract: export default async function view(ctx) -> HTMLElement. */

import { h, toast, emptyState, badge, timeAgo } from "../ui.js";
import { isAdmin, currentUser } from "../firebase.js";
import {
  adminList,
  adminSetBookStatus,
  adminHideComment,
  adminResolve,
} from "../data.js";

const TABS = [
  ["takedowns", "Takedowns"],
  ["reports", "Reports"],
  ["bugs", "Bugs"],
  ["books", "Books"],
];

function val(v) {
  if (v == null) return "—";
  if (typeof v === "object" && typeof v.toDate === "function") return timeAgo(v);
  return String(v);
}

function kv(k, v) {
  return h("div", { class: "prov-row" }, h("dt", {}, k), h("dd", {}, val(v)));
}

function smallBtn(label, onclick, kind = "btn-ghost") {
  return h(
    "button",
    { class: `btn btn-sm ${kind}`, onclick: () => void onclick() },
    label,
  );
}

export default async function view() {
  const root = h("div", { class: "stack" });
  root.append(h("h1", {}, "Admin"));

  let admin = false;
  try {
    admin = currentUser() ? await isAdmin() : false;
  } catch {
    admin = false;
  }
  if (!admin) {
    root.append(
      emptyState({
        icon: "⛔",
        title: "Not authorized",
        body: "This area is for library administrators. If you should have access, make sure you're signed in with the right account.",
        action: { label: "Back home", href: "#/" },
      }),
    );
    return root;
  }

  let tab = "takedowns";
  const tabsEl = h("div", { class: "chips", role: "tablist", "aria-label": "Admin sections" });
  const listEl = h("div", { class: "stack" });
  root.append(tabsEl, listEl);

  function renderTabs() {
    tabsEl.replaceChildren();
    for (const [id, label] of TABS) {
      tabsEl.append(
        h(
          "button",
          {
            class: "chip",
            role: "tab",
            "aria-selected": id === tab ? "true" : "false",
            "aria-pressed": id === tab ? "true" : "false",
            onclick: () => {
              tab = id;
              renderTabs();
              void load();
            },
          },
          label,
        ),
      );
    }
  }

  async function load() {
    listEl.replaceChildren(h("p", { class: "muted" }, "Loading…"));
    try {
      const items = await adminList(tab, {});
      if (!items.length) {
        listEl.replaceChildren(
          emptyState({ icon: "✅", title: "All clear", body: `No ${tab} right now.` }),
        );
        return;
      }
      listEl.replaceChildren();
      for (const item of items) {
        listEl.append(renderItem(item));
      }
    } catch (e) {
      listEl.replaceChildren(
        h("p", { class: "error-text", role: "alert" }, e instanceof Error ? e.message : "Load failed."),
      );
    }
  }

  function renderItem(item) {
    if (tab === "books") return renderBook(item);
    if (tab === "reports") return renderReport(item);
    if (tab === "bugs") return renderBug(item);
    return renderTakedown(item);
  }

  function renderBook(b) {
    const card = h("div", { class: "comment" });
    const head = h(
      "div",
      { class: "comment-head" },
      h("b", {}, b.title || b.id),
      badge(b.status || "published", b.status || "published"),
      h("span", { class: "muted small" }, b.author || ""),
      h("span", { class: "spacer" }),
      h("span", { class: "muted small" }, val(b.createdAt)),
    );
    const actions = h("div", { class: "comment-actions" });
    const act = async (status, label) => {
      try {
        await adminSetBookStatus(b.id, status);
        toast(`Book ${label}.`, { kind: "ok" });
        await load();
      } catch (e) {
        toast(e instanceof Error ? e.message : "Action failed.", { kind: "err" });
      }
    };
    if (b.status === "removed") {
      actions.append(smallBtn("Restore (published)", () => act("published", "restored")));
    } else {
      actions.append(smallBtn("Mark disputed", () => act("disputed", "marked disputed")));
      if (b.status !== "removed") actions.append(smallBtn("Remove", () => act("removed", "removed"), "btn-danger"));
      if (b.status !== "published") actions.append(smallBtn("Restore (published)", () => act("published", "restored")));
    }
    card.append(head, actions);
    return card;
  }

  function renderReport(r) {
    const card = h("div", { class: "comment" });
    card.append(
      h(
        "div",
        { class: "comment-head" },
        h("b", {}, `${r.kind || "report"} · ${r.reason || ""}`),
        r.resolved ? badge("resolved", "") : badge("open", "disputed"),
        h("span", { class: "spacer" }),
        h("span", { class: "muted small" }, val(r.createdAt)),
      ),
      h(
        "dl",
        {},
        kv("Book", r.bookId),
        r.commentId ? kv("Comment", r.commentId) : null,
        kv("Details", r.details),
      ),
    );
    const actions = h("div", { class: "comment-actions" });
    if (r.kind === "comment" && r.bookId && r.commentId) {
      actions.append(
        smallBtn("Hide comment", async () => {
          try {
            await adminHideComment(r.bookId, r.commentId);
            toast("Comment hidden.", { kind: "ok" });
          } catch (e) {
            toast(e instanceof Error ? e.message : "Hide failed.", { kind: "err" });
          }
        }),
      );
    }
    if (!r.resolved) {
      actions.append(
        smallBtn("Mark resolved", async () => {
          try {
            await adminResolve("reports", r.id);
            toast("Resolved.", { kind: "ok" });
            await load();
          } catch (e) {
            toast(e instanceof Error ? e.message : "Resolve failed.", { kind: "err" });
          }
        }),
      );
    }
    card.append(actions);
    return card;
  }

  function renderBug(b) {
    const card = h("div", { class: "comment" });
    card.append(
      h(
        "div",
        { class: "comment-head" },
        h("b", {}, b.kind || "bug"),
        b.status === "open" ? badge("open", "disputed") : badge(String(b.status), ""),
        h("span", { class: "muted small" }, b.bookId ? `book: ${b.bookId}` : (b.page || "")),
        h("span", { class: "spacer" }),
        h("span", { class: "muted small" }, val(b.createdAt)),
      ),
      h("p", { class: "comment-body" }, b.message || ""),
      h("p", { class: "hint small" }, `browser: ${b.userAgent || "—"} · app: ${b.appVersion || "—"}`),
    );
    if (b.status === "open") {
      card.append(
        h(
          "div",
          { class: "comment-actions" },
          smallBtn("Mark resolved", async () => {
            try {
              await adminResolve("bugs", b.id);
              toast("Resolved.", { kind: "ok" });
              await load();
            } catch (e) {
              toast(e instanceof Error ? e.message : "Resolve failed.", { kind: "err" });
            }
          }),
        ),
      );
    }
    return card;
  }

  function renderTakedown(t) {
    const card = h("div", { class: "comment" });
    card.append(
      h(
        "div",
        { class: "comment-head" },
        h("b", {}, t.claimantName || t.id),
        t.status === "open" ? badge("open", "disputed") : badge(String(t.status), ""),
        h("span", { class: "spacer" }),
        h("span", { class: "muted small" }, val(t.createdAt)),
      ),
      h(
        "dl",
        {},
        kv("Book", t.bookId),
        kv("Email", t.claimantEmail),
        kv("Rights holder", t.rightsHolder),
        kv("Work", t.workDescription),
        kv("URLs", t.infringingUrls),
        kv("Signature", t.signature),
      ),
    );
    const actions = h("div", { class: "comment-actions" });
    if (t.bookId) {
      actions.append(
        smallBtn("Set book disputed", async () => {
          try {
            await adminSetBookStatus(t.bookId, "disputed");
            toast("Book marked disputed.", { kind: "ok" });
          } catch (e) {
            toast(e instanceof Error ? e.message : "Action failed.", { kind: "err" });
          }
        }),
      );
    }
    if (t.status === "open") {
      actions.append(
        smallBtn("Mark resolved", async () => {
          try {
            await adminResolve("takedowns", t.id);
            toast("Resolved.", { kind: "ok" });
            await load();
          } catch (e) {
            toast(e instanceof Error ? e.message : "Resolve failed.", { kind: "err" });
          }
        }),
      );
    }
    card.append(actions);
    return card;
  }

  renderTabs();
  await load();
  return root;
}
