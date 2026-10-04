'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { mean, max } = require('../src/stats');

test('mean', () => {
  assert.equal(mean([1, 2, 3]), 2);
});

test('max', () => {
  assert.equal(max([1, 5, 3]), 5);
});
