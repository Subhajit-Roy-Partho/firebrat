import './style.css';
import 'katex/dist/katex.min.css';
import katex from 'katex';
import {initializeApp,getApps} from 'firebase/app';
import {getAuth,onIdTokenChanged,GoogleAuthProvider,signInWithPopup,signInWithRedirect,getRedirectResult,signOut,signInWithEmailAndPassword,createUserWithEmailAndPassword} from 'firebase/auth';
import {normalizeServer,assetURL,activeAt,bookKey,bookAssets} from './core.mjs';
const $=id=>document.getElementById(id),audio=$('audio'),INDEX='firebrat-index-v1',APP_BASE=import.meta.env.BASE_URL,STATIC_HOST=import.meta.env.VITE_STATIC_HOST==='1',INDEX_URL=new URL(APP_BASE+'_library',location.origin).href;
const savedServer=localStorage.getItem('firebrat.server')||(STATIC_HOST?'':location.origin);
let base=savedServer?normalizeServer(savedServer):'',records=[],auth=null,unsubAuth=null,reader=null,readGeneration=0,autoplayTimer=null,lastActive=null,lastSave=0,remote=[],noticeTimer;
let prefs={};try{prefs=JSON.parse(localStorage.getItem('firebrat.reader')||'{}');}catch{}
function savePrefs(){localStorage.setItem('firebrat.reader',JSON.stringify(prefs));}
function notice(message){$('notice').textContent=message;clearTimeout(noticeTimer);noticeTimer=setTimeout(()=>$('notice').textContent='',6500);}
function element(tag,text,className){const el=document.createElement(tag);if(text!==undefined)el.textContent=text;if(className)el.className=className;return el;}
function button(text,action){const el=element('button',text);el.type='button';el.onclick=()=>Promise.resolve().then(action).catch(e=>notice(e.message));return el;}
async function indexRead(){try{const response=await(await caches.open(INDEX)).match(INDEX_URL);records=response?await response.json():[];}catch{records=[];}}
async function indexWrite(next){await(await caches.open(INDEX)).put(INDEX_URL,new Response(JSON.stringify(next),{headers:{'Content-Type':'application/json'}}));records=next;}
async function request(path,options={},server=base){
 if(!server)throw new Error('Set your Firebrat server address in Settings.');
 const headers=new Headers(options.headers);if(options.auth){if(!auth?.currentUser)throw new Error('Sign in from Settings to manage conversions.');headers.set('Authorization',`Bearer ${await auth.currentUser.getIdToken()}`);}
 const response=await fetch(server+path,{...options,headers,signal:options.signal??AbortSignal.timeout(15000)});
 if(!response.ok){if(response.status===401)throw new Error('Please sign in again to manage conversions.');let body;try{body=await response.json();}catch{}throw new Error(body?.detail||`Server returned ${response.status}.`);}
 return response;
}
function switchTab(name){for(const page of document.querySelectorAll('.page'))page.hidden=page.id!==name;for(const tab of document.querySelectorAll('[data-tab]')){if(tab.dataset.tab===name)tab.setAttribute('aria-current','page');else tab.removeAttribute('aria-current');}history.replaceState(null,'',`#${name}`);if(name==='settings')initAuth().catch(e=>$('auth-error').textContent=e.message);if(name==='jobs')loadJobs();}
for(const tab of document.querySelectorAll('[data-tab]'))tab.onclick=()=>switchTab(tab.dataset.tab);
async function loadLibrary(){
 await indexRead();renderLibrary();if(!base){remote=[{book_id:'demo-circuit',title:'The Lantern Circuit — short sample',section_count:1,total_duration_ms:18000,_server:location.origin+APP_BASE+'demo'}];renderLibrary();$('connection').textContent='Choose a server';$('library-note').textContent='Try the short sample, or open Settings to connect your conversion server. Saved books remain available offline.';return;}$('connection').textContent=navigator.onLine?'Connecting…':'Offline';
 try{remote=await(await request('/books')).json();$('connection').textContent='Server connected';$('library-note').textContent='Save a book for offline reading and listening.';}catch{remote=[];$('connection').textContent='Offline reading';$('library-note').textContent='Showing saved books. Connect to your server for more.';}
 renderLibrary();
}
function renderLibrary(){
 const grid=$('book-grid');grid.replaceChildren();const books=new Map(records.map(r=>[r.key,{...r.manifest,server:r.base,saved:r}]));
 for(const book of remote){const server=book._server||base,key=bookKey(server,book.book_id);if(!books.has(key))books.set(key,{...book,server});}
 if(!books.size){grid.append(element('p','No books yet. Connect to your server or submit a book for server conversion.','muted'));return;}
 for(const book of books.values()){
  const card=element('article',undefined,'card');card.append(element('h2',book.title||book.book_id),element('p',`${book.saved?'Saved offline · ':''}${book.sections?.length??book.section_count??0} ${(book.sections?.length??book.section_count)===1?'section':'sections'} · ${(book.total_duration_ms||0)<60000?Math.ceil((book.total_duration_ms||0)/1000)+' sec':Math.round(book.total_duration_ms/60000)+' min'}`,'muted'));
  const actions=element('div',undefined,'actions');actions.append(button('Read',()=>openBook(book.server,book.book_id)));
  if(!book.saved)actions.append(button('Save offline',()=>downloadBook(book.server,book.book_id,card)));
  else actions.append(button('Remove download',async()=>{if(!confirm('Remove this saved copy? The server book is kept.'))return;await indexWrite(records.filter(r=>r.key!==book.saved.key));await caches.delete(book.saved.cacheName);renderLibrary();}));
  card.append(actions);grid.append(card);
 }
}
async function downloadBook(server,id,card){
 if(!('caches'in window)||!window.isSecureContext)throw new Error('Offline saving requires HTTPS (or localhost for testing).');
 if(!('serviceWorker'in navigator))throw new Error('This browser does not support offline playback.');
 await navigator.serviceWorker.ready;
 if(!navigator.serviceWorker.controller)throw new Error('Reload once after installing the app, then save the book.');
 const buttons=card.querySelectorAll('button');buttons.forEach(b=>b.disabled=true);const progress=element('p','Preparing download…','muted');card.append(progress);
 const cacheName='firebrat-book-'+crypto.randomUUID();let committed=false;
 try{
  const manifestResponse=await request(`/books/${encodeURIComponent(id)}/manifest`,{},server),manifest=await manifestResponse.clone().json();
  if(manifest.book_id!==id||!manifest.sections?.length)throw new Error('Server returned an invalid book manifest.');
  const manifestURL=`${server}/books/${encodeURIComponent(id)}/manifest`,urls=bookAssets(server,manifest,$('include-pdf').checked),cache=await caches.open(cacheName);
  await cache.put(manifestURL,manifestResponse);let done=0;
  for(const url of urls){const response=await fetch(url);if(!response.ok)throw new Error('An asset could not be downloaded. Retry when the server is available.');await cache.put(url,response);progress.textContent=`Saving ${++done} of ${urls.length} files…`;}
  const old=records.find(r=>r.key===bookKey(server,id));const record={key:bookKey(server,id),base:server,manifest,cacheName,urls:[manifestURL,...urls]};
  await indexWrite([...records.filter(r=>r.key!==record.key),record]);committed=true;if(old)await caches.delete(old.cacheName);
  if(navigator.storage?.persist)await navigator.storage.persist();notice('Book saved for offline listening.');renderLibrary();
 }catch(error){if(error.name==='QuotaExceededError')throw new Error('Not enough browser storage. Remove a download or exclude the original PDF, then retry.');throw error;}
 finally{if(!committed)await caches.delete(cacheName);buttons.forEach(b=>b.disabled=false);progress.remove();}
}
async function bookResponse(server,id,path){const url=path==='manifest'?`${server}/books/${encodeURIComponent(id)}/manifest`:assetURL(server,id,path);const record=records.find(r=>r.key===bookKey(server,id));if(record){const saved=await(await caches.open(record.cacheName)).match(url);if(saved)return saved;}const response=await fetch(url);if(!response.ok)throw new Error('This book file is unavailable. Connect to the server or save the book again.');return response;}
async function openBook(server,id){
 const generation=++readGeneration;clearTimeout(autoplayTimer);audio.pause();$('reader-status').textContent='Opening book…';switchTab('reader');
 try{const manifest=await(await bookResponse(server,id,'manifest')).json();if(!manifest.sections?.length)throw new Error('Book contains no sections.');if(generation!==readGeneration)return;
  reader={base:server,id,manifest,index:0,segments:[]};$('reader-title').textContent=manifest.title;$('section-select').replaceChildren(...manifest.sections.map((s,i)=>{const option=element('option',s.title||`Section ${i+1}`);option.value=String(i);return option;}));
  let progress={};try{progress=JSON.parse(localStorage.getItem('firebrat.progress.'+bookKey(server,id))||'{}');}catch{}
  await loadSection(Math.min(manifest.sections.length-1,Math.max(0,progress.section||0)),false,progress.time||0);
 }catch(e){$('reader-status').textContent=e.message;}
}
async function loadSection(index,play=false,time=0){
 if(!reader||index<0||index>=reader.manifest.sections.length)return;const generation=++readGeneration;clearTimeout(autoplayTimer);audio.pause();lastActive=null;
 reader.index=index;$('section-select').value=String(index);$('previous-section').disabled=index===0;$('next-section').disabled=index===reader.manifest.sections.length-1;$('reader-status').textContent='Loading section…';
 const section=reader.manifest.sections[index];
 try{const file=await(await bookResponse(reader.base,reader.id,section.segments_path)).json();if(generation!==readGeneration)return;reader.segments=file.segments||[];
  $('segments').replaceChildren(...reader.segments.map(segment=>{const el=button(segment.text,()=>{audio.currentTime=segment.start_ms/1000;return audio.play();});el.className='segment';el.dataset.segment=segment.segment_id;return el;}));
  audio.src=assetURL(reader.base,reader.id,section.audio_path);audio.playbackRate=Number($('speed').value);audio.onloadedmetadata=()=>{if(generation!==readGeneration)return;if(time>0)audio.currentTime=Math.min(time,Number.isFinite(audio.duration)?audio.duration:time);};
  showVisual(reader.segments.find(s=>s.ref)?.ref);$('reader-status').textContent='';
  if('mediaSession'in navigator&&typeof MediaMetadata!=='undefined'){navigator.mediaSession.metadata=new MediaMetadata({title:section.title,album:reader.manifest.title});}
  if(play)await audio.play();
 }catch(e){$('reader-status').textContent=e.message;}
}
function showVisual(ref){
 if(!reader)return;const m=reader.manifest,item=[...(m.figures||[]),...(m.formulas||[]),...(m.tables||[])].find(x=>[x.figure_id,x.formula_id,x.table_id].includes(ref));
 $('visual').hidden=!item;if(!item)return;$('caption').textContent=item.caption||item.spoken_text||'';$('figure').hidden=!item.image_path;$('image-button').hidden=!item.image_path;$('math').replaceChildren();
 if(item.image_path){$('figure').src=assetURL(reader.base,reader.id,item.image_path);$('figure').alt=item.caption||item.spoken_text||'Book illustration';}
 else if(item.latex)katex.render(item.latex,$('math'),{throwOnError:false,trust:false,maxExpand:1000,displayMode:true});
}
audio.ontimeupdate=()=>{
 if(!reader)return;const segment=activeAt(reader.segments,audio.currentTime*1000);
 if(segment?.segment_id!==lastActive){lastActive=segment?.segment_id;for(const el of $('segments').children)el.classList.toggle('active',el.dataset.segment===lastActive);if(segment?.ref)showVisual(segment.ref);}
 if(Date.now()-lastSave>2000){localStorage.setItem('firebrat.progress.'+bookKey(reader.base,reader.id),JSON.stringify({section:reader.index,time:audio.currentTime}));lastSave=Date.now();}
};
audio.onended=()=>{if(prefs.autoplay!==false&&reader&&reader.index+1<reader.manifest.sections.length){const next=reader.index+1;autoplayTimer=setTimeout(()=>loadSection(next,true),Math.min(10,Math.max(0,Number(prefs.delay??1)))*1000);}};
audio.onerror=()=>{$('reader-status').textContent='Audio could not be played. Connect to the server or save this book again.';};
$('section-select').onchange=()=>loadSection(Number($('section-select').value),!audio.paused);$('previous-section').onclick=()=>loadSection(reader.index-1,!audio.paused);$('next-section').onclick=()=>loadSection(reader.index+1,!audio.paused);
function skipSegment(delta){if(!reader)return;const current=activeAt(reader.segments,audio.currentTime*1000);const index=Math.max(0,reader.segments.findIndex(s=>s===current));const target=reader.segments[Math.min(reader.segments.length-1,Math.max(0,index+delta))];if(target)audio.currentTime=target.start_ms/1000;}
$('previous-segment').onclick=()=>skipSegment(-1);$('next-segment').onclick=()=>skipSegment(1);$('speed').value=String(prefs.speed||1);$('speed').onchange=()=>{prefs.speed=Number($('speed').value);audio.playbackRate=prefs.speed;savePrefs();};
$('focus').onclick=()=>$('reader').classList.toggle('focus');$('close-reader').onclick=()=>switchTab('library');$('image-button').onclick=()=>{$('zoom-image').src=$('figure').src;$('zoom-image').alt=$('figure').alt;$('image-dialog').showModal();};$('close-image').onclick=()=>$('image-dialog').close();
$('source-pdf').onclick=async()=>{if(!reader)return;const path=reader.manifest.source_pdf_path;if(!path)return notice('This package does not include the original PDF.');const url=assetURL(reader.base,reader.id,path);const record=records.find(r=>r.key===bookKey(reader.base,reader.id));if(!navigator.onLine&&!record?.urls.includes(url))return notice('The original PDF was not saved offline.');window.open(url,'_blank','noopener');};
if('mediaSession'in navigator){for(const [action,handler]of Object.entries({play:()=>audio.play(),pause:()=>audio.pause(),previoustrack:()=>skipSegment(-1),nexttrack:()=>skipSegment(1),seekto:d=>audio.currentTime=d.seekTime})){try{navigator.mediaSession.setActionHandler(action,handler);}catch{}}}
async function initAuth(){
 if(auth){await auth.authStateReady();return auth;}$('google-signin').disabled=true;$('auth-error').textContent='Loading sign-in…';
 const cfg=base?await(await request('/firebase-config')).json():{apiKey:'AIzaSyDnvh3rtp4f2GtU9vOAIoDIcWLnXpTp38E',authDomain:'firebrat-8c597.firebaseapp.com',projectId:'firebrat-8c597',appId:'1:657440934081:web:c94b0a6fd08fdb7f1bac40'};if(!cfg.apiKey)throw new Error('The server needs Firebase web sign-in configuration. Reading still works.');
 const app=getApps().find(a=>a.name===(base||location.origin))||initializeApp(cfg,base||location.origin);auth=getAuth(app);if(unsubAuth)unsubAuth();
 unsubAuth=onIdTokenChanged(auth,user=>{$('account-status').textContent=user?`Signed in as ${user.email||'your account'}`:'Reading does not require an account. Sign in for uploads and jobs.';$('signout').hidden=!user;$('google-signin').hidden=!!user;$('email-form').hidden=!!user;});
 await auth.authStateReady();$('google-signin').disabled=false;$('auth-error').textContent='';if(sessionStorage.getItem('firebrat.redirect')){sessionStorage.removeItem('firebrat.redirect');await getRedirectResult(auth);}return auth;
}
$('google-signin').onclick=()=>{if(!auth)return;signInWithPopup(auth,new GoogleAuthProvider()).catch(error=>{$('auth-error').textContent=error.message;if(error.code==='auth/popup-blocked'){const redirect=button('Sign in in this window',()=>{sessionStorage.setItem('firebrat.redirect','1');return signInWithRedirect(auth,new GoogleAuthProvider());});$('auth-error').append(redirect);}});};
$('signout').onclick=()=>signOut(auth).catch(e=>notice(e.message));$('email-form').onsubmit=async event=>{event.preventDefault();try{await initAuth();const fn=$('create-account').checked?createUserWithEmailAndPassword:signInWithEmailAndPassword;await fn(auth,$('email').value,$('password').value);$('password').value='';$('auth-error').textContent='';}catch(e){$('auth-error').textContent=e.message;}};
$('upload-form').onsubmit=async event=>{
 event.preventDefault();const file=$('upload-file').files[0];if(!file)return;const status=$('upload-status');$('upload-button').disabled=true;
 try{await initAuth();if(!auth.currentUser)throw new Error('Sign in from Settings before uploading.');const token=await auth.currentUser.getIdToken();const form=new FormData();form.append('file',file);form.append('title',$('upload-title').value);form.append('content_mode',$('content-mode').value);
  status.textContent='Uploading…';$('upload-progress').hidden=false;
  const job=await new Promise((resolve,reject)=>{const xhr=new XMLHttpRequest();xhr.timeout=600000;xhr.ontimeout=()=>reject(new Error('Upload timed out. Check the connection and retry.'));xhr.open('POST',base+'/books/upload');xhr.setRequestHeader('Authorization','Bearer '+token);xhr.upload.onprogress=e=>{if(e.lengthComputable)$('upload-progress').value=e.loaded/e.total;};xhr.onload=()=>{let value;try{value=JSON.parse(xhr.responseText);}catch{}if(xhr.status>=200&&xhr.status<300)resolve(value);else reject(new Error(value?.detail||`Upload failed (${xhr.status}).`));};xhr.onerror=()=>reject(new Error('Upload interrupted. Check the server connection and retry.'));xhr.send(form);});
  status.textContent=`Queued: ${job.title||file.name}. Conversion continues on the server.`;switchTab('jobs');await loadJobs();
 }catch(e){status.textContent=e.message;}finally{$('upload-button').disabled=false;$('upload-progress').hidden=true;}
};
async function loadJobs(){const list=$('job-list');try{await initAuth();const jobs=await(await request('/jobs',{auth:true})).json();list.replaceChildren();if(!jobs.length)list.append(element('p','No conversions yet.'));for(const job of jobs){const card=element('article',undefined,'card');card.append(element('h2',job.title||job.filename),element('p',`${job.state} · ${job.stage||''}`),element('p',job.detail||''));if(job.progress!==null&&job.progress!==undefined){const bar=element('progress');bar.max=1;bar.value=job.progress;card.append(bar);}if(job.error)card.append(element('p',job.error));if(job.needs_review_count)card.append(element('p',`${job.needs_review_count} sections need review.`));if(['failed','done'].includes(job.state))card.append(button('Retry',async()=>{await request(`/jobs/${encodeURIComponent(job.job_id)}/retry`,{auth:true,method:'POST'});await loadJobs();}));if(job.state==='done')card.append(button('Open book',()=>openBook(base,job.book_id)));list.append(card);}}catch(e){list.replaceChildren(element('p',e.message));}}
$('server-url').value=base;$('server-form').onsubmit=event=>{event.preventDefault();try{base=normalizeServer($('server-url').value);localStorage.setItem('firebrat.server',base);if(unsubAuth)unsubAuth();auth=null;audio.pause();reader=null;loadLibrary();$('server-status').textContent='Server saved.';initAuth().catch(e=>$('auth-error').textContent=e.message);}catch(e){$('server-status').textContent=e.message;}};
$('font-scale').value=String(prefs.font||1.1);document.documentElement.style.setProperty('--font-scale',prefs.font||1.1);$('font-scale').oninput=()=>{prefs.font=Number($('font-scale').value);document.documentElement.style.setProperty('--font-scale',prefs.font);savePrefs();};$('autoplay').checked=prefs.autoplay!==false;$('autoplay').onchange=()=>{prefs.autoplay=$('autoplay').checked;savePrefs();};$('autoplay-delay').value=String(prefs.delay??1);$('autoplay-delay').onchange=()=>{prefs.delay=Math.min(10,Math.max(0,Number($('autoplay-delay').value)||0));savePrefs();};$('include-pdf').checked=!!prefs.includePDF;$('include-pdf').onchange=()=>{prefs.includePDF=$('include-pdf').checked;savePrefs();};
$('refresh').onclick=loadLibrary;$('refresh-jobs').onclick=loadJobs;setInterval(()=>{if(!$('jobs').hidden&&!document.hidden)loadJobs();},4000);window.addEventListener('online',loadLibrary);window.addEventListener('offline',()=>{$('connection').textContent='Offline reading';});
if('serviceWorker'in navigator&&window.isSecureContext)navigator.serviceWorker.register(APP_BASE+'sw.js',{type:'module',scope:APP_BASE}).catch(e=>notice('Offline installation unavailable: '+e.message));
if(navigator.storage?.estimate)navigator.storage.estimate().then(s=>$('storage-status').textContent=`Browser storage: ${Math.round((s.usage||0)/1048576)} MB used of about ${Math.round((s.quota||0)/1048576)} MB available.`);
loadLibrary();if(sessionStorage.getItem('firebrat.redirect')){switchTab('settings');initAuth().catch(e=>$('auth-error').textContent=e.message);}

document.querySelector('.brand')?.addEventListener('click',event=>{event.preventDefault();switchTab('library');});
