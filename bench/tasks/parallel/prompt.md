Implement two independent features, each in its own new module, and export both from src/index.js.

1. src/csv.js: `parseCsvLine(line)` returns an array of field strings for one CSV line. Fields are separated by commas. A field may be wrapped in double quotes, in which case it may contain commas, and a doubled quote (`""`) inside it is a literal quote. Unquoted fields are returned as-is (no trimming). An empty line returns `['']`. Example: `parseCsvLine('a,"b,c","say ""hi"""')` is `['a', 'b,c', 'say "hi"']`.

2. src/duration.js: `formatDuration(seconds)` formats a non-negative integer number of seconds as a compact string using h, m and s units, omitting zero units, joined by single spaces: `3725` is `'1h 2m 5s'`, `60` is `'1m'`, `45` is `'45s'`, `0` is `'0s'`, `7200` is `'2h'`. Negative or non-integer input throws a `RangeError`.

Add tests for each in its own test file (tests/csv.test.js and tests/duration.test.js), run `node --test` and make sure everything passes. Do not commit.
