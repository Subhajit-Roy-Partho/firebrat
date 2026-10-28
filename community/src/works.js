// Pure helpers that group several uploads of the same book ("editions") under one work.
// No Firebase / DOM here so they can be unit-tested with `node --test`.

/** Average star rating (0 when unrated). */
export function avgRating(b) {
  return b && b.ratingCount > 0 ? b.ratingSum / b.ratingCount : 0;
}

/** createdAt may be a Firestore Timestamp, a Date, a number or missing. */
export function createdMs(b) {
  const t = b && b.createdAt;
  if (!t) return 0;
  if (typeof t.toMillis === "function") return t.toMillis();
  if (t instanceof Date) return t.getTime();
  return Number(t) || 0;
}

const fold = (s) =>
  String(s ?? "")
    .normalize("NFKD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase();

/** "Frankenstein; or, The Modern Prometheus" -> "frankenstein"; "The Time Machine" -> "time-machine". */
export function titleKey(title) {
  let t = fold(title).replace(/\([^)]*\)/g, " ");
  t = t.split(/\s[-–—]\s|[;:]/)[0]; // drop subtitles
  t = t.replace(/['’]/g, ""); // alice's -> alices
  t = t.replace(/[^a-z0-9]+/g, " ").trim();
  t = t.replace(/^(the|a|an) /, "");
  return t.replace(/ /g, "-");
}

/** Surname only: "Mary Wollstonecraft Shelley" and "Shelley, Mary" -> "shelley". */
export function authorKey(author) {
  const a = fold(author).trim();
  if (!a) return "";
  const surname = a.includes(",") ? a.split(",")[0] : a.split(/\s+/).pop();
  return surname.replace(/[^a-z]+/g, "");
}

/** Two uploads share a work when title (minus subtitle/article) and author surname match. */
export function workKey(book) {
  const t = titleKey(book && book.title);
  return t ? `${t}|${authorKey(book && book.author)}` : "";
}

/** Best first: higher average, then more ratings, then newer. */
export function compareEditions(a, b) {
  return avgRating(b) - avgRating(a) || (b.ratingCount ?? 0) - (a.ratingCount ?? 0) || createdMs(b) - createdMs(a);
}

export const SORTS = [
  ["top", "Highest rated"],
  ["new", "Newest"],
  ["most", "Most ratings"],
  ["long", "Longest"],
  ["title", "Title A–Z"],
];

/**
 * Group books into works. Editions inside a work are always best-rated first;
 * works are then ordered by `sort` (top | new | most | long | title).
 * Books without a usable title stay as their own work.
 */
export function groupBooks(items, sort = "top") {
  const map = new Map();
  for (const b of items) {
    const key = workKey(b) || `id:${b.id}`;
    if (!map.has(key)) map.set(key, { key, editions: [] });
    map.get(key).editions.push(b);
  }
  const works = [...map.values()];
  for (const w of works) {
    w.editions.sort(compareEditions);
    w.best = w.editions[0];
    w.title = w.best.title || "Untitled";
    w.author = w.best.author || "";
    w.ratingCount = w.editions.reduce((n, e) => n + (e.ratingCount ?? 0), 0);
    w.newest = Math.max(...w.editions.map(createdMs));
    w.longest = Math.max(...w.editions.map((e) => e.totalDurationMs ?? 0));
  }
  const byTitle = (a, b) => a.title.localeCompare(b.title, "en", { sensitivity: "base" });
  const order = {
    top: (a, b) => compareEditions(a.best, b.best) || byTitle(a, b),
    new: (a, b) => b.newest - a.newest || byTitle(a, b),
    most: (a, b) => b.ratingCount - a.ratingCount || compareEditions(a.best, b.best) || byTitle(a, b),
    long: (a, b) => b.longest - a.longest || byTitle(a, b),
    title: byTitle,
  };
  return works.sort(order[sort] || order.top);
}
