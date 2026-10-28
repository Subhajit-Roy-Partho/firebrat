import test from "node:test";
import assert from "node:assert/strict";
import { workKey, titleKey, authorKey, groupBooks, avgRating, compareEditions } from "../src/works.js";

const b = (id, title, author, sum = 0, count = 0, createdAt = 0, extra = {}) =>
  ({ id, title, author, ratingSum: sum, ratingCount: count, createdAt, ...extra });

test("titleKey drops subtitles, articles, apostrophes and diacritics", () => {
  assert.equal(titleKey("Frankenstein; or, The Modern Prometheus"), "frankenstein");
  assert.equal(titleKey("The Time Machine"), "time-machine");
  assert.equal(titleKey("Alice's Adventures in Wonderland"), "alices-adventures-in-wonderland");
  assert.equal(titleKey("Alice’s Adventures in Wonderland"), "alices-adventures-in-wonderland");
  assert.equal(titleKey("Les Misérables (Volume 1)"), "les-miserables");
  assert.equal(titleKey("Dracula - Complete"), "dracula");
  assert.equal(titleKey(""), "");
});

test("authorKey uses the surname for any name order", () => {
  assert.equal(authorKey("Mary Wollstonecraft Shelley"), "shelley");
  assert.equal(authorKey("Shelley, Mary"), "shelley");
  assert.equal(authorKey("L. M. Montgomery"), "montgomery");
  assert.equal(authorKey("Charlotte Brontë"), "bronte");
  assert.equal(authorKey(""), "");
});

test("same work across uploads shares a key; different works do not", () => {
  assert.equal(workKey(b("1", "Frankenstein", "Mary Shelley")), workKey(b("2", "Frankenstein; or, The Modern Prometheus", "Shelley, Mary W.")));
  assert.notEqual(workKey(b("1", "Emma", "Jane Austen")), workKey(b("2", "Emma", "Someone Else")));
  assert.equal(workKey(b("1", "", "x")), "");
});

test("editions inside a work are best-rated first (avg, then count, then newest)", () => {
  const items = [
    b("a", "Dracula", "Bram Stoker", 8, 2, 1), // 4.0 x2
    b("b", "Dracula", "Bram Stoker", 5, 1, 2), // 5.0 x1
    b("c", "Dracula", "Bram Stoker", 20, 5, 3), // 4.0 x5
    b("d", "Dracula", "Bram Stoker", 0, 0, 9), // unrated
  ];
  const [w] = groupBooks(items, "top");
  assert.deepEqual(w.editions.map((e) => e.id), ["b", "c", "a", "d"]);
  assert.equal(w.best.id, "b");
  assert.equal(w.ratingCount, 8);
});

test("works are ordered by the chosen sort", () => {
  const items = [
    b("1", "Zeta", "A One", 5, 1, 100, { totalDurationMs: 5000 }),
    b("2", "Alpha", "B Two", 8, 2, 300, { totalDurationMs: 9000 }), // 4.0 x2
    b("3", "Mid", "C Three", 30, 10, 200, { totalDurationMs: 1000 }), // 3.0 x10
  ];
  const ids = (s) => groupBooks(items, s).map((w) => w.best.id);
  assert.deepEqual(ids("top"), ["1", "2", "3"]);
  assert.deepEqual(ids("new"), ["2", "3", "1"]);
  assert.deepEqual(ids("most"), ["3", "2", "1"]);
  assert.deepEqual(ids("long"), ["2", "1", "3"]);
  assert.deepEqual(ids("title"), ["2", "3", "1"]);
  assert.deepEqual(ids("bogus"), ids("top"));
});

test("a work sorts by its best edition; untitled books stay separate; Timestamp-like createdAt works", () => {
  const ts = (n) => ({ toMillis: () => n });
  const items = [
    b("1", "Moby Dick", "Herman Melville", 0, 0, ts(1)),
    b("2", "Moby Dick", "Herman Melville", 5, 1, ts(2)),
    b("3", "", "", 0, 0, ts(3)),
    b("4", "", "", 0, 0, ts(4)),
  ];
  const works = groupBooks(items, "new");
  assert.equal(works.length, 3);
  assert.equal(works.find((w) => w.editions.length === 2).best.id, "2");
  assert.equal(avgRating(items[1]), 5);
  assert.ok(compareEditions(items[1], items[0]) < 0);
});
