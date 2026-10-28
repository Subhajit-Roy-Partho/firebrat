/* Firebrat Community — legal view: /legal/:doc
   (copyright | terms | privacy | takedown), incl. the takedown notice form.
   Contract: export default async function view(ctx) -> HTMLElement.
   Plain-English summaries only — this page is not legal advice. */

import { h, toast } from "../ui.js";
import { submitTakedown } from "../data.js";
import { navigate } from "../router.js";

// Counter-notices go through the public issue tracker (no personal mailbox is published).
const COUNTER_NOTICE_URL = "https://github.com/Subhajit-Roy-Partho/firebrat/issues/new?title=Counter-notice";

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

function table(headers, rows) {
  return h(
    "div",
    { class: "table-wrap", style: "overflow-x:auto" },
    h(
      "table",
      { class: "table" },
      h("thead", {}, h("tr", {}, ...headers.map((t) => h("th", { scope: "col" }, t)))),
      h("tbody", {}, ...rows.map((r) => h("tr", {}, ...r.map((c) => h("td", {}, c))))),
    ),
  );
}

// Source works of the launch catalogue (Project Gutenberg editions). Dates are the
// author's / translator's year of death; every work was first published before 1931.
const LAUNCH_WORKS = [
  ["Alice's Adventures in Wonderland", "Lewis Carroll (d. 1898)", "1865", "#11"],
  ["Frankenstein", "Mary Wollstonecraft Shelley (d. 1851)", "1818", "#84"],
  ["The Picture of Dorian Gray", "Oscar Wilde (d. 1900)", "1890/1891", "#174"],
  ["Anne of Green Gables", "L. M. Montgomery (d. 1942)", "1908", "#45"],
  ["The Adventures of Sherlock Holmes", "Arthur Conan Doyle (d. 1930)", "1892", "#1661"],
  ["Pride and Prejudice", "Jane Austen (d. 1817)", "1813", "#1342"],
  ["Dracula", "Bram Stoker (d. 1912)", "1897", "#345"],
  ["Jane Eyre", "Charlotte Brontë (d. 1855)", "1847", "#1260"],
  ["Little Women", "Louisa May Alcott (d. 1888)", "1868–69", "#37106"],
  [
    "Crime and Punishment",
    "Fyodor Dostoyevsky (d. 1881), English translation by Constance Garnett (d. 1946)",
    "1866 / 1914",
    "#2554",
  ],
];

function declarationDoc() {
  return prose(
    "Declaration of content, sources & legal status",
    p(
      h("em", { class: "muted small" }, "Last updated 28 October 2026. This is a good-faith statement of facts about this library. It is not legal advice, and it does not create any warranty or contract."),
    ),
    h2("1. Who runs this"),
    p(
      "Firebrat Community is an independent, non-commercial, volunteer-run project. It is not a company, charity or publisher, and it is not affiliated with, sponsored by or endorsed by Project Gutenberg, the Internet Archive, Google, Alibaba/Qwen, or any author, estate or publisher named on this site. Those names are used only to identify sources and tools accurately.",
    ),
    h2("2. What this library contains"),
    ul(
      "Listings (title, author, description, tags, ratings, comments) stored in Google Cloud Firestore.",
      "Links to audiobook packages stored on the Internet Archive. This site does not host the audio files; they stream and download from archive.org.",
      "For the launch catalogue below, the audio was generated by the Firebrat team's own text-to-speech pipeline from public-domain texts.",
    ),
    h2("3. Copyright status of the underlying texts"),
    p(
      "The launch catalogue uses only texts that we believe, in good faith, are in the public domain in the United States, where this project is operated from. Every work below was first published before 1931, and each author (and, for Crime and Punishment, its translator) died more than 70 years ago. The text of each book was taken from the Project Gutenberg ebook listed.",
    ),
    table(
      ["Work", "Author / translator", "First published", "Gutenberg ebook"],
      LAUNCH_WORKS,
    ),
    p(
      "Public-domain status depends on the country. The facts above mean these works are also public domain in countries that protect works for the author's life plus 70 years or less. Some countries protect works for longer (for example, life plus 80 or 100 years), and the status of a work there may differ. If you are outside the United States, check your local law before you copy, adapt or redistribute a work.",
    ),
    p(
      "We have not obtained a legal opinion on each work. Modern editorial additions (introductions, notes, newly commissioned illustrations or translations) can carry their own copyright even when the original text does not. We aim to use only the original public-domain text. Each cover image is the one bundled in that Project Gutenberg ebook file; we have not independently verified the rights status of each cover. If you believe a particular cover is protected, tell us using section 9 and we will review it promptly.",
    ),
    h2("4. The audio is synthetic (AI-generated)"),
    ul(
      "The narration is generated speech, not a human recording. No human narrator performed these books.",
      "Speech is produced with Qwen3-TTS models. Each character’s voice is created from a written description (for example, “a young girl about ten years old”) and then reused for that character. No real person’s voice recording was used as a reference, and no voice is intended to imitate any real person.",
      "A language model assigns lines to characters. Narration can mispronounce names or words, misattribute a speaker, or contain errors. We check samples automatically, but not every sentence is reviewed by a human.",
      "The pipeline software and model licences are those published by their respective authors; see each model’s page for its terms.",
    ),
    h2("5. Licence of the audio and packages"),
    p(
      "The generated audio, package files and metadata created by this project for the launch catalogue are licensed under ",
      h("a", { href: "https://creativecommons.org/licenses/by/4.0/", target: "_blank", rel: "noopener" }, "Creative Commons Attribution 4.0 (CC BY 4.0)"),
      ". You may copy, share and adapt them, including commercially, as long as you give credit (for example: “Audio by Firebrat Community, https://subhajit-roy-partho.github.io/firebrat/community/”) and indicate if you made changes. The licence covers only what this project itself created. It claims no rights in the underlying texts, which we believe are in the public domain, and it does not apply to material added by other contributors.",
    ),
    p(
      "Each book page shows its own licence and provenance. Books submitted by other contributors are licensed as their submitters declare, subject to the terms below.",
    ),
    h2("6. Contributions by other people"),
    ul(
      "Contributors must attest that the source text is public domain, CC0, CC-BY or CC-BY-SA, and that they created the audio or have permission to share it.",
      "We do not independently verify every submission. Each contributor is responsible for the accuracy of their declaration and for the rights in what they upload.",
      "Listings may be hidden or removed at any time, including after a complaint (see section 9).",
      "Comments and ratings are published by their authors, who are responsible for them.",
    ),
    h2("7. Internet Archive"),
    p(
      "Audio is stored on and delivered by the Internet Archive, which has its own terms of use and its own process for handling copyright complaints. Removing a listing from this library does not remove the underlying Internet Archive item; a rights holder may also need to contact the Internet Archive directly.",
    ),
    h2("8. Personal data"),
    p(
      "See the ",
      h("a", { href: "#/legal/privacy" }, "privacy page"),
      ". In short: sign-in uses Firebase Authentication; we store your account name and email, your submissions, ratings, comments and the record of what you uploaded and its Internet Archive link. We do not sell personal data or use it for advertising. Takedown contact details are visible to administrators only.",
    ),
    h2("9. Copyright complaints and takedowns"),
    ul(
      "If you own or represent the rights to something listed here, use the notice form on the takedown page. An administrator reviews notices and may hide (“dispute”) or remove a listing while the matter is resolved.",
      "If a listing was removed by mistake, you can send a counter-notice through the public issue tracker linked on the takedown page.",
      "Only file a notice for a work you own or are authorised to represent. Knowingly false claims can have legal consequences.",
    ),
    p(
      "This project has not designated an agent with the US Copyright Office under 17 U.S.C. § 512(c), so we do not claim the DMCA safe-harbour protections. We still act on notices in good faith and as quickly as volunteers can; we do not promise a fixed response time.",
    ),
    h2("10. No warranty; limits"),
    p(
      "The library is provided “as is” and “as available”, free of charge, without warranties of any kind. To the extent permitted by law, the maintainers are not liable for losses arising from its use, from errors in generated audio or metadata, or from content submitted by others. Nothing here limits any right you have that cannot be limited by law.",
    ),
    h2("11. Changes"),
    p(
      "We may update this declaration as the catalogue or the law changes. The date at the top shows the latest revision.",
    ),
    p(
      h("a", { class: "btn btn-primary", href: "#/legal/takedown" }, "File a copyright notice"),
      " ",
      h("a", { class: "btn", href: "#/legal/terms" }, "Terms of use"),
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
          "If your content was removed by mistake, you can send a counter-notice by ",
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
  if (last) last.append(h("a", { href: COUNTER_NOTICE_URL, target: "_blank", rel: "noopener" }, "opening a counter-notice issue"), ".");

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
  if (doc === "declaration") return declarationDoc();
  if (doc === "terms") return termsDoc();
  if (doc === "privacy") return privacyDoc();
  if (doc === "takedown") {
    const prefill = ctx.query ? ctx.query.get("book") || "" : "";
    return takedownDoc(prefill);
  }
  return copyrightDoc();
}
