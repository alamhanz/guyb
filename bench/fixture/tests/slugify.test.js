'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { slugify } = require('../src/slugify');

test('slugify lowercases and joins words', () => {
  assert.equal(slugify('Hello World'), 'hello-world');
});
