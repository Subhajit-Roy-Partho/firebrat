/* Firebrat Community — legal view: /legal/:doc
   (copyright | terms | privacy | takedown), incl. the takedown notice form.
   Contract: export default async function view(ctx) -> HTMLElement.
   Plain-English summaries only — this page is not legal advice. */

import { h, toast } from "../ui.js";
import { submitTakedown } from "../data.js";
import { navigate } from "../router.js";

// TODO: replace with the real counter-notice contact before launch.
const COUNTER_NOTICE_EMAIL = "takedown@REPLACE-ME.example";

function field(labelText, input, hintText = "") {
  return h(
    "div",
    { class: "field" },
    h("label", { class: "label" }, labelText, input),
    hintText ? h("p", { class: "hint" }, hintText) : null,
  );
}

function prose(title, ...nodes) {
  return h("article", { class: "prose" }, h("h1", {}, title), ...nodes);
}

function p(...children) {
  return h("p", {}, ...children);
}

function h2(text) {
  return h("h2", {}, text);
}

function ul(...items) {
  return h("ul", {}, ...items.map((t) => h("li", {}, t)));
}

function copyrightDoc() {
  return prose(
    "Copyright & licensing policy",
    p(
      "Firebrat Community only accepts audiobooks whose underlying text is copyright-free: public domain in the United States, CC0, CC-BY, or CC-BY-SA. If you submit a book, you are saying the source text qualifies and that you created the audio or have permission to share it.",
    ),
    h2("What we host"),
    p(
      "We host listings, not files. Every audiobook streams from the Internet Archive; our database only stores the listing (title, description, Archive link, and provenance). Removing a listing removes it from this library, but files on the Internet Archive must be handled there too.",
    ),
    h2("How the audio is made"),
    p(
      "Most listings are narrated by software (text-to-speech) rather than a human reader. Each book page has a “How this audio was made” card describing the generation method, engine, and models — check it if that matters to you.",
    ),
    h2("If your rights are affected"),
    p(
      "If you believe a listing infringes your copyright, file a notice on the takedown page. Admins review notices and may mark the book “disputed” (hidden from the library) while it is resolved. Knowingly false claims can have legal consequences.",
    ),
    p(
      h("a", { class: "btn btn-primary", href: "#/legal/takedown" }, "File a copyright notice"),
    ),
    p(
      h("em", { class: "muted small" }, "Plain-English summary, not legal advice. When in doubt, ask a lawyer."),
    ),
  );
}

function termsDoc() {
  return prose(
    "Terms of use",
    p(
      "Firebrat Community is a volunteer-run library of public-domain and openly-licensed audiobooks. By using it you agree to use it respectfully: don't scrape it aggressively, don't upload anything you don't have the right to share, and don't harass other users.",
    ),
    h2("Submissions"),
    ...[
      ul(
        "You must only submit works that are copyright-free (public domain in the US, CC0, CC-BY, or CC-BY-SA).",
        "You must have created the audio yourself or have permission from whoever did.",
        "Listings that violate these terms can be removed at any time.",
      ),
    ],
    h2("Accounts & conduct"),
    p(
      "Comments and ratings are public. Be kind. Spam, harassment, and misleading content can get your content removed. You can delete your own comments.",
    ),
    h2("No warranties"),
    p(
      "The library is provided as-is. Audio quality varies, machine narration can mispronounce words, and metadata may contain mistakes.",
    ),
    p(
      h("em", { class: "muted small" }, "Plain-English summary, not legal advice."),
    ),
  );
}

function privacyDoc() {
  return prose(
    "Privacy",
    p(
      "We collect as little as possible. Accounts and the library database are handled by Firebase Authentication and Cloud Firestore (Google). Audio files stream from the Internet Archive.",
    ),
    h2("What is stored"),
    ...[
      ul(
        "Account: your email and display name (via Firebase Auth).",
        "Library data: books you submit, your ratings, comments, bookmarks, and bug/feedback reports.",
        "Takedown notices: the contact details you provide so admins can follow up (visible to admins only).",
        "Player: your listening position and speed, kept in your own browser's local storage.",
      ),
    ],
    h2("What is never stored"),
    p(
      "Your Internet Archive S3 keys, used during route-B uploads, stay in that browser tab and are cleared afterwards. They are never sent to us or to Firebase.",
    ),
    h2("Third parties"),
    p(
      "Google (Firebase) processes account and library data; the Internet Archive serves audio files when you press play. Their own privacy policies apply to those services.",
    ),
    p(
      h("em", { class: "muted small" }, "Plain-English summary, not legal advice."),
    ),
  );
}

function takedownDoc(prefillBook) {
  const wrap = h("div", { class: "stack" });
  wrap.append(
    prose(
      "Copyright complaints & takedown",
      p(
        "If you believe a book in this library infringes your copyright, tell us with the form below. An administrator will review the notice and may mark the book “disputed” — which hides it from the library — while the issue is resolved.",
      ),
      h2("What happens next"),
      ...[
        ul(
          "Admins review every notice for completeness.",
          "Valid notices may lead to the listing being hidden (status “disputed”) or removed pending resolution.",
          "We may contact you at the email you provide if anything is unclear.",
          "If your content was removed by mistake, you can send a counter-notice to ",
        ),
      ],
      h2("A serious warning"),
      p(
        "Only file a notice for work you actually own or are authorized to represent. In the US, knowingly filing a false claim (misrepresentation) can make you liable for damages. This page is not legal advice — consider talking to a lawyer first.",
      ),
    ),
  );

  // The counter-notice address line needs the email inline; append it to the list above.
  const listItems = wrap.querySelectorAll("li");
  const last = listItems[listItems.length - 1];
  if (last) last.append(h("code", {}, COUNTER_NOTICE_EMAIL), ".");

  const nameI = h("input", { class: "input", type: "text", value: "", "aria-label": "Your full name" });
  const emailI = h("input", { class: "input", type: "email", value: "", "aria-label": "Contact email" });
  const holderI = h("input", {
    class: "input",
    type: "text",
    value: "",
    "aria-label": "Rights holder",
  });
  const bookI = h("input", {
    class: "input",
    type: "text",
    value: prefillBook || "",
    "aria-label": "Book id",
  });
  const workI = h("textarea", { class: "textarea", value: "", "aria-label": "Work description" });
  const urlsI = h("textarea", { class: "textarea", value: "", "aria-label": "Infringing URLs" });
  const sigI = h("input", { class: "input", type: "text", value: "", "aria-label": "Typed signature" });
  const goodFaithI = h("input", { type: "checkbox", "aria-label": "Good-faith statement" });
  const accuracyI = h("input", { type: "checkbox", "aria-label": "Accuracy statement" });
  const err = h("p", { class: "error-text hidden", role: "alert" });

  const form = h(
    "form",
    {
      class: "stack",
      onsubmit: (e) => {
        e.preventDefault();
        void send();
      },
    },
    h("h2", {}, "File a notice"),
    field("Your full name", nameI),
    field("Contact email", emailI, "We may write to you here about this notice."),
    field("Rights holder", holderI, "Who owns the work (you, your company, your client…)."),
    field("Book id in this library", bookI, "The listing's id, e.g. from the book page URL."),
    field("Describe the copyrighted work", workI, "Title, author, where it was published — enough to identify it (max 2000 characters)."),
    field("Infringing URLs", urlsI, "Library or Archive links to the allegedly infringing material."),
    h(
      "label",
      { class: "check-row" },
      goodFaithI,
      h(
        "span",
        {},
        "Good faith: I have a good-faith belief that the use described above is not authorized by the copyright owner, its agent, or the law.",
      ),
    ),
    h(
      "label",
      { class: "check-row" },
      accuracyI,
      h(
        "span",
        {},
        "Accuracy under penalty of perjury: the information in this notice is accurate, and I am the copyright owner or authorized to act for them.",
      ),
    ),
    field("Typed signature", sigI, "Type your full legal name as your signature."),
    err,
    h("div", { class: "row" }, h("button", { class: "btn btn-primary", type: "submit" }, "Submit notice")),
  );

  async function send() {
    err.textContent = "";
    err.classList.add("hidden");
    const formData = {
      bookId: bookI.value.trim().slice(0, 120),
      claimantName: nameI.value.trim().slice(0, 120),
      claimantEmail: emailI.value.trim().slice(0, 200),
      rightsHolder: holderI.value.trim().slice(0, 200),
      workDescription: workI.value.trim().slice(0, 2000),
      infringingUrls: urlsI.value.trim().slice(0, 2000),
      signature: sigI.value.trim().slice(0, 120),
    };
    if (!formData.claimantName) return fail("Please give your name.");
    if (!/.+@.+\..+/.test(formData.claimantEmail)) return fail("Please give a valid contact email.");
    if (!formData.workDescription) return fail("Please describe the copyrighted work.");
    if (!formData.signature) return fail("Please type your signature.");
    if (!goodFaithI.checked || !accuracyI.checked) {
      return fail("Both statements must be checked to file a notice.");
    }
    try {
      await submitTakedown({ ...formData, goodFaith: true, accuracy: true });
      toast("Notice received. An administrator will review it.", { kind: "ok" });
      navigate("/");
    } catch (e) {
      fail(e instanceof Error ? e.message : "Could not send the notice.");
    }
  }

  function fail(msg) {
    err.textContent = msg;
    err.classList.remove("hidden");
  }

  wrap.append(form);
  return wrap;
}

export default async function view(ctx) {
  const doc = (ctx.params && ctx.params.doc) || "copyright";
  if (doc === "terms") return termsDoc();
  if (doc === "privacy") return privacyDoc();
  if (doc === "takedown") {
    const prefill = ctx.query ? ctx.query.get("book") || "" : "";
    return takedownDoc(prefill);
  }
  return copyrightDoc();
}
