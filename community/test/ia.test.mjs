import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  parseArchiveUrl,
  locatePackage,
  validateManifest,
  buildChapters,
  validateChapters,
  MAX_CHAPTERS,
  downloadUrl,
  slugify,
  itemFileUrl,
} from "../src/ia.js";

const goodManifest = {
  schema_version: "1.0",
  book_id: "demo-book",
  title: "Demo Book",
  author: "Anon",
  total_duration_ms: 60000,
  narrator_voice: { engine: "firebrat-tts" },
  sections: [
    { section_id: "s1", audio_path: "sections/s1/audio.m4a", segments_path: "sections/s1/segments.json" },
    { section_id: "s2", audio_path: "sections/s2/audio.m4a", segments_path: "sections/s2/segments.json" },
  ],
};

describe("parseArchiveUrl", () => {
  it("parses details/download/embed URLs", () => {
    assert.equal(parseArchiveUrl("https://archive.org/details/my-book-123"), "my-book-123");
    assert.equal(parseArchiveUrl("https://archive.org/download/my-book-123/file.zip"), "my-book-123");
    assert.equal(parseArchiveUrl("https://archive.org/embed/my-book-123"), "my-book-123");
  });
  it("accepts bare host and trailing slashes", () => {
    assert.equal(parseArchiveUrl("archive.org/details/Abc_123"), "Abc_123");
    assert.equal(parseArchiveUrl("https://archive.org/details/Abc_123/"), "Abc_123");
  });
  it("rejects other hosts", () => {
    assert.equal(parseArchiveUrl("https://example.com/details/my-book-123"), null);
    assert.equal(parseArchiveUrl("https://evilarchive.org/details/my-book-123"), null);
    assert.equal(parseArchiveUrl("https://archive.org.evil.com/download/x"), null);
  });
  it("rejects malformed identifiers and paths", () => {
    assert.equal(parseArchiveUrl("https://archive.org/details/ab"), null); // too short
    assert.equal(parseArchiveUrl("https://archive.org/details/"), null);
    assert.equal(parseArchiveUrl("https://archive.org/other/my-book-123"), null);
    assert.equal(parseArchiveUrl("not a url at all!!!"), null);
    assert.equal(parseArchiveUrl(""), null);
  });
});

describe("slugify", () => {
  it("lowercases and hyphenates", () => {
    assert.equal(slugify("The Great Gatsby!"), "the-great-gatsby");
    assert.equal(slugify("  A  --  B  "), "a-b");
  });
  it("strips accents and truncates", () => {
    assert.equal(slugify("Café au lait"), "cafe-au-lait");
    assert.ok(slugify("x".repeat(200)).length <= 80);
  });
});

describe("locatePackage", () => {
  it("prefers a root manifest.json (folder)", () => {
    assert.deepEqual(locatePackage([{ name: "manifest.json" }, { name: "a.zip" }]), {
      kind: "folder",
      base: "",
    });
  });
  it("finds the first zip otherwise", () => {
    assert.deepEqual(locatePackage([{ name: "book_v1.ZIP" }, { name: "b.zip" }]), {
      kind: "zip",
      zip: "book_v1.ZIP",
    });
    assert.deepEqual(locatePackage(["notes.txt", "pkg.zip"]), { kind: "zip", zip: "pkg.zip" });
  });
  it("returns null when no package exists", () => {
    assert.equal(locatePackage([{ name: "cover.jpg" }]), null);
    assert.equal(locatePackage([]), null);
    assert.equal(locatePackage(null), null);
  });
});

describe("itemFileUrl / downloadUrl", () => {
  it("builds zip-inner and folder URLs", () => {
    assert.equal(
      itemFileUrl("my-book", { kind: "zip", zip: "pkg.zip" }, "manifest.json"),
      "https://archive.org/download/my-book/pkg.zip/manifest.json",
    );
    assert.equal(
      itemFileUrl("my-book", { kind: "folder", base: "" }, "sections/s1/audio.m4a"),
      "https://archive.org/download/my-book/sections/s1/audio.m4a",
    );
  });
  it("encodes path segments and strips leading slashes", () => {
    assert.equal(
      itemFileUrl("my-book", { kind: "folder", base: "" }, "/a b/c.m4a"),
      "https://archive.org/download/my-book/a%20b/c.m4a",
    );
  });
  it("downloadUrl uses zip file or compress endpoint", () => {
    assert.equal(
      downloadUrl("my-book", { kind: "zip", zip: "pkg.zip" }),
      "https://archive.org/download/my-book/pkg.zip",
    );
    assert.equal(
      downloadUrl("my-book", { kind: "folder", base: "" }),
      "https://archive.org/compress/my-book",
    );
  });
  it("throws on invalid identifiers", () => {
    assert.throws(() => itemFileUrl("ab", { kind: "folder" }, "x"), /Invalid archive/);
    assert.throws(() => downloadUrl("http://x", null), /Invalid archive/);
  });
});

describe("validateManifest", () => {
  it("accepts a good manifest with summary", () => {
    const r = validateManifest(goodManifest);
    assert.equal(r.ok, true);
    assert.deepEqual(r.errors, []);
    assert.equal(r.summary.sectionCount, 2);
    assert.equal(r.summary.durationMs, 60000);
    assert.equal(r.summary.engine, "firebrat-tts");
    assert.equal(r.summary.title, "Demo Book");
  });
  it("rejects malformed manifests", () => {
    assert.equal(validateManifest(null).ok, false);
    assert.equal(validateManifest({}).ok, false);
    assert.ok(validateManifest({ ...goodManifest, schema_version: "2.0" }).errors.length > 0);
    assert.ok(validateManifest({ ...goodManifest, title: "" }).errors.length > 0);
    assert.ok(validateManifest({ ...goodManifest, sections: [] }).errors.length > 0);
    const missingPaths = validateManifest({
      ...goodManifest,
      sections: [{ section_id: "s1" }],
    });
    assert.equal(missingPaths.ok, false);
    assert.ok(missingPaths.errors.some((e) => e.includes("audio_path")));
  });
});

describe("buildChapters", () => {
  it("sorts by order and maps chapter fields", () => {
    const chapters = buildChapters({
      sections: [
        { title: "B", order: 2, audio_path: "sections/b/audio.m4a", duration_ms: 1500.9 },
        { title: "A", order: 1, audio_path: "sections/a/audio.m4a", duration_ms: 1000 },
        { title: "No order", audio_path: "sections/c/audio.m4a", duration_ms: 500 },
      ],
    });
    assert.deepEqual(chapters.map((c) => c.title), ["A", "B", "No order"]);
    assert.deepEqual(chapters.map((c) => c.audioPath), [
      "sections/a/audio.m4a",
      "sections/b/audio.m4a",
      "sections/c/audio.m4a",
    ]);
    assert.deepEqual(chapters.map((c) => c.durationMs), [1000, 1500, 500]);
  });
  it("truncates long titles to 200 chars", () => {
    const chapters = buildChapters({
      sections: [{ title: "x".repeat(500), audio_path: "a.m4a", duration_ms: 10 }],
    });
    assert.equal(chapters[0].title.length, 200);
  });
  it("returns [] for missing sections", () => {
    assert.deepEqual(buildChapters(null), []);
    assert.deepEqual(buildChapters({}), []);
  });
});

describe("validateChapters", () => {
  it("accepts a good chapter list", () => {
    const r = validateChapters(buildChapters(goodManifest));
    assert.equal(r.ok, true);
    assert.deepEqual(r.errors, []);
  });
  it("rejects empty, bad, and oversized lists", () => {
    assert.equal(validateChapters([]).ok, false);
    assert.equal(validateChapters(null).ok, false);
    assert.equal(
      validateChapters([{ title: "", durationMs: 0, audioPath: "" }]).ok,
      false,
    );
    assert.equal(
      validateChapters([{ title: "t", durationMs: -1, audioPath: "a" }]).ok,
      false,
    );
    assert.equal(
      validateChapters([{ title: "t".repeat(201), durationMs: 0, audioPath: "a" }]).ok,
      false,
    );
    const big = Array.from({ length: MAX_CHAPTERS + 1 }, (_, i) => ({
      title: `Chapter ${i + 1}`,
      durationMs: 1000,
      audioPath: `sections/s${i}/audio.m4a`,
    }));
    const r = validateChapters(big);
    assert.equal(r.ok, false);
    assert.ok(r.errors[0].includes("too large"));
  });
});

import { coverUrl } from "../src/ia.js";
describe("coverUrl", () => { it("points at the package's cover.jpg", () => {
  assert.equal(
    coverUrl({ archiveId: "firebrat-alice", packageKind: "zip", packageFile: "firebrat-alice.zip" }),
    "https://archive.org/download/firebrat-alice/firebrat-alice.zip/cover.jpg",
  );
  assert.equal(coverUrl({ archiveId: "some-item", packageKind: "folder" }), "https://archive.org/download/some-item/cover.jpg");
  assert.equal(coverUrl({}), null);
  assert.equal(coverUrl({ archiveId: "bad id!" }), null);
}); });
