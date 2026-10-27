import {test} from 'node:test';import assert from 'node:assert/strict';
import {showSetup,showAdmin,setupError,validateSetupCode,validateInvite,normalizeUsers,normalizeOptions,optionLabel,optionNote,settingsToForm,formToSettings,normalizeQueue,canReorder,canCancel} from '../src/core.mjs';
test('setup shows only when IAM is on and no admin exists; admin UI only for admins',()=>{
  assert.equal(showSetup({needs_setup:true,iam_enabled:true},null),true);
  assert.equal(showSetup({needs_setup:true},{iam_enabled:true}),true);
  assert.equal(showSetup({needs_setup:true},{iam_enabled:false}),false);
  assert.equal(showSetup({needs_setup:false,iam_enabled:true},{iam_enabled:true}),false);
  assert.equal(showAdmin({role:'admin',iam_enabled:true},{iam_enabled:true}),true);
  assert.equal(showAdmin({role:'admin',iam_enabled:false},{iam_enabled:false}),true); // legacy admin
  assert.equal(showAdmin({role:'user'},{iam_enabled:true}),false);
  assert.equal(showAdmin(null,{iam_enabled:false}),false);
});
test('setup errors are friendly',()=>{
  assert.match(setupError(403),/not correct/);assert.match(setupError(410),/already/);assert.match(setupError(429),/10 minutes/);
  assert.equal(setupError(500,'boom'),'boom');
  assert.equal(validateSetupCode('  ').ok,false);assert.equal(validateSetupCode(' ABC123 ').code,'ABC123');
});
test('invite validation lowercases email and checks role',()=>{
  assert.deepEqual(validateInvite(' A@B.org ','user').payload,{email:'a@b.org',role:'user'});
  assert.equal(validateInvite('nope','user').ok,false);assert.equal(validateInvite('a@b.org','root').ok,false);
});
test('normalizeUsers handles {users,invites}, arrays, and hides claimed invites',()=>{
  const r=normalizeUsers({users:[{uid:'u1',email:'a@b.c',role:'admin',status:'disabled'}],invites:[{email:'x@y.z',role:'viewer'},{email:'d@e.f',role:'user',claimed_uid:'u9'}]});
  assert.deepEqual(r.users[0],{key:'u1',email:'a@b.c',name:'',role:'admin',active:false});
  assert.deepEqual(r.invites,[{email:'x@y.z',role:'viewer',claimed:false}]);
  assert.equal(normalizeUsers([{uid:'u'}]).users.length,1);assert.deepEqual(normalizeUsers(null),{users:[],invites:[]});
});
const OPTS={llm:{models:[{id:'qwen3.5-9b',name:'Qwen 9B',vram_gb:11,available:false,description:'Best'}],quantizations:['fp8']},tts:{engines:[{id:'chatterbox',vram_gb:5,available:true}]},run_pattern:{phase_modes:['batched','sequential'],audio_orders:['fifo'],max_books_range:[1,20]}};
test('options normalise and warn about missing weights',()=>{
  const o=normalizeOptions(OPTS);
  assert.equal(o.llm[0].id,'qwen3.5-9b');assert.deepEqual(o.quantizations,['fp8']);assert.deepEqual(o.audioOrders,['fifo']);
  assert.match(optionLabel(o.llm[0]),/11 GB VRAM.*weights not downloaded/);
  assert.match(optionNote(o.llm[0]),/not downloaded/);assert.doesNotMatch(optionNote(o.tts[0]),/not downloaded/);
  const flat=normalizeOptions({llm_model:[{id:'a'}],tts_engine:[{id:'b'}],quantization:['fp8']});assert.equal(flat.llm[0].id,'a');assert.equal(flat.tts[0].id,'b');
  assert.deepEqual(normalizeOptions(null).maxBooks,[1,20]);
});
const VALUES={llm:{model:'qwen3.5-9b',quantization:'fp8'},tts:{engine:'chatterbox'},run_pattern:{phase_mode:'batched',max_books_per_llm_phase:4,audio_order:'shortest_first',paused:false,quiet_hours:{start:'22:00',end:'06:00'}},limits:{max_upload_mb:200,max_cast_chars:1000000}};
test('form <-> payload round trip keeps untouched keys',()=>{
  const f=settingsToForm(VALUES);assert.equal(f.quietStart,'22:00');assert.equal(f.maxBooks,'4');
  const r=formToSettings(VALUES,f);assert.equal(r.ok,true);assert.deepEqual(r.values,VALUES);
  assert.deepEqual(VALUES.limits,{max_upload_mb:200,max_cast_chars:1000000});
});
test('form validation: range, quiet hours pair, no free choices missing',()=>{
  const f=settingsToForm(VALUES);
  assert.equal(formToSettings(VALUES,{...f,maxBooks:'0'}).ok,false);assert.equal(formToSettings(VALUES,{...f,maxBooks:'2.5'}).ok,false);assert.equal(formToSettings(VALUES,{...f,maxBooks:'21'}).ok,false);
  assert.equal(formToSettings(VALUES,{...f,quietEnd:''}).ok,false);assert.equal(formToSettings(VALUES,{...f,quietStart:'08:00',quietEnd:'08:00'}).ok,false);
  const none=formToSettings(VALUES,{...f,quietStart:'',quietEnd:''});assert.equal(none.values.run_pattern.quiet_hours,null);
  assert.equal(formToSettings(VALUES,{...f,llmModel:''}).ok,false);
  assert.equal(formToSettings({},{...f}).ok,true);
});
test('queue normalisation and per-book actions',()=>{
  const q=normalizeQueue({paused:true,scheduler:{available:true,running:false,detail:'idle',books:[{slug:'a',stage:'queued',progress:0.456},{slug:'b',stage:'done',terminal:'done',progress:1},{nope:1}]}});
  assert.equal(q.paused,true);assert.match(q.state,/Paused/);assert.equal(q.books.length,2);assert.equal(q.books[0].percent,46);
  assert.equal(canReorder(q.books[0]),true);assert.equal(canReorder(q.books[1]),false);assert.equal(canCancel(q.books[1]),false);
  assert.match(normalizeQueue({scheduler:{available:false}}).state,/not running/);assert.equal(normalizeQueue(null).books.length,0);
});
