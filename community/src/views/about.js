import { h } from "../ui.js";

export default async function view() {
  const root = h("div", { class: "stack" });
  root.append(h("h1", {}, "About Firebrat Community"));

  root.append(h("section", { class: "section" },
    h("div", { class: "section-head" }, h("h2", {}, "What this is")),
    h("p", { class: "muted" },
      "Firebrat Community is a free library of public-domain and openly-licensed audiobooks. ",
      "Every book is shared under a clear license — public domain, CC0, CC BY, or CC BY-SA — ",
      "so you can listen, download, and share without worry.")));

  root.append(h("section", { class: "section" },
    h("div", { class: "section-head" }, h("h2", {}, "How the audio is made")),
    h("p", { class: "muted" },
      "Some books are narrated with the Firebrat text-to-speech pipeline, some are human-narrated, ",
      "and some mix both. Each book page has a “How this audio was made” card with the generation method, ",
      "engine, models, and source-work details for full transparency.")));

  root.append(h("section", { class: "section" },
    h("div", { class: "section-head" }, h("h2", {}, "How to submit")),
    h("p", { class: "muted" },
      "Have a copyright-free recording to share? ",
      "Submit a book ",
      h("a", { href: "#/submit" }, "here"),
      ". There are two routes: (A) link an Internet Archive item you already uploaded, ",
      "or (B) upload your package and we help you place it on the Internet Archive.")));

  root.append(h("section", { class: "section" },
    h("div", { class: "section-head" }, h("h2", {}, "Where files live")),
    h("p", { class: "muted" },
      "Audio files stream directly from the ",
      h("a", { href: "https://archive.org/", target: "_blank", rel: "noopener" }, "Internet Archive"),
      ", a nonprofit digital library. Downloads come from the Archive too, so they keep working ",
      "even if this site is down.")));

  root.append(h("section", { class: "section" },
    h("div", { class: "section-head" }, h("h2", {}, "Firebrat app")),
    h("p", { class: "muted" },
      "Prefer listening on your phone? Open any book in the Firebrat app, or try the ",
      h("a", { href: "https://subhajit-roy-partho.github.io/firebrat/", target: "_blank", rel: "noopener" }, "Firebrat PWA"),
      " for offline playback with word-level highlighting.")));

  return root;
}
