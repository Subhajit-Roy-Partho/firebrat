import {readFile,writeFile,readdir} from 'node:fs/promises';
import {createHash} from 'node:crypto';
const root=process.env.FIREBRAT_PWA_OUT?new URL(process.env.FIREBRAT_PWA_OUT.replace(/\/?$/,'/'),new URL('../',import.meta.url)):new URL('../../../backend/server/static/pwa/',import.meta.url);
const hash=createHash('sha256');
async function walk(directory,prefix=''){
 for(const entry of (await readdir(directory,{withFileTypes:true})).sort((a,b)=>a.name.localeCompare(b.name))){
  const name=prefix+entry.name,url=new URL(entry.name+(entry.isDirectory()?'/':''),directory);
  if(entry.isDirectory())await walk(url,name+'/');else hash.update(name).update(await readFile(url));
 }
}
await walk(root);
const id=hash.digest('hex').slice(0,16),base=process.env.VITE_APP_BASE||'/pwa/';
const sw=new URL('sw.js',root);await writeFile(sw,(await readFile(sw,'utf8')).replaceAll('__BUILD_ID__',id).replaceAll('__APP_BASE__',base));
const manifest=new URL('manifest.webmanifest',root);await writeFile(manifest,(await readFile(manifest,'utf8')).replaceAll('/pwa/',base));
