#!/usr/bin/env node
// token_usage.js — sums real token usage for a run's [start, end] window from
// this session's own Claude Code transcript
// (~/.claude/projects/<project-slug>/<session-id>.jsonl), which records
// `usage` on every assistant message, including subagent turns (isSidechain).
// Invoked by report_tool.sh's `end` command; not meant to be called directly.
//
// Usage: token_usage.js <project_root> <session_id> <start_epoch> <end_epoch>

const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');

async function main() {
  const [, , projectRoot, sessionId, startEpochStr, endEpochStr] = process.argv;

  if (!projectRoot || !sessionId || !startEpochStr || !endEpochStr) {
    console.log('TOKENS_AVAILABLE=false');
    return;
  }

  const startMs = Number(startEpochStr) * 1000;
  const endMs = Number(endEpochStr) * 1000;
  const slug = projectRoot.replace(/\//g, '-');
  const transcriptPath = path.join(os.homedir(), '.claude', 'projects', slug, `${sessionId}.jsonl`);

  if (!fs.existsSync(transcriptPath)) {
    console.log('TOKENS_AVAILABLE=false');
    return;
  }

  const seen = new Set();
  let input = 0;
  let output = 0;
  let cacheRead = 0;
  let cacheWrite = 0;

  const rl = readline.createInterface({
    input: fs.createReadStream(transcriptPath),
    crlfDelay: Infinity,
  });

  for await (const line of rl) {
    if (!line.trim()) continue;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch {
      continue;
    }
    if (entry.type !== 'assistant') continue;

    const ts = Date.parse(entry.timestamp || '');
    if (!Number.isFinite(ts) || ts < startMs || ts > endMs) continue;

    const msg = entry.message || {};
    const usage = msg.usage;
    if (!usage || !msg.id || seen.has(msg.id)) continue;
    seen.add(msg.id);

    input += usage.input_tokens || 0;
    output += usage.output_tokens || 0;
    cacheRead += usage.cache_read_input_tokens || 0;
    cacheWrite += usage.cache_creation_input_tokens || 0;
  }

  if (seen.size === 0) {
    console.log('TOKENS_AVAILABLE=false');
    return;
  }

  const total = input + output + cacheRead + cacheWrite;
  console.log('TOKENS_AVAILABLE=true');
  console.log(`TOKENS_TOTAL=${total}`);
  console.log(`TOKENS_INPUT=${input}`);
  console.log(`TOKENS_OUTPUT=${output}`);
  console.log(`TOKENS_CACHE_READ=${cacheRead}`);
  console.log(`TOKENS_CACHE_WRITE=${cacheWrite}`);
}

main().catch(() => {
  console.log('TOKENS_AVAILABLE=false');
});
