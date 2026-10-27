// Firebrat Community — minimal in-browser zip reader.
// Reads ONLY manifest.json out of a user-chosen .zip (central-directory scan,
// then a single slice for the entry data). Supports stored (method 0) and
// deflate (method 8 via DecompressionStream). No dependencies.

const EOCD_SIG = 0x06054b50; // end of central directory
const CD_SIG = 0x02014b50; // central directory entry
const LFH_SIG = 0x04034b50; // local file header

/**
 * Parse and return manifest.json from a File/Blob zip.
 * Throws an Error with a user-friendly message on any problem.
 */
export async function readManifestFromZip(file) {
  if (!file) throw new Error("Choose a .zip file first.");
  const size = file.size;
  if (!Number.isFinite(size) || size < 22) {
    throw new Error("That file is too small to be a zip.");
  }

  // Locate the end-of-central-directory record (last 64KB + 22 bytes).
  const tailLen = Math.min(size, 65535 + 22);
  const tailBuf = await file.slice(size - tailLen, size).arrayBuffer();
  const tail = new DataView(tailBuf);
  let eocd = -1;
  for (let i = tail.byteLength - 22; i >= 0; i--) {
    if (tail.getUint32(i, true) === EOCD_SIG) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) {
    throw new Error("Could not read this zip (no end-of-directory record).");
  }
  const cdCount = tail.getUint16(eocd + 10, true);
  const cdSize = tail.getUint32(eocd + 12, true);
  const cdOffset = tail.getUint32(eocd + 16, true);
  if (cdCount === 0xffff || cdSize === 0xffffffff || cdOffset === 0xffffffff) {
    throw new Error(
      "This zip uses Zip64, which the in-browser reader does not support. Re-save it without Zip64 and try again.",
    );
  }
  if (cdCount === 0 || cdSize === 0) throw new Error("This zip is empty.");
  if (cdOffset + cdSize > size) {
    throw new Error("Could not read this zip (corrupt directory).");
  }

  // Scan the central directory for manifest.json (prefer the root entry).
  const cdBuf = await file.slice(cdOffset, cdOffset + cdSize).arrayBuffer();
  const cd = new DataView(cdBuf);
  const decode = new TextDecoder();
  let exact = null;
  let nested = null;
  let off = 0;
  while (off + 46 <= cd.byteLength) {
    if (cd.getUint32(off, true) !== CD_SIG) break;
    const method = cd.getUint16(off + 10, true);
    const compSize = cd.getUint32(off + 24, true);
    const fnLen = cd.getUint16(off + 28, true);
    const extraLen = cd.getUint16(off + 30, true);
    const commentLen = cd.getUint16(off + 32, true);
    const lho = cd.getUint32(off + 42, true);
    if (off + 46 + fnLen > cd.byteLength) break;
    const name = decode
      .decode(new Uint8Array(cdBuf, off + 46, fnLen))
      .replace(/^\.\//, "")
      .replace(/^\/+/, "");
    const entry = { method, compSize, lho };
    if (name === "manifest.json") {
      exact = entry;
      break;
    }
    if (!nested && /(^|\/)manifest\.json$/i.test(name)) nested = entry;
    off += 46 + fnLen + extraLen + commentLen;
  }
  const found = exact || nested;
  if (!found) {
    throw new Error(
      "manifest.json was not found in this zip. The package must contain a manifest.json at its top level.",
    );
  }
  if (found.method !== 0 && found.method !== 8) {
    throw new Error("manifest.json uses an unsupported compression method.");
  }
  if (found.compSize === 0xffffffff) {
    throw new Error("Could not read manifest.json (Zip64 entry).");
  }

  // Local file header tells us where the entry data starts.
  const lfhBuf = await file.slice(found.lho, found.lho + 30).arrayBuffer();
  if (lfhBuf.byteLength < 30) throw new Error("Could not read this zip (bad local header).");
  const lfh = new DataView(lfhBuf);
  if (lfh.getUint32(0, true) !== LFH_SIG) {
    throw new Error("Could not read this zip (bad local header).");
  }
  const dataStart = found.lho + 30 + lfh.getUint16(26, true) + lfh.getUint16(28, true);
  const raw = new Uint8Array(
    await file.slice(dataStart, dataStart + found.compSize).arrayBuffer(),
  );

  let bytes = raw;
  if (found.method === 8) {
    if (typeof DecompressionStream === "undefined") {
      throw new Error(
        "This browser cannot decompress zips (no DecompressionStream). Try a recent Chrome or Edge.",
      );
    }
    const stream = new Blob([raw]).stream().pipeThrough(new DecompressionStream("deflate-raw"));
    bytes = new Uint8Array(await new Response(stream).arrayBuffer());
  }
  const text = new TextDecoder("utf-8").decode(bytes);
  try {
    const parsed = JSON.parse(text);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new Error("not an object");
    }
    return parsed;
  } catch (e) {
    if (e instanceof Error && /not valid JSON|not an object/.test(e.message)) throw e;
    throw new Error("manifest.json in this zip is not valid JSON.");
  }
}
