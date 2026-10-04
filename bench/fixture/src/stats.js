'use strict';

function mean(nums) {
  if (nums.length === 0) return 0;
  return nums.reduce((a, b) => a + b, 0) / nums.length;
}

function max(nums) {
  return Math.max(...nums);
}

module.exports = { mean, max };
