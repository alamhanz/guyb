'use strict';

function capitalize(text) {
  const s = String(text);
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function padLeft(text, width, ch = ' ') {
  return String(text).padStart(width, ch);
}

module.exports = { capitalize, padLeft };
