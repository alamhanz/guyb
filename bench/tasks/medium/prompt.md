Add a function `truncate(text, max, suffix)` to src/strings.js and export it from both src/strings.js and src/index.js.

Behavior:
- Returns `text` unchanged when its length is <= `max`.
- Otherwise returns the first characters of `text` followed by `suffix`, so that the total result length is exactly `max`.
- `suffix` defaults to `'...'`.
- If `suffix` is longer than or equal to `max`, return the first `max` characters of `suffix`.
- If `max` is negative or not an integer, throw a `RangeError`.
- Non-string `text` is converted with `String()` first.

Examples: `truncate('hello world', 8)` is `'hello...'`; `truncate('hi', 8)` is `'hi'`; `truncate('hello world', 8, '~')` is `'hello w~'`; `truncate('hello', 2, '...')` is `'..'`.

Add tests for it in tests/strings.test.js (or a new test file), run `node --test` and make sure everything passes. Do not commit.
