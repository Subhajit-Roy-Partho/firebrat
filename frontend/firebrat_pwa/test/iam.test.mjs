import {test} from 'node:test';import assert from 'node:assert/strict';
import {iamEnabled,needsSetup,roleOf,canUpload,canSeeAdmin,friendlyAuthError} from '../src/core.mjs';
test('iam_enabled gates setup/admin/role UI; missing or null stays off',()=>{
  assert.equal(iamEnabled({iam_enabled:true}),true);
  for(const s of [{iam_enabled:false},{},null,undefined])assert.equal(iamEnabled(s),false);
});
test('needs_setup is true only when the server reports no admin yet',()=>{
  assert.equal(needsSetup({needs_setup:true}),true);
  for(const m of [{needs_setup:false},{},null,undefined])assert.equal(needsSetup(m),false);
});
test('roleOf keeps admin/user/viewer and drops anything else',()=>{
  assert.equal(roleOf({role:'admin'}),'admin');assert.equal(roleOf({role:'user'}),'user');assert.equal(roleOf({role:'viewer'}),'viewer');
  for(const m of [{role:null},{role:'owner'},{role:''},{},null,undefined])assert.equal(roleOf(m),null);
});
test('upload stays open when IAM is off; user+ only when on',()=>{
  const off={iam_enabled:false},on={iam_enabled:true};
  for(const m of [null,{role:null},{role:'viewer'}])assert.equal(canUpload(m,off),true);
  assert.equal(canUpload({role:'admin'},on),true);assert.equal(canUpload({role:'user'},on),true);
  for(const m of [{role:'viewer'},{role:null},{},null,undefined])assert.equal(canUpload(m,on),false);
});
test('only admins see the server administration section',()=>{
  assert.equal(canSeeAdmin({role:'admin'}),true);
  for(const m of [{role:'user'},{role:'viewer'},{role:null},{},null,undefined])assert.equal(canSeeAdmin(m),false);
});
test('403 maps to a friendly message; other statuses pass detail through',()=>{
  assert.equal(friendlyAuthError(403,'Forbidden'), 'Your account is not allowed to do that. Ask a server admin for access.');
  assert.equal(friendlyAuthError(404,'Missing'), 'Missing');
  assert.equal(friendlyAuthError(500), 'Server returned 500.');
});
