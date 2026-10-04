'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { slugify } = require('../src/slugify');

test('collapses runs and trims', () => {
  assert.equal(slugify('  Hello,   World!! '), 'hello-world');
  assert.equal(slugify('a---b'), 'a-b');
  assert.equal(slugify('--x--'), 'x');
});

test('plain input unchanged', () => {
  assert.equal(slugify('Hello World'), 'hello-world');
  assert.equal(slugify('abc123'), 'abc123');
});

test('empty and symbol-only input', () => {
  assert.equal(slugify(''), '');
  assert.equal(slugify('!!!'), '');
});
