// All Firestore reads/writes for the Community library.
// Field names match firebase/firestore.rules exactly — do not rename.
import {
  collection,
  doc,
  getDoc,
  getDocs,
  addDoc,
  setDoc,
  deleteDoc,
  updateDoc,
  query,
  where,
  orderBy,
  limit as qLimit,
  startAfter,
  serverTimestamp,
  writeBatch,
  increment,
} from "firebase/firestore";
import { auth, db } from "./firebase.js";

const BOOKS = "books";

function friendly(err) {
  const code = err?.code ?? "";
  if (code === "permission-denied") {
    return new Error(
      auth.currentUser ? "Not allowed for this item." : "You need to sign in.",
    );
  }
  if (code === "unauthenticated") return new Error("You need to sign in.");
  if (code === "not-found") return new Error("Item not found.");
  return err instanceof Error ? err : new Error("Something went wrong.");
}

const needUser = () => {
  const u = auth.currentUser;
  if (!u) throw new Error("You need to sign in.");
  return u;
};

const BOOK_ID_RE = /^[a-z0-9][a-z0-9-]{2,99}$/;

/**
 * List books with optional filters. Search/sort-top are client-side over the
 * fetched page (server orders by createdAt desc for 'new').
 * Returns {items:[{id,...doc}], cursor} — pass cursor as `after` for next page.
 */
export async function listBooks({
  category,
  language,
  license,
  sort = "new",
  search = "",
  after = null,
  limit = 24,
} = {}) {
  try {
    const clauses = [];
    if (category) clauses.push(where("category", "==", category));
    if (language) clauses.push(where("language", "==", language));
    if (license) clauses.push(where("provenance.license", "==", license));
    // Rules allow public reads only for published/disputed; keep the
    // query to published so indexes stay simple and guests see the library.
    clauses.push(where("status", "==", "published"));
    clauses.push(orderBy("createdAt", "desc"));
    if (after) clauses.push(startAfter(after));
    clauses.push(qLimit(Math.min(Math.max(limit, 1), 100)));
    const snap = await getDocs(query(collection(db, BOOKS), ...clauses));
    let items = snap.docs.map((d) => ({ id: d.id, ...d.data() }));
    const q = search.trim().toLowerCase();
    if (q) {
      items = items.filter((b) =>
        [b.title, b.author, b.description, ...(b.tags ?? [])]
          .filter(Boolean)
          .join(" ")
          .toLowerCase()
          .includes(q),
      );
    }
    if (sort === "top") {
      items = [...items].sort((a, b) => avg(b) - avg(a));
    } else if (sort === "long") {
      items = [...items].sort((a, b) => (b.totalDurationMs ?? 0) - (a.totalDurationMs ?? 0));
    }
    const cursor = snap.docs.length ? snap.docs[snap.docs.length - 1] : null;
    return { items, cursor };
  } catch (e) {
    throw friendly(e);
  }
}

const avg = (b) => (b.ratingCount > 0 ? b.ratingSum / b.ratingCount : 0);

export async function getBook(id) {
  try {
    const snap = await getDoc(doc(db, BOOKS, id));
    if (!snap.exists()) throw new Error("Book not found.");
    return { id: snap.id, ...snap.data() };
  } catch (e) {
    throw friendly(e);
  }
}

/** Create a books/{bookId} doc. bookId must match [a-z0-9][a-z0-9-]{2,99}. */
export async function createBook(id, fields) {
  try {
    const u = needUser();
    if (!BOOK_ID_RE.test(String(id))) throw new Error("Invalid book id.");
    const ref = doc(db, BOOKS, id);
    const existing = await getDoc(ref);
    if (existing.exists()) throw new Error("A book with this id already exists.");
    const batch = writeBatch(db);
    batch.set(ref, {
      ...fields,
      submitterUid: u.uid,
      submitterName: (u.displayName ?? "").slice(0, 80),
      status: "published",
      ratingSum: 0,
      ratingCount: 0,
      commentCount: 0,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    });
    // Ledger: user -> upload -> Internet Archive link (mirrors the book doc; rules enforce it).
    batch.set(doc(db, "users", u.uid, "uploads", id), {
      bookId: id,
      title: fields.title,
      archiveId: fields.archiveId,
      archiveUrl: fields.archiveUrl,
      uploadedAt: serverTimestamp(),
    });
    await batch.commit();
    return id;
  } catch (e) {
    throw friendly(e);
  }
}

export async function getMyRating(bookId) {
  const u = auth.currentUser;
  if (!u) return null;
  try {
    const snap = await getDoc(doc(db, BOOKS, bookId, "ratings", u.uid));
    return snap.exists() ? snap.data().value : null;
  } catch (e) {
    throw friendly(e);
  }
}

/** Batch: rating doc + book aggregate (rules verify the deltas). */
export async function rateBook(bookId, value) {
  try {
    const u = needUser();
    const v = Number(value);
    if (!Number.isInteger(v) || v < 1 || v > 5) throw new Error("Rating must be 1–5 stars.");
    const bookRef = doc(db, BOOKS, bookId);
    const ratingRef = doc(db, BOOKS, bookId, "ratings", u.uid);
    const [bookSnap, prevSnap] = await Promise.all([getDoc(bookRef), getDoc(ratingRef)]);
    if (!bookSnap.exists()) throw new Error("Book not found.");
    const prev = prevSnap.exists() ? prevSnap.data().value : 0;
    const isNew = !prevSnap.exists();
    const batch = writeBatch(db);
    batch.set(ratingRef, { value: v, updatedAt: serverTimestamp() });
    batch.update(bookRef, {
      ratingSum: increment(v - prev),
      ratingCount: increment(isNew ? 1 : 0),
    });
    await batch.commit();
  } catch (e) {
    throw friendly(e);
  }
}

export async function listComments(bookId, { after = null, limit = 20 } = {}) {
  try {
    // Rules only expose visible comments to non-admins, so the query must say so.
    const clauses = [where("status", "==", "visible"), orderBy("createdAt", "desc")];
    if (after) clauses.push(startAfter(after));
    clauses.push(qLimit(Math.min(Math.max(limit, 1), 100)));
    const snap = await getDocs(query(collection(db, BOOKS, bookId, "comments"), ...clauses));
    const items = snap.docs.map((d) => ({ id: d.id, ...d.data() }));
    const cursor = snap.docs.length ? snap.docs[snap.docs.length - 1] : null;
    return { items, cursor };
  } catch (e) {
    throw friendly(e);
  }
}

/** Batch: comment doc + commentCount+1. */
export async function addComment(bookId, text) {
  try {
    const u = needUser();
    const clean = String(text ?? "").trim();
    if (!clean) throw new Error("Write a comment first.");
    if (clean.length > 2000) throw new Error("Comment is too long (max 2000 characters).");
    const batch = writeBatch(db);
    batch.set(doc(collection(db, BOOKS, bookId, "comments")), {
      uid: u.uid,
      name: (u.displayName ?? u.email ?? "Reader").slice(0, 80),
      text: clean,
      status: "visible",
      createdAt: serverTimestamp(),
      reportCount: 0,
    });
    batch.update(doc(db, BOOKS, bookId), { commentCount: increment(1) });
    await batch.commit();
  } catch (e) {
    throw friendly(e);
  }
}

/** Batch: delete comment + commentCount-1. Author or admin (rules enforce). */
export async function deleteComment(bookId, cid) {
  try {
    needUser();
    const batch = writeBatch(db);
    batch.delete(doc(db, BOOKS, bookId, "comments", cid));
    batch.update(doc(db, BOOKS, bookId), { commentCount: increment(-1) });
    await batch.commit();
  } catch (e) {
    throw friendly(e);
  }
}

export async function reportItem({ kind, bookId, commentId, reason, details = "" }) {
  try {
    const u = needUser();
    await addDoc(collection(db, "reports"), {
      kind,
      bookId,
      ...(commentId ? { commentId } : {}),
      reason,
      details: String(details).slice(0, 1000),
      reporterUid: u.uid,
      createdAt: serverTimestamp(),
      resolved: false,
    });
  } catch (e) {
    throw friendly(e);
  }
}

export async function reportBug({ kind, bookId, page, message }) {
  try {
    const u = needUser();
    await addDoc(collection(db, "bugs"), {
      kind,
      ...(bookId ? { bookId } : {}),
      page: String(page ?? location.pathname).slice(0, 200),
      message: String(message ?? "").slice(0, 3000),
      userAgent: String(navigator.userAgent ?? "").slice(0, 300),
      appVersion: "community/1.0",
      reporterUid: u.uid,
      createdAt: serverTimestamp(),
      status: "open",
    });
  } catch (e) {
    throw friendly(e);
  }
}

/** Copyright notice — no sign-in required (rules allow public create). */
export async function submitTakedown(form) {
  try {
    await addDoc(collection(db, "takedowns"), {
      bookId: String(form.bookId ?? ""),
      claimantName: String(form.claimantName ?? ""),
      claimantEmail: String(form.claimantEmail ?? ""),
      rightsHolder: String(form.rightsHolder ?? ""),
      workDescription: String(form.workDescription ?? ""),
      infringingUrls: String(form.infringingUrls ?? ""),
      goodFaith: true,
      accuracy: true,
      signature: String(form.signature ?? ""),
      status: "open",
      createdAt: serverTimestamp(),
    });
  } catch (e) {
    throw friendly(e);
  }
}

/** Toggle bookmark. Returns true when now favorited. */
export async function toggleFavorite(bookId) {
  try {
    const u = needUser();
    const ref = doc(db, "users", u.uid, "favorites", bookId);
    const snap = await getDoc(ref);
    if (snap.exists()) {
      await deleteDoc(ref);
      return false;
    }
    await setDoc(ref, { addedAt: serverTimestamp() });
    return true;
  } catch (e) {
    throw friendly(e);
  }
}

export async function listFavorites() {
  try {
    const u = needUser();
    const snap = await getDocs(collection(db, "users", u.uid, "favorites"));
    return snap.docs.map((d) => d.id);
  } catch (e) {
    throw friendly(e);
  }
}

// ---- admin ----

const ADMIN_COLLS = new Set(["reports", "bugs", "takedowns", "books"]);

export async function adminList(coll, { status } = {}) {
  try {
    needUser();
    if (!ADMIN_COLLS.has(coll)) throw new Error("Unknown collection.");
    const clauses = [];
    if (status) clauses.push(where("status", "==", status));
    clauses.push(orderBy("createdAt", "desc"), qLimit(100));
    const snap = await getDocs(query(collection(db, coll), ...clauses));
    return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
  } catch (e) {
    throw friendly(e);
  }
}

export async function adminSetBookStatus(id, status) {
  try {
    needUser();
    await updateDoc(doc(db, BOOKS, id), { status, updatedAt: serverTimestamp() });
  } catch (e) {
    throw friendly(e);
  }
}

export async function adminHideComment(bookId, cid) {
  try {
    needUser();
    await updateDoc(doc(db, BOOKS, bookId, "comments", cid), { status: "hidden" });
  } catch (e) {
    throw friendly(e);
  }
}

export async function adminResolve(coll, id) {
  try {
    needUser();
    if (!["reports", "bugs", "takedowns"].includes(coll)) throw new Error("Unknown collection.");
    const patch = coll === "takedowns" ? { status: "resolved" } : { resolved: true };
    await updateDoc(doc(db, coll, id), patch);
  } catch (e) {
    throw friendly(e);
  }
}
