import { initializeApp, getApps } from "firebase/app";
import {
  getAuth,
  onAuthStateChanged,
  GoogleAuthProvider,
  signInWithPopup,
  signInWithEmailAndPassword,
  createUserWithEmailAndPassword,
  updateProfile,
  signOut as fbSignOut,
} from "firebase/auth";
import { getFirestore, doc, getDoc } from "firebase/firestore";
import { firebaseConfig } from "./firebase-config.js";

const app = getApps().length ? getApps()[0] : initializeApp(firebaseConfig);

export const auth = getAuth(app);
export const db = getFirestore(app);

/** Subscribe to auth state. Returns unsubscribe fn. */
export function onUser(cb) {
  return onAuthStateChanged(auth, cb);
}

/** Current signed-in user (or null). */
export function currentUser() {
  return auth.currentUser;
}

export async function signInGoogle() {
  const cred = await signInWithPopup(auth, new GoogleAuthProvider());
  return cred.user;
}

export async function signInEmail(email, pw) {
  const cred = await signInWithEmailAndPassword(auth, email, pw);
  return cred.user;
}

export async function signUpEmail(email, pw, name) {
  const cred = await createUserWithEmailAndPassword(auth, email, pw);
  if (name) {
    try {
      await updateProfile(cred.user, { displayName: name });
    } catch {
      // non-fatal: account exists, display name can be set later
    }
  }
  return cred.user;
}

export async function signOut() {
  await fbSignOut(auth);
}

/** True if the signed-in user has an admins/{uid} doc. */
export async function isAdmin() {
  const u = auth.currentUser;
  if (!u) return false;
  const snap = await getDoc(doc(db, "admins", u.uid));
  return snap.exists();
}
