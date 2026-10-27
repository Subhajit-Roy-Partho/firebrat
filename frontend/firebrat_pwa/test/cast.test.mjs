import {test} from 'node:test';import assert from 'node:assert/strict';
import {castAvailable} from '../src/core.mjs';
test('cast option shows only when the server reports cast_available',()=>{
  assert.equal(castAvailable({cast_available:true}),true);
  assert.equal(castAvailable({cast_available:false}),false);
  assert.equal(castAvailable({}),false);
  assert.equal(castAvailable(null),false);
  assert.equal(castAvailable(undefined),false);
});
