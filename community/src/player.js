/* Firebrat Community — audio player + sticky mini-player.
   Contract: playBook(book, sectionIndex), togglePlay(),
   seek(sec), setSpeed(r), current(), onChange(cb), mountMiniPlayer(el).
   - Audio streams from Internet Archive section URLs (zip or folder layout)
     built from book.chapters + ia.itemFileUrl — never fetches manifest.json.
   - Auto-advances sections; Media Session metadata/actions; resume
     position remembered per book in localStorage (try/catch).
   - seek(sec) is ABSOLUTE (clamped); skip buttons use an internal offset.
   - Legacy playBook(book, manifest, loc, sectionIndex) is still accepted
     and mapped onto book.chapters when present. */

import * as ia from "./ia.js";
import { cover, h, toast } from "./ui.js";

const POS_KEY = "firebrat.player.pos.v1";
const SPEED_KEY = "firebrat.player.speed.v1";
const SPEEDS = [1, 1.25, 1.5, 1.75, 2];

const audio = new Audio();
audio.preload = "metadata";

const state = {
  book: null,      // Firestore book doc {id, ...}
  loc: null,       // {kind:'zip'|'folder', zip|base} derived from book
  index: 0,
  playing: false,
  speed: 1,
  time: 0,
  duration: 0,
};

const listeners = new Set();
function emit() { for (const cb of [...listeners]) { try { cb(current()); } catch {} } }

/** Remembered position helpers (safe localStorage). */
function loadPos() {
  try {
    const raw = localStorage.getItem(POS_KEY);
    return raw ? JSON.parse(raw) : {};
  } catch { return {}; }
}
function savePos() {
  try {
    if (!state.book) return;
    const all = loadPos();
    all[state.book.id] = { section: state.index, time: audio.currentTime || 0 };
    localStorage.setItem(POS_KEY, JSON.stringify(all));
  } catch {}
}
function posFor(bookId) {
  const all = loadPos();
  return all[bookId] || null;
}

try {
  const s = parseFloat(localStorage.getItem(SPEED_KEY));
  if (SPEEDS.includes(s)) { state.speed = s; audio.playbackRate = s; }
} catch {}

/** Derive the IA file location from a book doc. Pure. */
export function locFromBook(book) {
  if (book && book.packageKind === "zip" && book.packageFile) {
    return { kind: "zip", zip: book.packageFile };
  }
  return { kind: "folder", base: "" };
}

/** Chapters on a book doc (Firestore `chapters` list). */
export function bookChapters(book) {
  return Array.isArray(book?.chapters) ? book.chapters : [];
}

/** Build a streamable section URL from a book doc + chapter audioPath. */
export function sectionUrl(archiveId, loc, audioPath) {
  return ia.itemFileUrl(archiveId, loc, audioPath);
}

function chapters() {
  return bookChapters(state.book);
}

function applyMediaSession() {
  try {
    if (!("mediaSession" in navigator) || !state.book) return;
    const list = chapters();
    const ch = list[state.index];
    navigator.mediaSession.metadata = new MediaMetadata({
      title: (ch && ch.title) || `Chapter ${state.index + 1}`,
      artist: state.book.author || "Unknown author",
      album: state.book.title || "Firebrat Community",
    });
  } catch {}
}

function loadSection(idx, { autoplay = true, resume = true } = {}) {
  const list = chapters();
  if (!list.length) return false;
  state.index = Math.max(0, Math.min(idx, list.length - 1));
  const ch = list[state.index];
  audio.src = sectionUrl(state.book.archiveId, state.loc, ch.audioPath);
  audio.playbackRate = state.speed;
  // Resume where the listener left off on this book+section.
  if (resume) {
    const saved = posFor(state.book.id);
    if (saved && saved.section === state.index && saved.time > 10) {
      audio.currentTime = saved.time;
    }
  }
  applyMediaSession();
  if (autoplay) audio.play().catch(() => {});
  emit();
  return true;
}

/**
 * Start playing a book. sectionIndex defaults to the remembered position.
 * Legacy form playBook(book, manifest, loc, sectionIndex) is accepted:
 * when the 2nd arg looks like a manifest ({sections}), it is mapped onto
 * book.chapters for this session only.
 */
export function playBook(book, sectionIndexOrManifest, locOrIndex, maybeIndex) {
  let sectionIndex = sectionIndexOrManifest;
  if (
    sectionIndexOrManifest &&
    typeof sectionIndexOrManifest === "object" &&
    Array.isArray(sectionIndexOrManifest.sections)
  ) {
    const manifest = sectionIndexOrManifest;
    const loc = locOrIndex;
    sectionIndex = maybeIndex;
    state.book = {
      ...book,
      packageKind: (loc && loc.kind) || book?.packageKind || "folder",
      packageFile: (loc && loc.zip) || book?.packageFile || "",
      chapters:
        bookChapters(book).length > 0
          ? bookChapters(book)
          : manifest.sections.map((s, i) => ({
              title: s?.title || `Chapter ${i + 1}`,
              durationMs: Number.isFinite(Number(s?.duration_ms)) ? Math.floor(Number(s.duration_ms)) : 0,
              audioPath: s?.audio_path || "",
            })),
    };
  } else {
    state.book = book;
  }
  if (!state.book) return false;
  state.loc = locFromBook(state.book);
  let idx = sectionIndex;
  if (idx == null) {
    const saved = posFor(state.book.id);
    idx = saved ? saved.section : 0;
  }
  return loadSection(idx, { autoplay: true, resume: sectionIndex == null });
}

export async function togglePlay() {
  if (!audio.src) return state.playing;
  try {
    if (audio.paused) await audio.play();
    else audio.pause();
  } catch {}
  return !audio.paused;
}

/** Absolute seek in seconds (clamped to duration when known). */
export function seek(sec) {
  if (!audio.src || sec == null || isNaN(sec)) return;
  const d = audio.duration;
  audio.currentTime = Math.max(0, d && isFinite(d) ? Math.min(sec, d) : sec);
}

/** Relative skip in seconds (used by -15s / +30s buttons). */
export function skipBy(delta) {
  if (!audio.src) return;
  seek((audio.currentTime || 0) + delta);
}

export function setSpeed(r) {
  if (!SPEEDS.includes(r)) return state.speed;
  state.speed = r;
  audio.playbackRate = r;
  try { localStorage.setItem(SPEED_KEY, String(r)); } catch {}
  emit();
  return r;
}

export function cycleSpeed() {
  return setSpeed(SPEEDS[(SPEEDS.indexOf(state.speed) + 1) % SPEEDS.length]);
}

export function nextSection() {
  if (state.index + 1 < chapters().length) loadSection(state.index + 1, { resume: false });
}
export function prevSection() {
  if (audio.currentTime > 5) { seek(0); return; }
  if (state.index > 0) loadSection(state.index - 1, { resume: false });
}

export function current() {
  const list = chapters();
  const ch = list[state.index] || null;
  // Keep `manifest` (null) + a manifest-shaped `section` alias so older
  // callers that read section.audio_path / duration_ms keep working.
  return {
    book: state.book,
    manifest: null,
    chapters: list,
    sectionIndex: state.index,
    section: ch
      ? { ...ch, audio_path: ch.audioPath, duration_ms: ch.durationMs }
      : null,
    sectionCount: list.length,
    time: audio.currentTime || 0,
    duration: audio.duration && isFinite(audio.duration) ? audio.duration : 0,
    playing: !audio.paused && !!audio.src,
    speed: state.speed,
  };
}

/** Subscribe to player changes. Returns unsubscribe. */
export function onChange(cb) {
  listeners.add(cb);
  return () => listeners.delete(cb);
}

/* ——— audio element events ——— */
audio.addEventListener("play", () => { state.playing = true; emit(); });
audio.addEventListener("pause", () => { state.playing = false; savePos(); emit(); });
audio.addEventListener("ended", () => {
  savePos();
  if (state.index + 1 < chapters().length) loadSection(state.index + 1, { resume: false });
  else { state.playing = false; emit(); }
});
audio.addEventListener("error", () => {
  try {
    toast("Audio unavailable — the Archive item may be darked or removed.", { kind: "err" });
  } catch {}
  state.playing = false;
  emit();
});
audio.addEventListener("timeupdate", () => {
  state.time = audio.currentTime || 0;
  for (const cb of [...listeners]) { try { cb(current()); } catch {} }
});
let saveTick = 0;
audio.addEventListener("timeupdate", () => {
  const now = Date.now();
  if (now - saveTick > 5000) { saveTick = now; savePos(); }
});
audio.addEventListener("loadedmetadata", () => { state.duration = audio.duration || 0; emit(); });

try {
  if ("mediaSession" in navigator) {
    navigator.mediaSession.setActionHandler("play", () => audio.play().catch(() => {}));
    navigator.mediaSession.setActionHandler("pause", () => audio.pause());
    navigator.mediaSession.setActionHandler("previoustrack", () => prevSection());
    navigator.mediaSession.setActionHandler("nexttrack", () => nextSection());
    navigator.mediaSession.setActionHandler("seekbackward", () => skipBy(-15));
    navigator.mediaSession.setActionHandler("seekforward", () => skipBy(30));
  }
} catch {}

/* ——— mini player ——— */
function fmt(sec) {
  if (sec == null || isNaN(sec) || !isFinite(sec)) return "0:00";
  const s = Math.floor(sec);
  const m = Math.floor(s / 60);
  const r = s % 60;
  const hh = Math.floor(m / 60);
  return hh ? `${hh}:${String(m % 60).padStart(2, "0")}:${String(r).padStart(2, "0")}` : `${m}:${String(r).padStart(2, "0")}`;
}

export function mountMiniPlayer(el) {
  el.className = "mini-player";
  el.setAttribute("hidden", "");
  el.setAttribute("role", "region");
  el.setAttribute("aria-label", "Audio player");

  const bar = h("div", { class: "mp-bar" });
  const progress = h("div", {
    class: "mp-progress", role: "slider", tabindex: "0",
    "aria-label": "Seek", "aria-valuemin": "0", "aria-valuemax": "100", "aria-valuenow": "0",
  }, bar);
  const coverSlot = h("div", { class: "mp-cover-slot", style: "display:flex" });
  const titleEl = h("div", { class: "mp-title" }, "Nothing playing");
  const subEl = h("div", { class: "mp-sub" }, "Pick a book to listen");
  const timeEl = h("div", { class: "mp-time" }, "0:00 / 0:00");
  const playBtn = h("button", { class: "mp-play", "aria-label": "Play or pause" }, "▶");

  const backBtn = h("button", { class: "icon-btn mp-skip", "aria-label": "Back 15 seconds" }, "−15");
  const fwdBtn = h("button", { class: "icon-btn mp-skip", "aria-label": "Forward 30 seconds" }, "+30");
  const speedBtn = h("button", { class: "icon-btn mp-skip mp-speed", "aria-label": "Playback speed" }, "1×");
  const controls = h("div", { class: "mp-controls" }, backBtn, playBtn, fwdBtn, speedBtn);
  const text = h("div", { class: "mp-text" }, titleEl, subEl);
  const inner = h("div", { class: "mp-inner" }, coverSlot, text, timeEl, controls);
  el.append(progress, inner);

  playBtn.onclick = () => togglePlay();
  backBtn.onclick = () => skipBy(-15);
  fwdBtn.onclick = () => skipBy(30);
  speedBtn.onclick = () => cycleSpeed();

  const doSeek = (clientX) => {
    const r = progress.getBoundingClientRect();
    const frac = Math.max(0, Math.min(1, (clientX - r.left) / Math.max(1, r.width)));
    const d = audio.duration;
    if (d && isFinite(d)) seek(frac * d);
  };
  progress.addEventListener("click", (e) => doSeek(e.clientX));
  progress.addEventListener("keydown", (e) => {
    if (e.key === "ArrowLeft") { skipBy(-5); e.preventDefault(); }
    if (e.key === "ArrowRight") { skipBy(5); e.preventDefault(); }
  });

  let lastCoverFor = "";
  onChange((snap) => {
    if (!snap.book) { el.setAttribute("hidden", ""); return; }
    el.removeAttribute("hidden");
    const list = snap.chapters || [];
    const ch = list[snap.sectionIndex];
    const chap = ch ? ch.title || `Chapter ${snap.sectionIndex + 1}` : "";
    titleEl.textContent = chap;
    subEl.textContent = `${snap.book.title || ""} · ${snap.sectionIndex + 1}/${list.length || "?"}`;
    timeEl.textContent = `${fmt(snap.time)} / ${fmt(snap.duration)}`;
    playBtn.textContent = snap.playing ? "⏸" : "▶";
    playBtn.setAttribute("aria-label", snap.playing ? "Pause" : "Play");
    speedBtn.textContent = `${snap.speed}×`;
    const pct = snap.duration ? (snap.time / snap.duration) * 100 : 0;
    bar.style.width = `${Math.max(0, Math.min(100, pct))}%`;
    progress.setAttribute("aria-valuenow", String(Math.round(pct)));
    progress.setAttribute("aria-valuetext", `${fmt(snap.time)} of ${fmt(snap.duration)}`);
    if (snap.book.id !== lastCoverFor) {
      lastCoverFor = snap.book.id;
      coverSlot.replaceChildren(cover(snap.book, { size: "mp" }));
    }
  });
}
