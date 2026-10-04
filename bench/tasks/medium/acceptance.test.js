'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const strings = require('../src/strings');
const index = require('../src/index');

test('truncate basics', () => {
  const { truncate } = strings;
  assert.equal(truncate('hello world', 8), 'hello...');
  assert.equal(truncate('hi', 8), 'hi');
  assert.equal(truncate('exactly8', 8), 'exactly8');
  assert.equal(truncate('hello world', 8, '~'), 'hello w~');
  assert.equal(truncate(12345, 4, ''), '1234');
});

test('truncate short max', () => {
  const { truncate } = strings;
  assert.equal(truncate('hello', 2, '...'), '..');
  assert.equal(truncate('hello', 0), '');
});

test('truncate validation', () => {
  const { truncate } = strings;
  assert.throws(() => truncate('x', -1), RangeError);
  assert.throws(() => truncate('x', 1.5), RangeError);
});

test('exported from index and existing exports intact', () => {
  assert.equal(typeof index.truncate, 'function');
  assert.equal(typeof index.slugify, 'function');
  assert.equal(typeof index.mean, 'function');
  assert.equal(index.capitalize('a'), 'A');
});
