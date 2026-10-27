import {rangeBounds} from './range.mjs';
const SHELL_PREFIX='firebrat-shell-/firebrat/-',SHELL=SHELL_PREFIX+'c7c5f74cc2fab729', INDEX='firebrat-index-v1', INDEX_URL=new URL('/firebrat/_library',self.location.origin).href;
self.addEventListener('install',event=>event.waitUntil((async()=>{
  const cache=await caches.open(SHELL), page=await fetch('/firebrat/',{cache:'reload'});
  if(!page.ok)throw new Error('App shell unavailable');
  const html=await page.clone().text();await cache.put('/firebrat/',page);
  const paths=['/firebrat/manifest.webmanifest','/firebrat/icon-192.png','/firebrat/icon-512.png','/firebrat/range.mjs'];
  for(const match of html.matchAll(/(?:src|href)="([^"]+)"/g)){const u=new URL(match[1],self.location.origin);if(u.origin===self.location.origin&&u.pathname.startsWith('/firebrat/assets/'))paths.push(u.href);}
  await cache.addAll(paths);await self.skipWaiting();
})()));
self.addEventListener('activate',event=>event.waitUntil((async()=>{await self.clients.claim();for(const name of await caches.keys())if(name.startsWith(SHELL_PREFIX)&&name!==SHELL)await caches.delete(name);})()));
self.addEventListener('fetch',event=>{
  if(event.request.method!=='GET')return;
  event.respondWith((async()=>{
    const request=event.request,url=new URL(request.url);
    // Only committed downloads are eligible; staging caches remain private.
    const index=await(await caches.open(INDEX)).match(INDEX_URL);
    const records=index?await index.json():[];
    for(const record of records){
      if(!record.urls?.includes(request.url))continue;
      const response=await(await caches.open(record.cacheName)).match(request.url);
      if(!response)continue;
      return ranged(response,request);
    }
    if(url.origin===self.location.origin&&url.pathname.startsWith('/firebrat/')){
      const cache=await caches.open(SHELL);
      if(request.mode==='navigate' && (url.pathname==='/firebrat/'||url.pathname==='/firebrat/index.html')){
        return await cache.match('/firebrat/')||fetch(request);
      }
      const saved=await cache.match(request);if(saved)return ranged(saved,request);
      const response=await fetch(request);if(response.status===200&&!request.headers.has('range'))await cache.put(request,response.clone());return response;
    }
    return fetch(request);
  })());
});

async function ranged(response,request){
  if(!request.headers.has('range')||response.status!==200)return response;
  const blob=await response.blob(),bounds=rangeBounds(request.headers.get('range'),blob.size);
  if(!bounds)return new Response(null,{status:416,headers:{'Content-Range':`bytes */${blob.size}`}});
  const [start,end]=bounds,headers=new Headers(response.headers);
  headers.set('Content-Range',`bytes ${start}-${end}/${blob.size}`);headers.set('Content-Length',String(end-start+1));headers.set('Accept-Ranges','bytes');
  return new Response(blob.slice(start,end+1),{status:206,headers});
}
