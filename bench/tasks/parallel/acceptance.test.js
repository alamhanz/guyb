'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const index = require('../src/index');
const { parseCsvLine } = require('../src/csv');
const { formatDuration } = require('../src/duration');

test('parseCsvLine', () => {
  assert.deepEqual(parseCsvLine('a,b,c'), ['a', 'b', 'c']);
  assert.deepEqual(parseCsvLine('a,"b,c","say ""hi"""'), ['a', 'b,c', 'say "hi"']);
  assert.deepEqual(parseCsvLine(''), ['']);
  assert.deepEqual(parseCsvLine('a,,c'), ['a', '', 'c']);
  assert.deepEqual(parseCsvLine(' x , y '), [' x ', ' y ']);
  assert.deepEqual(parseCsvLine('""'), ['']);
});

test('formatDuration', () => {
  assert.equal(formatDuration(3725), '1h 2m 5s');
  assert.equal(formatDuration(60), '1m');
  assert.equal(formatDuration(45), '45s');
  assert.equal(formatDuration(0), '0s');
  assert.equal(formatDuration(7200), '2h');
  assert.equal(formatDuration(3601), '1h 1s');
});

test('formatDuration validation', () => {
  assert.throws(() => formatDuration(-1), RangeError);
  assert.throws(() => formatDuration(1.5), RangeError);
});

test('exported from index, existing exports intact', () => {
  assert.equal(typeof index.parseCsvLine, 'function');
  assert.equal(typeof index.formatDuration, 'function');
  assert.equal(typeof index.slugify, 'function');
});
