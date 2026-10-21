export function normalizeServer(value, origin = location.origin) {
  const url = new URL(value || origin);
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) throw new Error('Use a plain HTTP or HTTPS server address without credentials.');
  if (origin.startsWith('https:') && url.protocol === 'http:' && !['localhost','127.0.0.1','[::1]'].includes(url.hostname)) throw new Error('Use HTTPS for the server when this app is opened over HTTPS.');
  return url.href.replace(/\/$/, '');
}
export function assetURL(base, bookId, path) {
  if (!path || path.startsWith('/') || path.includes('\\') || path.split('/').includes('..') || /[?#]/.test(path)) throw new Error('Invalid book asset path.');
  return `${base}/books/${encodeURIComponent(bookId)}/assets/${path.split('/').map(encodeURIComponent).join('/')}`;
}
export function activeAt(segments, ms) {
  let low=0,high=segments.length-1;
  while(low<=high){const mid=(low+high)>>1;const s=segments[mid];if(ms<s.start_ms)high=mid-1;else if(ms>=s.end_ms)low=mid+1;else return s;}
  return undefined;
}
export {rangeBounds} from '../public/range.mjs';
export function bookKey(base,id){return `${base}|${id}`;}
export function bookAssets(base, manifest, includePDF=false) {
  const paths=manifest.sections.flatMap(s=>[s.audio_path,s.segments_path]);
  for(const group of ['figures','formulas','tables'])for(const item of manifest[group]||[])if(item.image_path)paths.push(item.image_path);
  if(includePDF&&manifest.source_pdf_path)paths.push(manifest.source_pdf_path);
  return [...new Set(paths.map(p=>assetURL(base,manifest.book_id,p)))];
}
