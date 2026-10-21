import {test} from 'node:test';import assert from 'node:assert/strict';
import {normalizeServer,assetURL,activeAt,bookAssets,rangeBounds} from '../src/core.mjs';
test('server URLs reject credentials, unsafe protocols and mixed content',()=>{
 assert.equal(normalizeServer('https://books.example/','https://app.example'),'https://books.example');
 for(const v of ['javascript:alert(1)','https://user:secret@example.com','http://lan.example'])assert.throws(()=>normalizeServer(v,'https://app.example'));
 assert.equal(normalizeServer('http://localhost:8000','http://localhost:8000'),'http://localhost:8000');
});
test('asset paths cannot escape the server book directory',()=>{
 assert.equal(assetURL('https://s','book','sections/a/audio.wav'),'https://s/books/book/assets/sections/a/audio.wav');
 for(const p of ['../secret','/etc/passwd','a\\b','audio.wav?token=x'])assert.throws(()=>assetURL('https://s','book',p));
});
test('active segment respects gaps and exact boundaries',()=>{
 const list=[{start_ms:0,end_ms:100},{start_ms:120,end_ms:200}];
 assert.equal(activeAt(list,99),list[0]);assert.equal(activeAt(list,100),undefined);assert.equal(activeAt(list,120),list[1]);assert.equal(activeAt(list,200),undefined);
});
test('download list includes all audio/visuals and optional original PDF',()=>{
 const m={book_id:'b',sections:[{audio_path:'a.wav',segments_path:'s.json'}],figures:[{image_path:'f.png'}],formulas:[{image_path:''}],source_pdf_path:'source.pdf'};
 assert.equal(bookAssets('https://s',m).length,3);assert.equal(bookAssets('https://s',m,true).length,4);
});
test('Safari offline audio byte ranges, suffixes and invalid requests',()=>{
 assert.deepEqual(rangeBounds('bytes=0-99',1000),[0,99]);assert.deepEqual(rangeBounds('bytes=500-',1000),[500,999]);assert.deepEqual(rangeBounds('bytes=-100',1000),[900,999]);assert.deepEqual(rangeBounds('bytes=0-9999',1000),[0,999]);
 for(const h of ['bytes=1000-','bytes=9-1','bytes=-0','bytes=0-1,2-3','bad'])assert.equal(rangeBounds(h,1000),null);
});
