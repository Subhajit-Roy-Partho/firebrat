/* Firebrat Community — report-a-bug view: kind + optional book + message.
   Page and user-agent are captured automatically by data.reportBug.
   Contract: export default async function view(ctx) -> HTMLElement. */

import { h, toast, emptyState, requireSignIn } from "../ui.js";
import { reportBug } from "../data.js";
import { navigate } from "../router.js";

const KINDS = ["bug", "error", "feedback"];

function field(labelText, input, hintText = "") {
  return h(
    "div",
    { class: "field" },
    h("label", { class: "label" }, labelText, input),
    hintText ? h("p", { class: "hint" }, hintText) : null,
  );
}

export default async function view(ctx) {
  const root = h("div", { class: "stack" });
  root.append(h("h1", {}, "Report a bug"));

  let user = null;
  try {
    user = await requireSignIn();
  } catch {
    user = null;
  }
  if (!user) {
    root.append(
      emptyState({
        icon: "🔑",
        title: "Sign in to report",
        body: "Reports are linked to your account so we can follow up if needed.",
        action: { label: "Back home", href: "#/" },
      }),
    );
    return root;
  }

  const prefillBook = (ctx.query && ctx.query.get("book")) || "";
  const kindS = h(
    "select",
    { class: "select", "aria-label": "Report kind" },
    ...KINDS.map((k) => h("option", { value: k }, k)),
  );
  const bookI = h("input", {
    class: "input",
    type: "text",
    value: prefillBook,
    placeholder: "optional",
    "aria-label": "Book id",
  });
  const msgI = h("textarea", {
    class: "textarea",
    value: "",
    placeholder: "What happened? What did you expect?",
    "aria-label": "Message",
  });
  const err = h("p", { class: "error-text hidden", role: "alert" });

  const page = (typeof location !== "undefined" && (location.hash || location.pathname)) || "";
  const ua = (typeof navigator !== "undefined" && navigator.userAgent) || "";

  const sendBtn = h("button", { class: "btn btn-primary", type: "submit" }, "Send report");
  const form = h(
    "form",
    {
      class: "stack",
      onsubmit: (e) => {
        e.preventDefault();
        void send();
      },
    },
    field("Kind", kindS, "Bug: something is broken. Error: you saw an error message. Feedback: anything else."),
    field("Book id (optional)", bookI, "If this is about a specific book, paste its id."),
    field("Message", msgI, "Up to 3000 characters. Steps to reproduce help a lot."),
    h(
      "p",
      { class: "hint" },
      "Your report automatically includes this page (“",
      page,
      "”) and your browser (“",
      ua.slice(0, 80),
      "”) so we can reproduce the problem.",
    ),
    err,
    h("div", { class: "row" }, sendBtn),
  );
  root.append(form);

  async function send() {
    err.textContent = "";
    err.classList.add("hidden");
    const message = msgI.value.trim();
    if (!message) {
      err.textContent = "Please describe the problem first.";
      err.classList.remove("hidden");
      return;
    }
    sendBtn.disabled = true;
    try {
      await reportBug({
        kind: kindS.value,
        bookId: bookI.value.trim(),
        page,
        message,
      });
      toast("Thanks — report sent.", { kind: "ok" });
      navigate("/");
    } catch (e) {
      sendBtn.disabled = false;
      err.textContent = e instanceof Error ? e.message : "Could not send the report.";
      err.classList.remove("hidden");
    }
  }

  return root;
}
