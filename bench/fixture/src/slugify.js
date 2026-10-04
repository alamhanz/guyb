'use strict';

// Turn text into a lowercase, hyphen-separated URL slug.
function slugify(text) {
  return String(text)
    .toLowerCase()
    .replace(/[^a-z0-9]/g, '-');
}

module.exports = { slugify };
