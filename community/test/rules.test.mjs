// Firestore rules tests. Run with the emulator:  npm run test:rules
import { readFileSync } from 'node:fs';
import { test, before, after } from 'node:test';
import { initializeTestEnvironment, assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { doc, setDoc, getDoc, updateDoc, serverTimestamp, writeBatch, increment } from 'firebase/firestore';

let env;
before(async () => {
  env = await initializeTestEnvironment({
    projectId: 'demo-firebrat-rules',
    firestore: { rules: readFileSync(new URL('../../firebase/firestore.rules', import.meta.url), 'utf8') },
  });
});
after(async () => { await env?.cleanup(); });

const provenance = {
  generation: 'firebrat-tts', license: 'public-domain', attested: true, narrationEngine: 'Qwen3-TTS', models: ['qwen3-tts'],
  pipelineNotes: 'x', sourceTitle: 'Alice', sourceUrl: 'https://www.gutenberg.org/ebooks/11', licenseUrl: 'https://creativecommons.org/publicdomain/mark/1.0/',
};
const book = (uid, over = {}) => ({
  title: 'Alice', author: 'Carroll', description: 'd', language: 'en', category: 'fiction', tags: [],
  archiveId: 'alice-test', archiveUrl: 'https://archive.org/details/alice-test', packageKind: 'zip', packageFile: 'alice-test.zip',
  chapters: [{ id: 'sec_0001', title: 'One', ms: 1000 }], sizeBytes: 1, sectionCount: 1, totalDurationMs: 1000,
  provenance, submitterUid: uid, submitterName: 'Sub', status: 'published', ratingSum: 0, ratingCount: 0, commentCount: 0,
  createdAt: serverTimestamp(), updatedAt: serverTimestamp(), ...over,
});

test('anyone can read published books; anonymous cannot create', async () => {
  await env.withSecurityRulesDisabled(async (c) => { await setDoc(doc(c.firestore(), 'books/b-one'), { ...book('u1'), createdAt: new Date(), updatedAt: new Date() }); });
  await assertSucceeds(getDoc(doc(env.unauthenticatedContext().firestore(), 'books/b-one')));
  await assertFails(setDoc(doc(env.unauthenticatedContext().firestore(), 'books/b-two'), book('u1')));
});

test('signed-in user can create a valid book with their own uid only', async () => {
  const db = env.authenticatedContext('u1').firestore();
  await assertSucceeds(setDoc(doc(db, 'books/alice-test'), book('u1')));
  await assertFails(setDoc(doc(db, 'books/alice-two'), book('someone-else')));
  await assertFails(setDoc(doc(db, 'books/alice-three'), book('u1', { archiveUrl: 'https://evil.example/x' })));
  await assertFails(setDoc(doc(db, 'books/alice-four'), book('u1', { provenance: { ...provenance, attested: false } })));
  await assertFails(setDoc(doc(db, 'books/alice-five'), book('u1', { ratingSum: 50 })));
});

test('only admins change status; submitters edit text only', async () => {
  await env.withSecurityRulesDisabled(async (c) => { await setDoc(doc(c.firestore(), 'admins/boss'), { a: 1 }); });
  const owner = env.authenticatedContext('u1').firestore();
  await assertSucceeds(updateDoc(doc(owner, 'books/alice-test'), { description: 'new', updatedAt: serverTimestamp() }));
  await assertFails(updateDoc(doc(owner, 'books/alice-test'), { status: 'removed', updatedAt: serverTimestamp() }));
  const admin = env.authenticatedContext('boss').firestore();
  await assertSucceeds(updateDoc(doc(admin, 'books/alice-test'), { status: 'disputed', updatedAt: serverTimestamp() }));
  await assertSucceeds(updateDoc(doc(admin, 'books/alice-test'), { status: 'published', updatedAt: serverTimestamp() }));
  const other = env.authenticatedContext('u2').firestore();
  await assertFails(updateDoc(doc(other, 'books/alice-test'), { status: 'removed', updatedAt: serverTimestamp() }));
});

test('rating batch must keep the aggregate consistent', async () => {
  const db = env.authenticatedContext('u2').firestore();
  const ok = writeBatch(db);
  ok.set(doc(db, 'books/alice-test/ratings/u2'), { value: 5, updatedAt: serverTimestamp() });
  ok.update(doc(db, 'books/alice-test'), { ratingSum: increment(5), ratingCount: increment(1) });
  await assertSucceeds(ok.commit());
  const cheat = writeBatch(env.authenticatedContext('u3').firestore());
  const db3 = env.authenticatedContext('u3').firestore();
  const bad = writeBatch(db3);
  bad.set(doc(db3, 'books/alice-test/ratings/u3'), { value: 1, updatedAt: serverTimestamp() });
  bad.update(doc(db3, 'books/alice-test'), { ratingSum: increment(5), ratingCount: increment(1) });
  await assertFails(bad.commit());
  void cheat;
  await assertFails(setDoc(doc(db3, 'books/alice-test/ratings/u3'), { value: 9, updatedAt: serverTimestamp() }));
});

test('comments, reports, bugs and takedowns', async () => {
  const db = env.authenticatedContext('u2').firestore();
  await assertSucceeds(setDoc(doc(db, 'books/alice-test/comments/c1'), { uid: 'u2', name: 'N', text: 'nice', status: 'visible', createdAt: serverTimestamp(), reportCount: 0 }));
  await assertFails(setDoc(doc(db, 'books/alice-test/comments/c2'), { uid: 'u1', name: 'N', text: 'spoof', status: 'visible', createdAt: serverTimestamp(), reportCount: 0 }));
  await assertSucceeds(setDoc(doc(db, 'reports/r1'), { kind: 'comment', bookId: 'alice-test', commentId: 'c1', reason: 'offensive', details: '', reporterUid: 'u2', createdAt: serverTimestamp(), resolved: false }));
  await assertFails(getDoc(doc(db, 'reports/r1')));
  await assertSucceeds(setDoc(doc(db, 'bugs/b1'), { kind: 'bug', page: '/x', message: 'broken', userAgent: 'ua', appVersion: '1', reporterUid: 'u2', createdAt: serverTimestamp(), status: 'open' }));
  const anon = env.unauthenticatedContext().firestore();
  await assertSucceeds(setDoc(doc(anon, 'takedowns/t1'), { bookId: 'alice-test', claimantName: 'A', claimantEmail: 'a@b.co', rightsHolder: 'R', workDescription: 'w', infringingUrls: '', goodFaith: true, accuracy: true, signature: 'A', status: 'open', createdAt: serverTimestamp() }));
  const admin = env.authenticatedContext('boss').firestore();
  await assertSucceeds(getDoc(doc(admin, 'reports/r1')));
  await assertSucceeds(getDoc(doc(admin, 'takedowns/t1')));
});

test('upload ledger: user -> book -> Internet Archive link must mirror the book', async () => {
  const db = env.authenticatedContext('u9').firestore();
  const row = (over = {}) => ({ bookId: 'alice-led', title: 'Alice', archiveId: 'alice-test', archiveUrl: 'https://archive.org/details/alice-test', uploadedAt: serverTimestamp(), ...over });
  const bad = writeBatch(db);
  bad.set(doc(db, 'books/alice-led'), book('u9'));
  bad.set(doc(db, 'users/u9/uploads/alice-led'), row({ archiveUrl: 'https://archive.org/details/other' }));
  await assertFails(bad.commit());
  const ok = writeBatch(db);
  ok.set(doc(db, 'books/alice-led'), book('u9'));
  ok.set(doc(db, 'users/u9/uploads/alice-led'), row());
  await assertSucceeds(ok.commit());
  await assertSucceeds(getDoc(doc(db, 'users/u9/uploads/alice-led')));
  await assertFails(getDoc(doc(env.authenticatedContext('u8').firestore(), 'users/u9/uploads/alice-led')));
  await assertFails(updateDoc(doc(db, 'users/u9/uploads/alice-led'), { title: 'x' }));
  await assertSucceeds(setDoc(doc(db, 'users/u9'), { displayName: 'Sub', uploadCount: 1, lastSeenAt: serverTimestamp() }));
});
