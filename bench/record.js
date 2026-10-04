'use strict';
// Helper for run.sh. Usage:
//   node record.js cost <raw.json>                  prints total_cost_usd (0 if unparsable)
//   node record.js record <raw.json> key=value ...  prints one JSONL result line
const fs = require('fs');

function load(file) {
  try {
    const j = JSON.parse(fs.readFileSync(file, 'utf8'));
    const r = Array.isArray(j) ? j.filter((e) => e && e.type === 'result').pop() : j;
    return r && typeof r === 'object' ? r : null;
  } catch (e) {
    return null;
  }
}

const [mode, file, ...rest] = process.argv.slice(2);
const res = load(file);

if (mode === 'cost') {
  console.log(res && typeof res.total_cost_usd === 'number' ? res.total_cost_usd : 0);
  process.exit(0);
}

const meta = {};
for (const kv of rest) {
  const i = kv.indexOf('=');
  const k = kv.slice(0, i);
  const v = kv.slice(i + 1);
  meta[k] = /^-?\d+(\.\d+)?$/.test(v) ? Number(v) : v === 'true' ? true : v === 'false' ? false : v;
}

const line = Object.assign({}, meta);
if (!res) {
  Object.assign(line, { error: 'unparsable claude output', total_cost_usd: 0 });
} else {
  const mu = res.modelUsage || {};
  const sum = { input: 0, output: 0, cache_read: 0, cache_creation: 0, cost: 0 };
  for (const m of Object.keys(mu)) {
    sum.input += mu[m].inputTokens || 0;
    sum.output += mu[m].outputTokens || 0;
    sum.cache_read += mu[m].cacheReadInputTokens || 0;
    sum.cache_creation += mu[m].cacheCreationInputTokens || 0;
    sum.cost += mu[m].costUSD || 0;
  }
  const multi = Object.keys(mu).length > 1;
  Object.assign(line, {
    models: Object.keys(mu),
    cost_by_model: Object.fromEntries(Object.keys(mu).map((m) => [m, mu[m].costUSD])),
    total_cost_usd: res.total_cost_usd,
    // total_cost_usd equals the sum over every model in modelUsage (subagent models included)
    cost_includes_subagents: multi ? Math.abs(sum.cost - res.total_cost_usd) < 1e-6 : null,
    // tokens summed over modelUsage (all models); top-level `usage` covers the main thread only
    tokens_all_models: sum,
    usage_top_level: res.usage
      ? {
          input: res.usage.input_tokens,
          output: res.usage.output_tokens,
          cache_read: res.usage.cache_read_input_tokens,
          cache_creation: res.usage.cache_creation_input_tokens,
        }
      : null,
    num_turns: res.num_turns,
    subagents_spawned: res.subagent_stats ? res.subagent_stats.spawned : null,
    permission_denials: Array.isArray(res.permission_denials) ? res.permission_denials.length : null,
    is_error: !!res.is_error,
    subtype: res.subtype,
    duration_ms: res.duration_ms,
    duration_api_ms: res.duration_api_ms,
  });
}
console.log(JSON.stringify(line));
