/* Firebrat Community — submit view: 4-step wizard (source -> package check
   -> details & provenance -> review & publish) with Internet Archive route
   A (already hosted) / route B (upload from this tab).
   Contract: export default async function view(ctx) -> HTMLElement. */

import { h, toast, emptyState, formatDuration, formatBytes, requireSignIn } from "../ui.js";
import { createBook } from "../data.js";
import {
  parseArchiveUrl,
  fetchItem,
  locatePackage,
  validateManifest,
  buildChapters,
  validateChapters,
  MAX_CHAPTERS,
  uploadToArchive,
  slugify,
} from "../ia.js";
import { readManifestFromZip } from "../zipmanifest.js";
import { navigate } from "../router.js";

const DRAFT_KEY = "firebrat.submit.draft.v1";
const S3_KEYS_URL = "https://archive.org/account/s3.php";
const MANUAL_UPLOAD_URL = "https://archive.org/upload";
const STEPS = ["Source", "Package check", "Details & provenance", "Review & publish"];
const CATEGORIES = [
  "fiction",
  "nonfiction",
  "science",
  "history",
  "poetry",
  "children",
  "education",
  "other",
];
const GENERATIONS = ["firebrat-tts", "human-narrated", "mixed", "other"];
const LICENSES = ["public-domain", "cc0", "cc-by", "cc-by-sa"];

function loadDraft() {
  try {
    const raw = sessionStorage.getItem(DRAFT_KEY);
    const d = raw ? JSON.parse(raw) : {};
    return d && typeof d === "object" ? d : {};
  } catch {
    return {};
  }
}

// NOTE: IA S3 keys are never written here — they live only in memory.
function saveDraft(draft) {
  try {
    sessionStorage.setItem(DRAFT_KEY, JSON.stringify(draft));
  } catch {
    // storage full or blocked: the wizard still works, it just won't resume.
  }
}

function clearDraft() {
  try {
    sessionStorage.removeItem(DRAFT_KEY);
  } catch {
    // ignore
  }
}

function randSuffix(n = 6) {
  return Math.random()
    .toString(36)
    .slice(2, 2 + n);
}

function bookIdFor(title, archiveId) {
  let base = slugify(title) || slugify(archiveId) || "audiobook";
  if (base.length < 3) base = `${base}-book`;
  return `${base}-${randSuffix(4)}`.slice(0, 100);
}

function field(labelText, input, hintText = "") {
  return h(
    "div",
    { class: "field" },
    h("label", { class: "label" }, labelText, input),
    hintText ? h("p", { class: "hint" }, hintText) : null,
  );
}

function errEl() {
  return h("p", { class: "error-text", role: "alert" });
}

function setErr(el, msg) {
  el.textContent = msg || "";
  el.classList.toggle("hidden", !msg);
}

export default async function view() {
  const root = h("div", { class: "stack" });

  // Sign-in gate: submissions are attributed, so guests must sign in first.
  let user = null;
  try {
    user = await requireSignIn();
  } catch {
    user = null;
  }
  if (!user) {
    root.append(
      h("h1", {}, "Submit an audiobook"),
      emptyState({
        icon: "🔑",
        title: "Sign in to submit",
        body: "Submissions are attributed to your account so we can reach you about your listing.",
        action: {
          label: "Back home",
          href: "#/",
        },
      }),
    );
    return root;
  }

  const draft = loadDraft();

  const S = {
    step: 0,
    route: draft.route || null, // 'a' | 'b'
    // Route A state
    archiveUrl: draft.archiveUrl || "",
    // Verified package (either route)
    archiveId: null,
    packageKind: null,
    zipName: "",
    manifest: null,
    validation: null,
    chapters: null,
    chaptersError: "",
    sizeWarn: "",
    sizeBytes: 0,
    iaFiles: [],
    // Route B transient state (never persisted)
    file: null,
    fileName: "",
    accessKey: "",
    secretKey: "",
    uploading: false,
    progress: 0,
    uploadError: "",
    aborter: null,
    uploaded: false,
    details: {
      title: draft.title || "",
      author: draft.author || "",
      description: draft.description || "",
      language: draft.language || "",
      category: draft.category || "",
      tags: draft.tags || "",
      generation: draft.generation || "firebrat-tts",
      narrationEngine: draft.narrationEngine || "",
      models: draft.models || "",
      pipelineNotes: draft.pipelineNotes || "",
      sourceTitle: draft.sourceTitle || "",
      sourceUrl: draft.sourceUrl || "",
      license: draft.license || "",
      licenseUrl: draft.licenseUrl || "",
    },
    attestOwn: false,
    attestSource: false,
  };

  const persist = () => {
    saveDraft({
      route: S.route,
      archiveUrl: S.archiveUrl,
      ...S.details,
    });
  };

  root.append(h("h1", {}, "Submit an audiobook"));
  root.append(
    h(
      "p",
      { class: "muted" },
      "Every audiobook is hosted by the Internet Archive — we only store its listing. Pick a route below to connect your files.",
    ),
  );

  const stepsEl = h("ol", { class: "steps", "aria-label": "Submission steps" });
  const bodyEl = h("div", { class: "stack" });
  const navEl = h("div", { class: "row" });
  root.append(stepsEl, bodyEl, navEl);

  function renderSteps() {
    stepsEl.replaceChildren();
    STEPS.forEach((label, i) => {
      const cls =
        "step" + (i === S.step ? " is-active" : "") + (i < S.step ? " is-done" : "");
      stepsEl.append(
        h(
          "li",
          { class: cls, "aria-current": i === S.step ? "step" : null },
          h("span", { class: "step-dot", "aria-hidden": "true" }, i < S.step ? "✓" : String(i + 1)),
          h("span", { class: "step-label" }, label),
        ),
      );
    });
  }

  function canContinue() {
    if (S.step === 0) return !!S.route;
    if (S.step === 1) return !!(S.validation && S.validation.ok && S.manifest && S.chapters && S.chapters.length);
    if (S.step === 2) return detailsErrors().length === 0;
    return false;
  }

  function renderNav() {
    navEl.replaceChildren();
    if (S.step > 0) {
      navEl.append(
        h("button", { class: "btn btn-ghost", onclick: () => go(S.step - 1) }, "← Back"),
      );
    }
    navEl.append(h("span", { class: "spacer" }));
    if (S.step < 3) {
      navEl.append(
        h(
          "button",
          {
            class: "btn btn-primary",
            disabled: !canContinue(),
            onclick: () => {
              if (canContinue()) go(S.step + 1);
            },
          },
          "Continue →",
        ),
      );
    }
  }

  function refresh() {
    renderSteps();
    renderNav();
  }

  function go(n) {
    S.step = Math.max(0, Math.min(3, n));
    renderSteps();
    if (S.step === 0) renderStepSource();
    else if (S.step === 1) renderStepPackage();
    else if (S.step === 2) renderStepDetails();
    else renderStepReview();
    renderNav();
  }

  /* ——— step 1: source route ——— */

  function renderStepSource() {
    bodyEl.replaceChildren();
    const cards = h("div", { class: "route-cards" });

    const cardA = h(
      "button",
      {
        type: "button",
        class: "route-card" + (S.route === "a" ? " is-selected" : ""),
        "aria-pressed": S.route === "a" ? "true" : "false",
        onclick: () => {
          S.route = "a";
          S.uploaded = false;
          persist();
          renderStepSource();
          refresh();
        },
      },
      h("div", { class: "route-title" }, "A · Already on the Archive"),
      h(
        "p",
        { class: "muted small" },
        "I already have it on the Internet Archive — I'll paste the URL and we'll verify it live.",
      ),
    );
    const cardB = h(
      "button",
      {
        type: "button",
        class: "route-card" + (S.route === "b" ? " is-selected" : ""),
        "aria-pressed": S.route === "b" ? "true" : "false",
        onclick: () => {
          S.route = "b";
          persist();
          renderStepSource();
          refresh();
        },
      },
      h("div", { class: "route-title" }, "B · Upload it for me"),
      h(
        "p",
        { class: "muted small" },
        "Upload it to the Internet Archive for me — your zip goes straight from this browser tab to archive.org using your own IA keys.",
      ),
    );
    cards.append(cardA, cardB);
    bodyEl.append(cards);

    if (S.route === "b") {
      const keysLink = h(
        "a",
        { href: S3_KEYS_URL, target: "_blank", rel: "noopener noreferrer" },
        S3_KEYS_URL,
      );
      bodyEl.append(
        h(
          "div",
          { class: "prov-card" },
          h("h3", {}, "How route B works"),
          h(
            "p",
            { class: "muted small" },
            "Your zip uploads directly to the Internet Archive's S3 API from this tab using YOUR own IA keys (find them at ",
            keysLink,
            "). The keys stay in this tab and are never saved or sent to us. If the direct upload fails (for example CORS or network blocks), we'll show you manual steps and you can finish via route A.",
          ),
        ),
      );
    } else if (S.route === "a") {
      bodyEl.append(
        h(
          "p",
          { class: "hint" },
          "Paste any archive.org details, download, or embed URL on the next step — we'll check the item and its manifest live.",
        ),
      );
    }
  }

  /* ——— step 2: package check ——— */

  function chapterTotals() {
    if (Array.isArray(S.chapters) && S.chapters.length) {
      const sum = S.chapters.reduce((a, c) => a + (Number.isInteger(c.durationMs) ? c.durationMs : 0), 0);
      return { count: S.chapters.length, durationMs: sum };
    }
    const v = S.validation;
    const m = S.manifest;
    const n = Number(m?.total_duration_ms);
    return {
      count: v ? v.summary.sectionCount : 0,
      durationMs: Number.isFinite(n) && n >= 0 ? Math.floor(n) : 0,
    };
  }

  function summaryBox() {
    if (!S.validation || !S.manifest) return null;
    const v = S.validation;
    const m = S.manifest;
    if (!v.ok) {
      return h(
        "div",
        { class: "prov-card" },
        h("h3", {}, "Manifest problems"),
        h(
          "ul",
          {},
          ...v.errors.map((e) => h("li", { class: "error-text small" }, e)),
        ),
        h(
          "p",
          { class: "hint" },
          "Fix the package and try again. The manifest needs schema_version “1.0”, a title, and at least one section with audio_path + segments_path.",
        ),
      );
    }
    const totals = chapterTotals();
    const rows = [
      ["Title", v.summary.title || m.title || "—"],
      ["Author", v.summary.author || m.author || "—"],
      ["Sections", String(totals.count)],
      ["Duration", formatDuration(totals.durationMs)],
      ["Engine", v.summary.engine || "—"],
      ["Package", S.packageKind === "zip" ? `zip${S.zipName ? ` (${S.zipName})` : ""}` : "folder"],
      ["Size", S.sizeBytes ? formatBytes(S.sizeBytes) : "—"],
    ];
    const card = h(
      "div",
      { class: "prov-card" },
      h("h3", {}, "Package looks good ✓"),
      h(
        "dl",
        {},
        ...rows.flatMap(([k, val]) => [
          h("div", { class: "prov-row" }, h("dt", {}, k), h("dd", {}, val)),
        ]),
      ),
    );
    if (S.sizeWarn) card.append(h("p", { class: "hint size-warn" }, S.sizeWarn));
    if (S.chaptersError) card.append(h("p", { class: "error-text small" }, S.chaptersError));
    return card;
  }

  function prefillFromManifest() {
    const m = S.manifest || {};
    const nv = m.narrator_voice || {};
    if (!S.details.title && m.title) S.details.title = String(m.title).slice(0, 200);
    if (!S.details.author && m.author) S.details.author = String(m.author).slice(0, 200);
    if (!S.details.narrationEngine && (nv.engine || nv.model_class)) {
      S.details.narrationEngine = String(nv.engine || nv.model_class).slice(0, 120);
    }
    if (!S.details.models) {
      const models = [nv.model_class, nv.model, nv.voice].filter(Boolean).map(String);
      if (models.length) S.details.models = models.slice(0, 10).join(", ");
    }
    persist();
  }

  function renderStepPackage() {
    bodyEl.replaceChildren();
    if (S.route === "a") renderPackageA();
    else renderPackageB();
    refresh();
  }

  function iaSizeOf(files, name) {
    const entry = (files || []).find((f) => {
      const n = typeof f === "string" ? f : f.name;
      return String(n ?? "").replace(/^\.\//, "").replace(/^\/+/, "") === name;
    });
    const size = Number(entry && typeof entry === "object" ? entry.size : NaN);
    return Number.isFinite(size) && size >= 0 ? size : null;
  }

  function fileListBox(files) {
    const rows = (files || []).slice(0, 12).map((f) => {
      const n = typeof f === "string" ? f : f.name;
      const size = typeof f === "object" && f.size != null ? Number(f.size) : NaN;
      return h(
        "li",
        { class: "small" },
        h("code", {}, String(n ?? "")),
        Number.isFinite(size) ? h("span", { class: "muted" }, ` — ${formatBytes(size)}`) : null,
      );
    });
    const extra = (files || []).length > 12
      ? h("li", { class: "small muted" }, `…and ${(files || []).length - 12} more`)
      : null;
    return h("ul", { class: "file-list" }, ...rows, extra);
  }

  function applyLocalManifest(manifest, localSize, localName) {
    const v = validateManifest(manifest);
    S.manifest = manifest;
    S.validation = v;
    S.chapters = null;
    S.chaptersError = "";
    S.sizeWarn = "";
    if (!v.ok) {
      toast("Manifest has problems — see details above.", { kind: "err" });
      return;
    }
    const chapters = buildChapters(manifest);
    const cv = validateChapters(chapters);
    if (!cv.ok) {
      S.chapters = null;
      S.chaptersError = cv.errors[0] || "Chapter list is invalid.";
      if (chapters.length > MAX_CHAPTERS) {
        toast("Package too large: too many chapters.", { kind: "err" });
      } else {
        toast("Chapter list has problems — see details above.", { kind: "err" });
      }
      return;
    }
    S.chapters = chapters;
    // The IA item must really contain the same package file (name match),
    // with a size warning when the local copy differs by more than 1%.
    if (S.packageKind === "zip") {
      if (localName && S.zipName && localName !== S.zipName) {
        S.sizeWarn =
          `Local file “${localName}” does not match the Archive file “${S.zipName}”. ` +
          `Playback uses the Archive copy — pick your local copy of “${S.zipName}” to be sure they match.`;
      }
      const iaSize = iaSizeOf(S.iaFiles, S.zipName);
      if (iaSize != null && Number.isFinite(localSize) && localSize > 0) {
        const diff = Math.abs(localSize - iaSize) / Math.max(1, iaSize);
        if (diff > 0.01) {
          S.sizeWarn =
            `Size differs from the Archive copy (${formatBytes(iaSize)} on the Archive, ` +
            `${formatBytes(localSize)} locally). Playback uses the Archive copy.`;
        }
      }
      S.sizeBytes = iaSize ?? (Number.isFinite(localSize) ? localSize : 0);
    } else {
      const iaSize = iaSizeOf(S.iaFiles, "manifest.json");
      if (iaSize != null && Number.isFinite(localSize) && localSize > 0) {
        const diff = Math.abs(localSize - iaSize) / Math.max(1, iaSize);
        if (diff > 0.01) {
          S.sizeWarn =
            `Local manifest.json (${formatBytes(localSize)}) differs from the Archive copy ` +
            `(${formatBytes(iaSize)}). Playback uses the Archive copy.`;
        }
      }
      S.sizeBytes = iaSize ?? 0;
    }
    prefillFromManifest();
    toast("Package verified.", { kind: "ok" });
  }

  function renderPackageA() {
    const urlInput = h("input", {
      class: "input",
      type: "url",
      placeholder: "https://archive.org/details/my-audiobook",
      value: S.archiveUrl,
      "aria-label": "Internet Archive item URL",
    });
    const status = h("div", { class: "stack" });
    const err = errEl();
    err.classList.add("hidden");

    async function verify() {
      setErr(err, "");
      status.replaceChildren();
      const checking = h("p", { class: "muted" }, "Checking the Archive…");
      status.append(checking);
      try {
        const id = parseArchiveUrl(urlInput.value.trim());
        if (!id) {
          throw new Error(
            "That doesn't look like an Internet Archive item URL. Use archive.org/details/…, /download/…, or /embed/… links.",
          );
        }
        S.archiveUrl = urlInput.value.trim();
        // Metadata API only — never fetch() the manifest cross-origin
        // (/download/... has no CORS headers, so that would fail).
        const files = await fetchItem(id);
        const loc = locatePackage(files);
        if (!loc) {
          throw new Error(
            "No book package found in that item: it needs a manifest.json or a .zip file.",
          );
        }
        S.archiveId = id;
        S.packageKind = loc.kind;
        S.zipName = loc.kind === "zip" ? loc.zip : "";
        S.iaFiles = files;
        S.manifest = null;
        S.validation = null;
        S.chapters = null;
        S.chaptersError = "";
        S.sizeWarn = "";
        S.sizeBytes = 0;
        persist();
        status.replaceChildren();
        const found = loc.kind === "zip"
          ? h("p", { class: "muted small" }, `Found package file: `, h("code", {}, loc.zip))
          : h("p", { class: "muted small" }, "Found package: root manifest.json (folder layout).");
        status.append(found, fileListBox(files));
        status.append(localPickerBox());
        toast("Archive item found. Now pick your local copy below.", { kind: "ok" });
      } catch (e) {
        S.validation = null;
        S.manifest = null;
        S.chapters = null;
        status.replaceChildren();
        setErr(err, e instanceof Error ? e.message : "Verification failed.");
      }
      refresh();
    }

    function localPickerBox() {
      const pickErr = errEl();
      pickErr.classList.add("hidden");
      const zipInput = h("input", {
        class: "input",
        type: "file",
        accept: ".zip,application/zip",
        "aria-label": "Local copy of the package zip",
      });
      const jsonInput = h("input", {
        class: "input",
        type: "file",
        accept: ".json,application/json",
        "aria-label": "Local copy of manifest.json",
      });
      async function onZipFile() {
        setErr(pickErr, "");
        const f = zipInput.files && zipInput.files[0];
        if (!f) return;
        try {
          const manifest = await readManifestFromZip(f);
          applyLocalManifest(manifest, f.size, f.name);
          status.append(summaryBox());
        } catch (e) {
          setErr(pickErr, e instanceof Error ? e.message : "Could not read the zip.");
        }
        refresh();
      }
      async function onJsonFile() {
        setErr(pickErr, "");
        const f = jsonInput.files && jsonInput.files[0];
        if (!f) return;
        try {
          const text = await f.text();
          let manifest;
          try {
            manifest = JSON.parse(text);
          } catch {
            throw new Error("That manifest.json is not valid JSON.");
          }
          applyLocalManifest(manifest, f.size, f.name);
          status.append(summaryBox());
        } catch (e) {
          setErr(pickErr, e instanceof Error ? e.message : "Could not read manifest.json.");
        }
        refresh();
      }
      zipInput.addEventListener("change", () => onZipFile());
      jsonInput.addEventListener("change", () => onJsonFile());
      return h(
        "div",
        { class: "stack" },
        h(
          "p",
          { class: "hint" },
          "We read the chapter list in your browser only — nothing is uploaded here.",
        ),
        S.packageKind === "zip"
          ? field("Your local copy of the zip", zipInput, "Pick the same .zip file that is on the Archive.")
          : field("Your local manifest.json", jsonInput, "Pick the same manifest.json that is at the item root."),
        S.packageKind === "zip"
          ? h("details", { class: "small" },
            h("summary", {}, "My zip is unpacked / I only have manifest.json"),
            h("div", { class: "stack" }, field("Or pick manifest.json instead", jsonInput)))
          : h("details", { class: "small" },
            h("summary", {}, "I have the whole folder as a zip"),
            h("div", { class: "stack" }, field("Or pick the .zip instead", zipInput))),
        pickErr,
      );
    }

    urlInput.addEventListener("input", () => {
      S.archiveUrl = urlInput.value;
      persist();
    });
    const verifyBtn = h("button", { class: "btn btn-primary", onclick: () => verify() }, "Verify URL");
    bodyEl.append(
      h("h2", {}, "Where is it on the Archive?"),
      field("Internet Archive URL", urlInput, "Details, download, or embed URLs all work."),
      h("div", { class: "row" }, verifyBtn),
      err,
      status,
    );
    if (S.archiveId && S.iaFiles.length) {
      const found = S.packageKind === "zip"
        ? h("p", { class: "muted small" }, `Found package file: `, h("code", {}, S.zipName))
        : h("p", { class: "muted small" }, "Found package: root manifest.json (folder layout).");
      status.append(found, fileListBox(S.iaFiles), localPickerBox());
    }
    if (S.manifest && S.validation) status.append(summaryBox());
  }

  function renderPackageB() {
    const status = h("div", { class: "stack" });
    const err = errEl();
    err.classList.add("hidden");

    const fileInput = h("input", {
      class: "input",
      type: "file",
      accept: ".zip,application/zip",
      "aria-label": "Book package zip file",
    });
    const keyInput = h("input", {
      class: "input",
      type: "text",
      autocomplete: "off",
      spellcheck: "false",
      placeholder: "IA S3 access key",
      "aria-label": "Internet Archive S3 access key",
    });
    const secretInput = h("input", {
      class: "input",
      type: "password",
      autocomplete: "off",
      placeholder: "IA S3 secret key",
      "aria-label": "Internet Archive S3 secret key",
    });
    const progressWrap = h("div", { class: "progress-wrap", role: "progressbar" });
    const progressFill = h("div", { class: "progress-fill" });
    progressWrap.append(progressFill);
    progressWrap.classList.add("hidden");

    async function inspect() {
      setErr(err, "");
      status.replaceChildren();
      S.validation = null;
      S.manifest = null;
      S.chapters = null;
      S.chaptersError = "";
      S.sizeWarn = "";
      S.uploaded = false;
      try {
        const f = fileInput.files && fileInput.files[0];
        if (!f) throw new Error("Choose the .zip package first.");
        if (!/\.zip$/i.test(f.name)) throw new Error("That doesn't look like a .zip file.");
        S.file = f;
        S.fileName = f.name;
        S.sizeBytes = f.size;
        S.packageKind = "zip";
        S.zipName = f.name;
        status.append(h("p", { class: "muted" }, "Reading manifest.json from your zip…"));
        const manifest = await readManifestFromZip(f);
        const v = validateManifest(manifest);
        S.manifest = manifest;
        S.validation = v;
        if (v.ok) {
          const chapters = buildChapters(manifest);
          const cv = validateChapters(chapters);
          if (!cv.ok) {
            S.chapters = null;
            S.chaptersError = cv.errors[0] || "Chapter list is invalid.";
          } else {
            S.chapters = chapters;
          }
        }
        prefillFromManifest();
        status.replaceChildren(summaryBox());
        if (!v.ok) toast("Manifest has problems — see details above.", { kind: "err" });
        else if (!S.chapters) toast(S.chaptersError || "Chapter list is invalid.", { kind: "err" });
      } catch (e) {
        status.replaceChildren();
        setErr(err, e instanceof Error ? e.message : "Could not read the zip.");
      }
      refresh();
    }

    async function upload() {
      setErr(err, "");
      S.uploadError = "";
      if (!S.file) {
        setErr(err, "Choose the .zip package first.");
        return;
      }
      if (!S.validation || !S.validation.ok || !S.chapters || !S.chapters.length) {
        setErr(err, "Verify the package manifest first — fix any problems above.");
        return;
      }
      const accessKey = keyInput.value.trim();
      const secretKey = secretInput.value;
      if (!accessKey || !secretKey) {
        setErr(err, "Enter your Internet Archive S3 keys (they never leave this tab).");
        return;
      }
      const title = S.details.title || S.manifest.title || S.fileName.replace(/\.zip$/i, "");
      const identifier = `${slugify(title) || "audiobook"}-${randSuffix(4)}`.slice(0, 100);
      S.uploading = true;
      S.progress = 0;
      S.aborter = new AbortController();
      progressWrap.classList.remove("hidden");
      uploadBtn.disabled = true;
      cancelBtn.classList.remove("hidden");
      refresh();
      try {
        const meta = {
          title: String(S.details.title || S.manifest.title || identifier).slice(0, 300),
          creator: String(S.details.author || S.manifest.author || "").slice(0, 300),
          description: String(S.details.description || "").slice(0, 1000),
          license: "http://creativecommons.org/publicdomain/mark/1.0/",
        };
        const res = await uploadToArchive({
          file: S.file,
          identifier,
          meta,
          accessKey,
          secretKey,
          signal: S.aborter.signal,
          onProgress: (frac) => {
            S.progress = frac;
            progressFill.style.width = `${Math.round(frac * 100)}%`;
          },
        });
        S.archiveId = identifier;
        S.archiveUrl = res.url;
        S.packageKind = "zip";
        S.zipName = S.file.name;
        S.uploaded = true;
        keyInput.value = "";
        secretInput.value = "";
        S.accessKey = "";
        S.secretKey = "";
        status.append(
          h("p", { class: "muted small" }, `Uploaded to ${res.url} — continue to the next step.`),
        );
        toast("Upload complete.", { kind: "ok" });
      } catch (e) {
        if (e && e.name === "AbortError") {
          setErr(err, "Upload cancelled.");
        } else {
          const manual = h(
            "a",
            { href: MANUAL_UPLOAD_URL, target: "_blank", rel: "noopener noreferrer" },
            "manual upload steps",
          );
          const box = h(
            "p",
            { class: "error-text small" },
            e instanceof Error ? e.message : "Upload failed.",
            " ",
          );
          box.append(document.createTextNode("You can also follow the "));
          box.append(manual);
          box.append(
            document.createTextNode(" at archive.org/upload, then submit via route A."),
          );
          status.append(box);
        }
      } finally {
        S.uploading = false;
        S.aborter = null;
        uploadBtn.disabled = false;
        cancelBtn.classList.add("hidden");
        refresh();
      }
    }

    const inspectBtn = h("button", { class: "btn btn-ghost", onclick: () => inspect() }, "Read manifest");
    const uploadBtn = h(
      "button",
      { class: "btn btn-primary", onclick: () => upload() },
      "Upload to the Internet Archive",
    );
    const cancelBtn = h(
      "button",
      {
        class: "btn btn-ghost hidden",
        onclick: () => {
          if (S.aborter) S.aborter.abort();
        },
      },
      "Cancel upload",
    );
    fileInput.addEventListener("change", () => inspect());

    const keysLink = h(
      "a",
      { href: S3_KEYS_URL, target: "_blank", rel: "noopener noreferrer" },
      "archive.org/account/s3.php",
    );
    bodyEl.append(
      h("h2", {}, "Upload your package"),
      field("Book package (.zip with manifest.json)", fileInput, "We read only manifest.json from your file to check it — the full upload happens in the next step."),
      h("div", { class: "row" }, inspectBtn),
      err,
      status,
      h("h2", {}, "Your Internet Archive keys"),
      h(
        "p",
        { class: "hint" },
        "Get your S3 keys at ",
        keysLink,
        ". They stay in this tab, are used only for this upload, and are cleared afterwards.",
      ),
      field("S3 access key", keyInput),
      field("S3 secret key", secretInput),
      progressWrap,
      h("div", { class: "row" }, uploadBtn, cancelBtn),
    );
  }

  /* ——— step 3: details & provenance ——— */

  function detailsErrors() {
    const d = S.details;
    const errs = [];
    if (!d.title.trim()) errs.push("Title is required.");
    else if (d.title.length > 200) errs.push("Title is too long (max 200).");
    if (d.author.length > 200) errs.push("Author is too long (max 200).");
    if (d.description.length > 4000) errs.push("Description is too long (max 4000).");
    if (d.language.length > 10) errs.push("Language is too long (max 10, e.g. “en”).");
    if (!CATEGORIES.includes(d.category)) errs.push("Pick a category.");
    const tags = d.tags
      .split(",")
      .map((t) => t.trim())
      .filter(Boolean);
    if (tags.length > 10) errs.push("Too many tags (max 10).");
    if (tags.some((t) => t.length > 40)) errs.push("Tags are too long (max 40 each).");
    if (!GENERATIONS.includes(d.generation)) errs.push("Pick a generation method.");
    if (d.narrationEngine.length > 120) errs.push("Narration engine is too long (max 120).");
    const models = d.models
      .split(",")
      .map((t) => t.trim())
      .filter(Boolean);
    if (models.length > 10) errs.push("Too many models (max 10).");
    if (models.some((t) => t.length > 120)) errs.push("Model names are too long (max 120 each).");
    if (d.pipelineNotes.length > 2000) errs.push("Pipeline notes are too long (max 2000).");
    if (d.sourceTitle.length > 300) errs.push("Source title is too long (max 300).");
    if (d.sourceUrl.length > 300) errs.push("Source URL is too long (max 300).");
    if (!LICENSES.includes(d.license)) errs.push("Pick a license.");
    if (d.licenseUrl.length > 300) errs.push("License URL is too long (max 300).");
    return errs;
  }

  function bindText(input, key) {
    input.addEventListener("input", () => {
      S.details[key] = input.value;
      persist();
      refresh();
    });
  }

  function bindSelect(sel, key) {
    sel.addEventListener("change", () => {
      S.details[key] = sel.value;
      persist();
      refresh();
    });
  }

  function renderStepDetails() {
    bodyEl.replaceChildren();
    const d = S.details;
    const errs = h("div", { class: "stack" });

    const titleI = h("input", { class: "input", type: "text", value: d.title, "aria-label": "Title" });
    const authorI = h("input", { class: "input", type: "text", value: d.author, "aria-label": "Author" });
    const descI = h("textarea", { class: "textarea", value: d.description, "aria-label": "Description" });
    const langI = h("input", {
      class: "input",
      type: "text",
      value: d.language,
      placeholder: "en",
      "aria-label": "Language code",
    });
    const catS = h(
      "select",
      { class: "select", "aria-label": "Category" },
      h("option", { value: "" }, "Choose…"),
      ...CATEGORIES.map((c) =>
        h("option", { value: c, selected: d.category === c ? true : null }, c),
      ),
    );
    const tagsI = h("input", {
      class: "input",
      type: "text",
      value: d.tags,
      placeholder: "classic, novel, adventure",
      "aria-label": "Tags, comma separated",
    });
    const genS = h(
      "select",
      { class: "select", "aria-label": "Generation method" },
      ...GENERATIONS.map((g) =>
        h("option", { value: g, selected: d.generation === g ? true : null }, g),
      ),
    );
    const engineI = h("input", {
      class: "input",
      type: "text",
      value: d.narrationEngine,
      placeholder: "e.g. Firebrat TTS",
      "aria-label": "Narration engine",
    });
    const modelsI = h("input", {
      class: "input",
      type: "text",
      value: d.models,
      placeholder: "model names, comma separated",
      "aria-label": "Models, comma separated",
    });
    const notesI = h("textarea", {
      class: "textarea",
      value: d.pipelineNotes,
      "aria-label": "Pipeline notes",
    });
    const srcTitleI = h("input", { class: "input", type: "text", value: d.sourceTitle, "aria-label": "Source work title" });
    const srcUrlI = h("input", { class: "input", type: "url", value: d.sourceUrl, "aria-label": "Source work URL" });
    const licS = h(
      "select",
      { class: "select", "aria-label": "License" },
      h("option", { value: "" }, "Choose…"),
      ...LICENSES.map((l) =>
        h("option", { value: l, selected: d.license === l ? true : null }, l),
      ),
    );
    const licUrlI = h("input", { class: "input", type: "url", value: d.licenseUrl, "aria-label": "License URL" });

    bindText(titleI, "title");
    bindText(authorI, "author");
    bindText(descI, "description");
    bindText(langI, "language");
    bindSelect(catS, "category");
    bindText(tagsI, "tags");
    bindSelect(genS, "generation");
    bindText(engineI, "narrationEngine");
    bindText(modelsI, "models");
    bindText(notesI, "pipelineNotes");
    bindText(srcTitleI, "sourceTitle");
    bindText(srcUrlI, "sourceUrl");
    bindSelect(licS, "license");
    bindText(licUrlI, "licenseUrl");

    bodyEl.append(
      h("h2", {}, "Details"),
      field("Title", titleI),
      field("Author", authorI, "Original author of the text, if known."),
      field("Description", descI, "Up to 4000 characters. What is this book about?"),
      h(
        "div",
        { class: "form-row" },
        field("Language", langI, "Short code, e.g. “en”."),
        field("Category", catS),
      ),
      field("Tags", tagsI, "Comma separated, up to 10."),
      h("h2", {}, "How the audio was made"),
      h(
        "div",
        { class: "form-row" },
        field("Generation method", genS, "Firebrat TTS, human-narrated, mixed, or other."),
        field("Narration engine", engineI, "TTS engine or recording setup."),
      ),
      field("Models", modelsI, "Comma separated model names, if any."),
      field("Pipeline notes", notesI, "Anything listeners should know about how this was produced."),
      h("h2", {}, "Source work & license"),
      h(
        "p",
        { class: "hint" },
        "Only copyright-free works: public domain in the US, CC0, CC-BY, or CC-BY-SA. If you are not sure the text qualifies, do not submit it.",
      ),
      field("Source work title", srcTitleI, "The book or text this audio was made from."),
      field("Source work URL", srcUrlI, "Where the source text can be found (e.g. Project Gutenberg)."),
      h(
        "div",
        { class: "form-row" },
        field("License", licS),
        field("License URL", licUrlI),
      ),
      errs,
    );

    const problems = detailsErrors();
    if (S.details.title || problems.length) {
      errs.append(...problems.map((p) => h("p", { class: "error-text small" }, p)));
    }
  }

  /* ——— step 4: review & publish ——— */

  function renderStepReview() {
    bodyEl.replaceChildren();
    const d = S.details;
    const totals = chapterTotals();
    const rows = [
      ["Title", d.title || "—"],
      ["Author", d.author || "—"],
      ["Archive", S.archiveId ? `https://archive.org/details/${S.archiveId}` : "—"],
      ["Package", S.packageKind === "zip" ? `zip${S.zipName ? ` (${S.zipName})` : ""}` : "folder"],
      ["Sections", String(totals.count)],
      ["Duration", formatDuration(totals.durationMs)],
      ["Category", d.category || "—"],
      ["License", d.license || "—"],
      ["Generation", d.generation || "—"],
    ];
    const checkOwn = h("input", {
      type: "checkbox",
      checked: S.attestOwn ? true : null,
      "aria-label": "I created this audio or have permission",
    });
    const checkSource = h("input", {
      type: "checkbox",
      checked: S.attestSource ? true : null,
      "aria-label": "The source text is public domain or openly licensed",
    });
    checkOwn.addEventListener("change", () => {
      S.attestOwn = checkOwn.checked;
      publishBtn.disabled = !(S.attestOwn && S.attestSource) || publishing;
    });
    checkSource.addEventListener("change", () => {
      S.attestSource = checkSource.checked;
      publishBtn.disabled = !(S.attestOwn && S.attestSource) || publishing;
    });

    let publishing = false;
    const pubErr = errEl();
    pubErr.classList.add("hidden");
    const publishBtn = h(
      "button",
      { class: "btn btn-primary", disabled: true },
      "Publish listing",
    );
    publishBtn.onclick = async () => {
      if (!(S.attestOwn && S.attestSource)) return;
      publishing = true;
      publishBtn.disabled = true;
      setErr(pubErr, "");
      try {
        const tags = d.tags
          .split(",")
          .map((t) => t.trim())
          .filter(Boolean)
          .slice(0, 10);
        const models = d.models
          .split(",")
          .map((t) => t.trim())
          .filter(Boolean)
          .slice(0, 10);
        const sectionCount = totals.count;
        const manifestMs = Number(S.manifest?.total_duration_ms);
        const summedMs = Array.isArray(S.chapters)
          ? S.chapters.reduce((a, c) => a + (Number.isInteger(c.durationMs) ? c.durationMs : 0), 0)
          : 0;
        const totalDurationMs =
          summedMs > 0
            ? summedMs
            : Number.isFinite(manifestMs) && manifestMs >= 0
              ? Math.floor(manifestMs)
              : 0;
        if (!S.chapters || !S.chapters.length) {
          throw new Error("Chapter list is missing — go back to the package step and pick your local copy again.");
        }
        const chapterCheck = validateChapters(S.chapters);
        if (!chapterCheck.ok) {
          throw new Error(chapterCheck.errors[0] || "Chapter list is invalid.");
        }
        const fields = {
          title: d.title.trim().slice(0, 200),
          author: d.author.trim().slice(0, 200),
          description: d.description.trim().slice(0, 4000),
          language: d.language.trim().slice(0, 10),
          category: d.category,
          tags,
          archiveId: S.archiveId,
          archiveUrl: `https://archive.org/details/${S.archiveId}`,
          packageKind: S.packageKind,
          packageFile: S.packageKind === "zip" ? S.zipName : "",
          chapters: S.chapters,
          sizeBytes: Math.max(0, Math.floor(Number(S.sizeBytes) || 0)),
          sectionCount,
          totalDurationMs,
          provenance: {
            generation: d.generation,
            narrationEngine: d.narrationEngine.trim().slice(0, 120),
            models,
            pipelineNotes: d.pipelineNotes.trim().slice(0, 2000),
            sourceTitle: d.sourceTitle.trim().slice(0, 300),
            sourceUrl: d.sourceUrl.trim().slice(0, 300),
            license: d.license,
            licenseUrl: d.licenseUrl.trim().slice(0, 300),
            attested: true,
          },
        };
        const id = bookIdFor(d.title, S.archiveId);
        await createBook(id, fields);
        clearDraft();
        toast("Published. Thanks for contributing!", { kind: "ok" });
        navigate(`/book/${id}`);
      } catch (e) {
        publishing = false;
        publishBtn.disabled = !(S.attestOwn && S.attestSource);
        setErr(pubErr, e instanceof Error ? e.message : "Publish failed.");
      }
    };

    const takedownLink = h("a", { href: "#/legal/takedown" }, "Takedown policy");
    bodyEl.append(
      h("h2", {}, "Review"),
      h(
        "div",
        { class: "prov-card" },
        h("h3", {}, "Listing summary"),
        h(
          "dl",
          {},
          ...rows.flatMap(([k, val]) => [
            h("div", { class: "prov-row" }, h("dt", {}, k), h("dd", {}, val)),
          ]),
        ),
      ),
      h(
        "label",
        { class: "check-row" },
        checkOwn,
        h(
          "span",
          {},
          "I created this audio or have permission from whoever did, and I have the right to share it.",
        ),
      ),
      h(
        "label",
        { class: "check-row" },
        checkSource,
        h(
          "span",
          {},
          "The source text is public domain or openly licensed as stated above. I understand listings can be removed under the ",
          takedownLink,
          " if a valid complaint is received.",
        ),
      ),
      pubErr,
      h("div", { class: "row" }, publishBtn),
    );
  }

  go(0);
  return root;
}
