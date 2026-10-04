'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { capitalize, padLeft } = require('../src/strings');

test('capitalize', () => {
  assert.equal(capitalize('abc'), 'Abc');
});

test('padLeft', () => {
  assert.equal(padLeft('7', 3, '0'), '007');
});
