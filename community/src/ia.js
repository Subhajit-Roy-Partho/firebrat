// Pure Internet Archive helpers (+ thin fetch wrappers). No Firebase here.
// Keys passed to uploadToArchive are kept in memory only, never logged/stored.

export const IA_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{2,99}$/;
const ARCHIVE_HOSTS = new Set(["archive.org", "www.archive.org"]);

/** Lowercase safe slug; caller appends a random suffix for IA identifiers. */
export function slugify(s) {
  return String(s ?? "")
    .normalize("NFKD")
    .replace(/[\u0300-\u036f]/g, "")
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/-{2,}/g, "-")
    .slice(0, 80)
    .replace(/-+$/, "");
}

/**
 * Extract IA identifier from details/download/embed URLs. Returns id or null.
 * Rejects non-archive.org hosts and malformed identifiers.
 */
export function parseArchiveUrl(str) {
  if (!str || typeof str !== "string") return null;
  let input = str.trim();
  if (!input) return null;
  if (!/^[a-z][a-z0-9+.-]*:\/\//i.test(input)) input = "https://" + input;
  let url;
  try {
    url = new URL(input);
  } catch {
    return null;
  }
  if (!ARCHIVE_HOSTS.has(url.hostname.toLowerCase())) return null;
  const parts = url.pathname.split("/").filter(Boolean);
  // details/<id> | download/<id>[/...] | embed/<id>[...]
  if (parts.length < 2) return null;
  const [kind, raw, ...rest] = parts;
  if (!["details", "download", "embed"].includes(kind)) return null;
  // "download/<id>/<zip>/<inner>" — id is still the first segment
  void rest;
  let id;
  try {
    id = decodeURIComponent(raw);
  } catch {
    return null;
  }
  return IA_ID_RE.test(id) ? id : null;
}

function fileName(entry) {
  if (!entry) return "";
  const n = typeof entry === "string" ? entry : entry.name;
  return String(n ?? "").replace(/^\.\//, "").replace(/^\/+/, "");
}

/**
 * Find the book package inside an IA item file list.
 * Returns {kind:'folder', base:''} when root manifest.json exists,
 * else {kind:'zip', zip:<name>} for the first .zip, else null.
 */
export function locatePackage(files) {
  if (!Array.isArray(files) || !files.length) return null;
  const names = files.map(fileName).filter(Boolean);
  if (names.some((n) => n === "manifest.json")) {
    return { kind: "folder", base: "" };
  }
  const zip = names.find((n) => !n.endsWith("/") && n.toLowerCase().endsWith(".zip"));
  return zip ? { kind: "zip", zip } : null;
}

const encPath = (p) =>
  String(p)
    .split("/")
    .map((s) => encodeURIComponent(s))
    .join("/");

/** Public file URL inside an IA item (zip-inner or folder path). Pure. */
export function itemFileUrl(id, loc, innerPath) {
  if (!IA_ID_RE.test(String(id))) throw new Error("Invalid archive identifier.");
  const inner = String(innerPath ?? "").replace(/^\/+/, "");
  if (!inner) throw new Error("Missing file path.");
  if (loc && loc.kind === "zip") {
    if (!loc.zip) throw new Error("Zip package has no file name.");
    return `https://archive.org/download/${encodeURIComponent(id)}/${encPath(loc.zip)}/${encPath(inner)}`;
  }
  return `https://archive.org/download/${encodeURIComponent(id)}/${encPath(inner)}`;
}

/** Cover image URL for a listing (the package's own cover.<ext>), or null when it has no Archive item. Pure. */
export function coverUrl(book, ext = "jpg") {
  if (!book || !book.archiveId) return null;
  const loc = book.packageKind === "zip" && book.packageFile ? { kind: "zip", zip: book.packageFile } : { kind: "folder", base: "" };
  try {
    return itemFileUrl(book.archiveId, loc, `cover.${ext}`);
  } catch {
    return null;
  }
}

/** Download URL for the whole package. Pure. */
export function downloadUrl(id, loc) {
  if (!IA_ID_RE.test(String(id))) throw new Error("Invalid archive identifier.");
  if (loc && loc.kind === "zip" && loc.zip) {
    return `https://archive.org/download/${encodeURIComponent(id)}/${encPath(loc.zip)}`;
  }
  return `https://archive.org/compress/${encodeURIComponent(id)}`;
}

/**
 * Validate a book manifest. Pure.
 * Returns {ok, errors[], summary:{title,author,sectionCount,durationMs,engine}}.
 */
export function validateManifest(m) {
  const errors = [];
  if (!m || typeof m !== "object" || Array.isArray(m)) {
    return { ok: false, errors: ["Manifest is not an object."], summary: emptySummary() };
  }
  if (m.schema_version !== "1.0") errors.push("schema_version must be \"1.0\".");
  if (!m.book_id || typeof m.book_id !== "string") errors.push("Missing book_id.");
  if (!m.title || typeof m.title !== "string") errors.push("Missing title.");
  if (!Array.isArray(m.sections) || m.sections.length === 0) {
    errors.push("sections must be a non-empty array.");
  } else {
    m.sections.forEach((s, i) => {
      if (!s || typeof s !== "object") {
        errors.push(`sections[${i}] is not an object.`);
        return;
      }
      if (!s.audio_path || typeof s.audio_path !== "string") {
        errors.push(`sections[${i}] is missing audio_path.`);
      }
      if (!s.segments_path || typeof s.segments_path !== "string") {
        errors.push(`sections[${i}] is missing segments_path.`);
      }
    });
  }
  return { ok: errors.length === 0, errors, summary: summarize(m) };
}

function emptySummary() {
  return { title: "", author: "", sectionCount: 0, durationMs: 0, engine: "" };
}

function summarize(m) {
  const sections = Array.isArray(m?.sections) ? m.sections.length : 0;
  const durationMs = Number(m?.total_duration_ms);
  return {
    title: typeof m?.title === "string" ? m.title : "",
    author: typeof m?.author === "string" ? m.author : "",
    sectionCount: sections,
    durationMs: Number.isFinite(durationMs) && durationMs >= 0 ? durationMs : 0,
    engine: String(m?.narrator_voice?.engine ?? m?.narrator_voice?.model_class ?? ""),
  };
}

/** GET https://archive.org/metadata/<id>; returns the item file list. */
export async function fetchItem(id, fetchFn = fetch) {
  if (!IA_ID_RE.test(String(id))) throw new Error("Invalid archive identifier.");
  const res = await fetchFn(`https://archive.org/metadata/${encodeURIComponent(id)}`);
  if (!res.ok) throw new Error(`Internet Archive lookup failed (${res.status}).`);
  const data = await res.json();
  return Array.isArray(data?.files) ? data.files : [];
}

/** Fetch + validate the book manifest for an IA item.
 * Best-effort only: archive.org /download/... does NOT send CORS headers,
 * so browsers cannot fetch() manifest.json from IA. Submit-time code must
 * read the manifest from the user's LOCAL file instead and never block on
 * this helper. Kept for scripts/diagnostics only. */
export async function fetchManifest(id, fetchFn = fetch) {
  const files = await fetchItem(id, fetchFn);
  const loc = locatePackage(files);
  if (!loc) throw new Error("No book package found: expected manifest.json or a .zip file.");
  const url = itemFileUrl(id, loc, "manifest.json");
  const res = await fetchFn(url);
  if (!res.ok) throw new Error(`manifest.json could not be read (${res.status}).`);
  const manifest = await res.json();
  const validation = validateManifest(manifest);
  if (!validation.ok) throw new Error(`Invalid manifest: ${validation.errors[0]}`);
  return { id, loc, manifest, validation };
}

/**
 * Upload one file to IA's S3 API. Browser-only (uses XHR for progress).
 * Keys stay in memory only — never logged, persisted, or sent to Firebase.
 * On CORS/network failure the caller should show manual-upload instructions.
 */
export function uploadToArchive({ file, identifier, meta = {}, accessKey, secretKey, onProgress, signal }) {
  return new Promise((resolve, reject) => {
    if (typeof XMLHttpRequest === "undefined") {
      reject(new Error("Uploads need a browser with XMLHttpRequest."));
      return;
    }
    if (!file) return reject(new Error("Choose a file to upload."));
    if (!IA_ID_RE.test(String(identifier ?? ""))) return reject(new Error("Invalid archive identifier."));
    if (!accessKey || !secretKey) return reject(new Error("Enter your Internet Archive S3 keys."));
    const name = file.name || meta.filename || "package.zip";
    const url = `https://s3.us.archive.org/${encodeURIComponent(identifier)}/${encPath(name)}`;
    const xhr = new XMLHttpRequest();
    if (signal) {
      if (signal.aborted) return reject(new DOMException("Aborted", "AbortError"));
      signal.addEventListener("abort", () => xhr.abort(), { once: true });
    }
    xhr.open("PUT", url);
    // IA S3 auth + auto-make-bucket. Secret is used here only, never stored.
    xhr.setRequestHeader("authorization", `LOW ${accessKey}:${secretKey}`);
    xhr.setRequestHeader("x-archive-auto-make-bucket", "1");
    xhr.setRequestHeader("x-archive-meta01-collection", meta.collection || "opensource_audio");
    xhr.setRequestHeader("x-archive-mediatype", meta.mediatype || "audio");
    if (meta.title) xhr.setRequestHeader("x-archive-meta01-title", meta.title);
    if (meta.creator) xhr.setRequestHeader("x-archive-meta01-creator", meta.creator);
    if (meta.description) xhr.setRequestHeader("x-archive-meta01-description", meta.description);
    if (meta.license) xhr.setRequestHeader("x-archive-meta01-license", meta.license);
    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable && typeof onProgress === "function") onProgress(e.loaded / e.total);
    };
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        resolve({ identifier, url: `https://archive.org/details/${identifier}` });
      } else if (xhr.status === 0) {
        reject(
          new Error(
            "Upload was blocked (network/CORS). See manual steps at https://archive.org/upload instead.",
          ),
        );
      } else {
        reject(new Error(`Upload failed (${xhr.status}). Check your keys and retry.`));
      }
    };
    xhr.onerror = () =>
      reject(
        new Error(
          "Upload was interrupted. See manual steps at https://archive.org/upload instead.",
        ),
      );
    xhr.onabort = () => reject(new DOMException("Aborted", "AbortError"));
    xhr.send(file);
  });
}

/** Maximum chapters stored on a book doc (rules-enforced size only). */
export const MAX_CHAPTERS = 1500;

function chapterDurationMs(s) {
  const raw = Number(s?.duration_ms ?? s?.durationMs ?? 0);
  if (!Number.isFinite(raw) || raw < 0) return 0;
  return Math.floor(raw);
}

/**
 * Build the Firestore `chapters` list from a validated package manifest.
 * Sorts sections by numeric `order` (stable for missing/order-less sections)
 * and maps to {title (<=200 chars), durationMs (int), audioPath}.
 * Pure. Does NOT enforce the 1500 cap — see validateChapters.
 */
export function buildChapters(manifest) {
  const sections = Array.isArray(manifest?.sections) ? [...manifest.sections] : [];
  sections.sort((a, b) => {
    const ao = Number(a?.order);
    const bo = Number(b?.order);
    const aFin = Number.isFinite(ao);
    const bFin = Number.isFinite(bo);
    if (aFin && bFin && ao !== bo) return ao - bo;
    if (aFin && !bFin) return -1;
    if (!aFin && bFin) return 1;
    return 0;
  });
  return sections.map((s, i) => ({
    title: String(s?.title ?? `Chapter ${i + 1}`).slice(0, 200) || `Chapter ${i + 1}`,
    durationMs: chapterDurationMs(s),
    audioPath: String(s?.audio_path ?? s?.audioPath ?? ""),
  }));
}

/**
 * Validate a Firestore `chapters` list. Pure.
 * Returns {ok, errors[]}. Enforces 1..1500 items per firestore.rules.
 */
export function validateChapters(chapters) {
  const errors = [];
  if (!Array.isArray(chapters) || chapters.length === 0) {
    return { ok: false, errors: ["Chapter list is empty."] };
  }
  if (chapters.length > MAX_CHAPTERS) {
    return {
      ok: false,
      errors: [
        `Package too large: ${chapters.length} chapters (max ${MAX_CHAPTERS}). Split the audiobook to submit it.`,
      ],
    };
  }
  chapters.forEach((c, i) => {
    if (!c || typeof c !== "object") {
      errors.push(`chapters[${i}] is not an object.`);
      return;
    }
    if (typeof c.title !== "string" || !c.title) {
      errors.push(`chapters[${i}] is missing a title.`);
    } else if (c.title.length > 200) {
      errors.push(`chapters[${i}].title is too long (max 200).`);
    }
    if (!Number.isInteger(c.durationMs) || c.durationMs < 0) {
      errors.push(`chapters[${i}].durationMs must be a non-negative integer.`);
    }
    if (typeof c.audioPath !== "string" || !c.audioPath) {
      errors.push(`chapters[${i}] is missing audioPath.`);
    }
  });
  return { ok: errors.length === 0, errors };
}
