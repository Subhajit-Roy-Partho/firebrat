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
// GET /settings gains "cast_available": true only when the server can run
// expressive-cast jobs. Missing key means false — never show the option then.
export function castAvailable(settings){return settings?.cast_available===true;}
// IAM (INTEGRATION2.md): additive role helpers. iam_enabled false (or missing)
// means today's behaviour — no setup prompt, no admin UI, no upload changes.
export function iamEnabled(settings){return settings?.iam_enabled===true;}
export function needsSetup(me){return me?.needs_setup===true;}
export function roleOf(me){return me?.role==='admin'||me?.role==='user'||me?.role==='viewer'?me.role:null;}
// Upload needs role user or better when IAM is on; off means unchanged (true).
export function canUpload(me,settings){if(!iamEnabled(settings))return true;const role=roleOf(me);return role==='admin'||role==='user';}
// Only admins ever see the Server administration section.
export function canSeeAdmin(me){return roleOf(me)==='admin';}
// 403 from a mutating/admin call means the role lacks permission, not a bug.
export function friendlyAuthError(status,detail){if(status===403)return 'Your account is not allowed to do that. Ask a server admin for access.';return detail||`Server returned ${status}.`;}
export function bookAssets(base, manifest, includePDF=false) {
  const paths=manifest.sections.flatMap(s=>[s.audio_path,s.segments_path]);
  for(const group of ['figures','formulas','tables'])for(const item of manifest[group]||[])if(item.image_path)paths.push(item.image_path);
  if(includePDF&&manifest.source_pdf_path)paths.push(manifest.source_pdf_path);
  return [...new Set(paths.map(p=>assetURL(base,manifest.book_id,p)))];
}
// ---- Server administration helpers (INTEGRATION2.md); pure, no DOM. ----
export const ROLES=['admin','user','viewer'];
export function showSetup(me,settings){return (iamEnabled(settings)||iamEnabled(me))&&needsSetup(me);}
export function showAdmin(me,settings){return !showSetup(me,settings)&&canSeeAdmin(me);}
export function setupError(status,detail){
  if(status===403)return 'That setup code is not correct.';
  if(status===410)return 'This server already has an administrator. Reload to continue.';
  if(status===429)return 'Too many wrong codes. Wait 10 minutes and try again.';
  return detail||`Server returned ${status}.`;
}
export function validateSetupCode(code){const c=String(code??'').trim();return c?{ok:true,code:c}:{ok:false,error:'Enter the setup code shown in the server log.'};}
export function validateInvite(email,role){
  const e=String(email??'').trim().toLowerCase();
  if(!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e))return {ok:false,error:'Enter a valid email address.'};
  if(!ROLES.includes(role))return {ok:false,error:'Choose a role.'};
  return {ok:true,payload:{email:e,role}};
}
// GET /admin/users -> {users,invites}; a bare array is tolerated.
export function normalizeUsers(data){
  const users=Array.isArray(data)?data:Array.isArray(data?.users)?data.users:[];
  const invites=Array.isArray(data?.invites)?data.invites:[];
  return {users:users.map(u=>({key:u.uid||u.email||'',email:u.email||'',name:u.name||'',role:roleOf(u)||'viewer',active:(u.status||'active')==='active'})),
    invites:invites.map(i=>({email:i.email||'',role:roleOf(i)||'user',claimed:!!i.claimed_uid})).filter(i=>i.email&&!i.claimed)};
}
const entryId=o=>typeof o==='string'?o:(o?.id??o?.value??o?.name);
export function optionLabel(o){
  if(typeof o==='string')return o;
  const bits=[o.name||entryId(o)];if(o.vram_gb)bits.push(`${o.vram_gb} GB VRAM`);if(o.available===false)bits.push('weights not downloaded');return bits.join(' - ');
}
export function optionNote(o){
  if(!o||typeof o==='string')return '';
  const bits=[];if(o.description)bits.push(o.description);if(o.vram_gb)bits.push(`Needs about ${o.vram_gb} GB of GPU memory.`);
  if(o.available===false)bits.push('Warning: weights are not downloaded on this server yet, so jobs using this choice will fail or download first.');
  return bits.join(' ');
}
// Accepts {llm:{models},tts:{engines}} (route) and flat catalog shapes.
export function normalizeOptions(options){
  const o=options||{},pick=(...c)=>{for(const v of c)if(Array.isArray(v))return v;return [];};
  const list=a=>a.map(x=>typeof x==='string'?{id:x}:{...x,id:entryId(x)}).filter(x=>x.id);
  return {llm:list(pick(o.llm?.models,o.llm_models,o.llm_model,o.llm)),tts:list(pick(o.tts?.engines,o.tts_engines,o.tts_engine,o.tts)),
    quantizations:list(pick(o.llm?.quantizations,o.quantization,o.quantizations)).map(x=>x.id),
    phaseModes:pick(o.run_pattern?.phase_modes,o.phase_mode).length?pick(o.run_pattern?.phase_modes,o.phase_mode):['batched','sequential'],
    audioOrders:pick(o.run_pattern?.audio_orders,o.audio_order).length?pick(o.run_pattern?.audio_orders,o.audio_order):['shortest_first','fifo'],
    maxBooks:Array.isArray(o.run_pattern?.max_books_range)?o.run_pattern.max_books_range:[1,20]};
}
export const PHASE_LABELS={batched:'Batched (cast all queued books, then audio)',sequential:'Sequential (one book end to end)'};
export const ORDER_LABELS={shortest_first:'Shortest book first',fifo:'First queued first'};
// values -> flat form fields.
export function settingsToForm(values){
  const v=values||{},r=v.run_pattern||{},q=r.quiet_hours;
  return {llmModel:v.llm?.model||'',quantization:v.llm?.quantization||'fp8',ttsEngine:v.tts?.engine||'',
    phaseMode:r.phase_mode||'batched',maxBooks:String(r.max_books_per_llm_phase??4),audioOrder:r.audio_order||'shortest_first',
    paused:r.paused===true,quietStart:q?.start||'',quietEnd:q?.end||''};
}
// form -> full values payload, preserving keys the form does not edit (limits, ...).
export function formToSettings(baseValues,f,range=[1,20]){
  const errors=[],base=JSON.parse(JSON.stringify(baseValues||{})),[lo,hi]=range;
  const n=Number(f.maxBooks);
  if(!Number.isInteger(n)||n<lo||n>hi)errors.push(`Max books per LLM phase must be a whole number from ${lo} to ${hi}.`);
  const s=(f.quietStart||'').trim(),e=(f.quietEnd||'').trim(),hm=/^([01]\d|2[0-3]):[0-5]\d$/;
  let quiet=null;
  if(s||e){
    if(!hm.test(s)||!hm.test(e))errors.push('Quiet hours need both a start and an end time.');
    else if(s===e)errors.push('Quiet hours start and end must differ.');
    else quiet={start:s,end:e};
  }
  if(!f.llmModel)errors.push('Choose an LLM model.');
  if(!f.ttsEngine)errors.push('Choose a TTS engine.');
  if(errors.length)return {ok:false,errors};
  base.llm={...(base.llm||{}),model:f.llmModel,quantization:f.quantization||'fp8'};
  base.tts={...(base.tts||{}),engine:f.ttsEngine};
  base.run_pattern={...(base.run_pattern||{}),phase_mode:f.phaseMode,max_books_per_llm_phase:n,audio_order:f.audioOrder,paused:!!f.paused,quiet_hours:quiet};
  return {ok:true,values:base};
}
// GET /admin/queue -> {scheduler:{available,running,detail,books:[{slug,stage,detail,progress}]},paused}
export function normalizeQueue(q){
  const s=q?.scheduler||{},books=Array.isArray(s.books)?s.books:Array.isArray(q?.books)?q.books:[];
  const paused=q?.paused===true;
  const state=paused?'Paused. No new GPU work starts.':s.available===false?'Cast scheduler is not running.':s.running?'Running.':'Idle.';
  return {paused,available:s.available!==false,state,detail:s.detail||'',
    books:books.filter(b=>b?.slug).map(b=>({slug:b.slug,stage:b.stage||'queued',detail:b.detail||'',
      percent:typeof b.progress==='number'&&Number.isFinite(b.progress)?Math.round(Math.max(0,Math.min(1,b.progress))*100):null,
      terminal:b.terminal||null,error:b.error||''}))};
}
export function canReorder(book){return !book.terminal&&book.stage==='queued';}
export function canCancel(book){return !book.terminal;}
