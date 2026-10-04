'use strict';
// Usage: node bench/summarize.js [results.jsonl]   (default: newest file in bench/results)
const fs = require('fs');
const path = require('path');

let file = process.argv[2];
if (!file) {
  const dir = path.join(__dirname, 'results');
  const files = fs.existsSync(dir) ? fs.readdirSync(dir).filter((f) => f.endsWith('.jsonl')).sort() : [];
  if (!files.length) {
    console.error('no results file given and none in bench/results');
    process.exit(1);
  }
  file = path.join(dir, files[files.length - 1]);
}

const rows = fs.readFileSync(file, 'utf8').split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));
const mean = (a) => (a.length ? a.reduce((x, y) => x + y, 0) / a.length : NaN);
const pct = (a, b) => (Number.isFinite(a) && Number.isFinite(b) && b > 0 ? ((a - b) / b) * 100 : NaN);
const fmtPct = (v) => (Number.isFinite(v) ? (v >= 0 ? '+' : '') + v.toFixed(0) + '%' : 'n/a');
const uniq = (a) => Array.from(new Set(a));

console.log('# guyb benchmark: ' + path.basename(file) + '\n');
console.log('Runs: ' + rows.length + '. Sample size is tiny; treat differences as anecdotes, not statistics.\n');

for (const task of uniq(rows.map((r) => r.task))) {
  const tr = rows.filter((r) => r.task === task);
  const arms = uniq(tr.map((r) => r.arm)).sort();
  const stat = {};
  console.log('## ' + task + '\n');
  console.log('| arm | n | pass rate | mean cost (USD) | mean wall (s) | models |');
  console.log('|---|---|---|---|---|---|');
  for (const arm of arms) {
    const ar = tr.filter((r) => r.arm === arm);
    const s = {
      n: ar.length,
      pass: ar.filter((r) => r.passed === true).length,
      cost: mean(ar.map((r) => r.total_cost_usd || 0)),
      wall: mean(ar.map((r) => r.wall_s)),
    };
    stat[arm] = s;
    const models = uniq([].concat(...ar.map((r) => r.models || []))).join(', ');
    console.log('| ' + [arm, s.n, s.pass + '/' + s.n, s.cost.toFixed(3), s.wall.toFixed(0), models].join(' | ') + ' |');
  }
  console.log('');
  if (stat.C) {
    console.log('| comparison | cost change | wall time change |');
    console.log('|---|---|---|');
    for (const base of ['A', 'B']) {
      if (!stat[base]) continue;
      console.log('| C vs ' + base + ' | ' + fmtPct(pct(stat.C.cost, stat[base].cost)) + ' | ' + fmtPct(pct(stat.C.wall, stat[base].wall)) + ' |');
    }
    console.log('');
  }
}

const bad = rows.filter((r) => r.error || r.is_error);
if (bad.length) console.log('Note: ' + bad.length + ' run(s) errored or hit a limit; they are included in the means.\n');
