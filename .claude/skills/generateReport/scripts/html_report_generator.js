#!/usr/bin/env node
//
// HtmlReportGenerator — renders a self-contained HTML run report from the
// same execution data used for the Markdown report. Invoked only by
// report_tool.sh ("render-html"), never called directly, so it stays behind
// that script's single allowlisted entry point.
//
// Usage: node html_report_generator.js <output-html-path>   (JSON data via stdin)

const fs = require('fs');

function esc(value) {
  if (value === null || value === undefined || value === '') return 'N/A';
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

// Like esc(), but returns '' instead of 'N/A' — for optional cells (Notes)
// where a blank is the correct display, not a missing-value placeholder.
function escBlank(value) {
  if (value === null || value === undefined) return '';
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function formatTimestamp(ts) {
  if (!ts) return null;
  const m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/.exec(String(ts));
  if (!m) return String(ts);
  const y = Number(m[1]), mo = Number(m[2]), d = Number(m[3]), h = Number(m[4]), mi = Number(m[5]);
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  let hour12 = h % 12;
  if (hour12 === 0) hour12 = 12;
  const ampm = h < 12 ? 'AM' : 'PM';
  const pad = n => String(n).padStart(2, '0');
  return `${pad(d)} ${months[mo - 1]} ${y}, ${pad(hour12)}:${pad(mi)} ${ampm}`;
}

function normalizeResult(result) {
  const r = String(result || '').trim().toLowerCase();
  if (r.includes('fail') || r.includes('❌')) return 'fail';
  if (r.includes('skip') || r.includes('⚠')) return 'skip';
  if (r.includes('pass') || r.includes('✅')) return 'pass';
  return 'skip';
}

function badge(kind) {
  const map = {
    pass: { label: 'Pass', icon: '✅', cls: 'badge-pass' },
    fail: { label: 'Fail', icon: '❌', cls: 'badge-fail' },
    skip: { label: 'Skipped', icon: '⚠️', cls: 'badge-skip' },
  };
  const m = map[kind] || map.skip;
  return `<span class="badge ${m.cls}">${m.icon} ${m.label}</span>`;
}

function render(data) {
  const steps = Array.isArray(data.steps) ? data.steps : [];
  const counts = { pass: 0, fail: 0, skip: 0 };
  steps.forEach(s => { counts[normalizeResult(s.result)]++; });
  const total = steps.length;
  const successRate = total > 0 ? Math.round((counts.pass / total) * 100) : 0;

  // API validations come straight from `api_action.sh results --json` — the
  // checks the apiCheck skill actually recorded during the run. Never a
  // hand-written summary, same rule as token counts and timestamps.
  const apiChecks = Array.isArray(data.apiChecks) ? data.apiChecks : [];
  const apiCounts = { pass: 0, fail: 0, skip: 0 };
  apiChecks.forEach(c => { apiCounts[normalizeResult(c.result)]++; });

  const overallRaw = String(data.overallResult || '').trim().toLowerCase();
  const overallPass = overallRaw
    ? (overallRaw.includes('pass') || overallRaw.includes('✅'))
    : counts.fail === 0 && apiCounts.fail === 0;
  const overallKind = overallPass ? 'pass' : 'fail';

  const execDate = formatTimestamp(data.runStart) || 'N/A';
  const tokens = data.tokens || {};

  const summaryFields = [
    ['Flow document', data.flowDoc],
    ['Precondition', data.precondition],
    ['APK', data.apk],
    ['Version Code', data.versionCode],
    ['Version Name', data.versionName],
    ['Package', data.package],
    ['Platform', data.platform],
    ['Device', data.device],
    ['Run Start', data.runStart],
    ['Run End', data.runEnd],
    ['Duration', data.duration],
    ['Total Tokens', tokens.total],
    ['Input Tokens', tokens.input],
    ['Output Tokens', tokens.output],
    ['Cache Read', tokens.cacheRead],
    ['Cache Write', tokens.cacheWrite],
  ];

  const summaryHtml = summaryFields.map(([label, value]) => `
        <div class="summary-item">
          <div class="summary-label">${esc(label)}</div>
          <div class="summary-value">${esc(value)}</div>
        </div>`).join('');

  const stepRows = steps.map((s, i) => {
    const kind = normalizeResult(s.result);
    return `
        <tr class="row-${kind}">
          <td>${esc(s.step ?? i + 1)}</td>
          <td class="mono">${escBlank(s.assertion) || 'N/A'}</td>
          <td>${badge(kind)}</td>
          <td>${escBlank(s.notes)}</td>
        </tr>`;
  }).join('');

  const apiRows = apiChecks.map(c => {
    const kind = normalizeResult(c.result);
    return `
        <tr class="row-${kind}">
          <td>${escBlank(c.name) || 'N/A'}</td>
          <td class="mono">${escBlank(c.expected) || 'N/A'}</td>
          <td class="mono">${escBlank(c.actual) || 'N/A'}</td>
          <td>${badge(kind)}</td>
          <td>${escBlank(c.notes)}</td>
        </tr>`;
  }).join('');

  const apiSectionHtml = apiChecks.length ? `
    <section class="card">
      <h2>API Validations</h2>
      <p class="section-note">Backend response checks, and comparisons of the API's values against what the app displayed — ${apiCounts.pass} passed, ${apiCounts.fail} failed.</p>
      <div class="table-wrap">
        <table>
          <thead>
            <tr><th>Check</th><th>Expected (API)</th><th>Actual</th><th>Result</th><th>Notes</th></tr>
          </thead>
          <tbody>${apiRows}
          </tbody>
        </table>
      </div>
    </section>` : '';

  const failedSteps = steps.filter(s => normalizeResult(s.result) === 'fail');
  const failedApi = apiChecks.filter(c => normalizeResult(c.result) === 'fail');
  const failureSectionHtml = (failedSteps.length || failedApi.length) ? `
    <section class="card failure-card">
      <h2>⚠️ Failure Details</h2>
      ${failedSteps.map(s => `
      <div class="failure-item">
        <div class="failure-row"><span class="failure-label">Failed Step:</span> ${esc(s.step)}</div>
        <div class="failure-row"><span class="failure-label">Assertion:</span> <span class="mono">${escBlank(s.assertion) || 'N/A'}</span></div>
        <div class="failure-row"><span class="failure-label">Failure Reason:</span> ${esc(s.notes)}</div>
        <div class="failure-row"><span class="failure-label">Timestamp:</span> ${esc(s.timestamp)}</div>
      </div>`).join('')}
      ${failedApi.map(c => `
      <div class="failure-item">
        <div class="failure-row"><span class="failure-label">Failed API Check:</span> ${esc(c.name)}</div>
        <div class="failure-row"><span class="failure-label">Expected (API):</span> <span class="mono">${escBlank(c.expected) || 'N/A'}</span></div>
        <div class="failure-row"><span class="failure-label">Actual:</span> <span class="mono">${escBlank(c.actual) || 'N/A'}</span></div>
        <div class="failure-row"><span class="failure-label">Failure Reason:</span> ${esc(c.notes)}</div>
        <div class="failure-row"><span class="failure-label">Timestamp:</span> ${esc(c.timestamp)}</div>
      </div>`).join('')}
    </section>` : '';

  const css = `
  :root {
    --bg: #f4f6fb;
    --card-bg: #ffffff;
    --text: #1f2937;
    --muted: #6b7280;
    --border: #e5e9f2;
    --pass-bg: #e6f7ec; --pass-text: #15803d; --pass-border: #bbf0cf;
    --fail-bg: #fdecec; --fail-text: #b91c1c; --fail-border: #f8c9c9;
    --skip-bg: #fff6e6; --skip-text: #b45309; --skip-border: #fbe3b5;
    --shadow: 0 6px 20px rgba(31, 41, 55, 0.06);
  }
  * { box-sizing: border-box; }
  body {
    margin: 0;
    background: var(--bg);
    color: var(--text);
    line-height: 1.5;
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  }
  .page { max-width: 1000px; margin: 0 auto; padding: 32px 20px 64px; }
  .hero {
    background: linear-gradient(135deg, #ffffff, #eef1fb);
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 28px 32px;
    box-shadow: var(--shadow);
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 24px;
    flex-wrap: wrap;
    margin-bottom: 24px;
  }
  .eyebrow { text-transform: uppercase; letter-spacing: .08em; font-size: .75rem; color: var(--muted); font-weight: 600; }
  .hero h1 { margin: .2em 0; font-size: 1.9rem; }
  .meta-line { color: var(--muted); font-size: .95rem; }
  .badge {
    display: inline-flex; align-items: center; gap: 6px;
    padding: 4px 12px; border-radius: 999px;
    font-weight: 600; font-size: .85rem; border: 1px solid transparent;
    white-space: nowrap;
  }
  .badge-pass { background: var(--pass-bg); color: var(--pass-text); border-color: var(--pass-border); }
  .badge-fail { background: var(--fail-bg); color: var(--fail-text); border-color: var(--fail-border); }
  .badge-skip { background: var(--skip-bg); color: var(--skip-text); border-color: var(--skip-border); }
  .badge-lg { font-size: 1.1rem; padding: 10px 22px; }
  .card {
    background: var(--card-bg); border: 1px solid var(--border); border-radius: 16px;
    padding: 24px 28px; box-shadow: var(--shadow); margin-bottom: 24px;
  }
  .card h2 { margin-top: 0; font-size: 1.15rem; }
  .section-note { margin: -6px 0 14px; color: var(--muted); font-size: .85rem; }
  .summary-card { padding: 0; }
  .summary-card > summary {
    cursor: pointer;
    list-style: none;
    padding: 14px 20px;
    font-size: 1rem;
    font-weight: 600;
    display: flex;
    align-items: center;
    justify-content: space-between;
    user-select: none;
    border-radius: 16px;
  }
  .summary-card > summary::-webkit-details-marker { display: none; }
  .summary-card > summary::after {
    content: '▸';
    color: var(--muted);
    font-size: .85rem;
    transition: transform .15s ease;
  }
  .summary-card[open] > summary { border-radius: 16px 16px 0 0; }
  .summary-card[open] > summary::after { transform: rotate(90deg); }
  .summary-card > summary:hover { background: #f8f9fd; }
  .summary-body { padding: 4px 20px 14px; border-top: 1px solid var(--border); }
  .summary-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 4px 20px; }
  .summary-item { padding: 5px 0; border-bottom: 1px dashed var(--border); }
  .summary-label { font-size: .68rem; text-transform: uppercase; letter-spacing: .05em; color: var(--muted); margin-bottom: 1px; }
  .summary-value { font-size: .84rem; font-weight: 500; word-break: break-word; }
  .table-wrap { overflow-x: auto; }
  table { width: 100%; border-collapse: collapse; min-width: 560px; }
  thead th {
    position: sticky; top: 0; background: #f8f9fd; text-align: left;
    padding: 12px 14px; font-size: .8rem; text-transform: uppercase; letter-spacing: .04em;
    color: var(--muted); border-bottom: 2px solid var(--border);
  }
  tbody td { padding: 12px 14px; border-bottom: 1px solid var(--border); vertical-align: top; font-size: .92rem; }
  tbody tr:nth-child(even) { background: #fafbfe; }
  tbody tr:hover { background: #f0f3ff; }
  .mono { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: .85rem; }
  .empty { text-align: center; color: var(--muted); padding: 24px; }
  .stats-grid { display: grid; grid-template-columns: repeat(5, 1fr); gap: 16px; text-align: center; }
  .stat { padding: 16px 8px; border-radius: 12px; background: #f8f9fd; }
  .stat-value { font-size: 1.6rem; font-weight: 700; }
  .stat-label { font-size: .78rem; color: var(--muted); text-transform: uppercase; letter-spacing: .04em; margin-top: 4px; }
  .stat-pass .stat-value { color: var(--pass-text); }
  .stat-fail .stat-value { color: var(--fail-text); }
  .stat-skip .stat-value { color: var(--skip-text); }
  .failure-card { border-color: var(--fail-border); background: #fff9f9; }
  .failure-item { padding: 14px 0; border-bottom: 1px dashed var(--fail-border); }
  .failure-item:last-child { border-bottom: none; }
  .failure-row { margin: 4px 0; font-size: .92rem; }
  .failure-label { font-weight: 600; color: var(--fail-text); margin-right: 6px; }
  .footer { text-align: center; color: var(--muted); font-size: .8rem; margin-top: 12px; }

  @media (max-width: 720px) {
    .page { padding: 20px 12px 48px; }
    .hero { padding: 20px; }
    .summary-grid { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    .stats-grid { grid-template-columns: repeat(2, 1fr); }
    .hero h1 { font-size: 1.5rem; }
  }`;

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(data.flowName)} — Run Report</title>
<style>${css}
</style>
</head>
<body>
  <div class="page">
    <header class="hero">
      <div class="hero-text">
        <div class="eyebrow">Run Report</div>
        <h1>${esc(data.flowName)}</h1>
        <div class="meta-line">Executed on: ${esc(execDate)} &nbsp;·&nbsp; Duration: ${esc(data.duration)}</div>
      </div>
      <div class="badge badge-lg ${overallKind === 'pass' ? 'badge-pass' : 'badge-fail'}">
        ${overallKind === 'pass' ? '✅ PASS' : '❌ FAIL'}
      </div>
    </header>

    <details class="card summary-card">
      <summary>Execution Summary</summary>
      <div class="summary-body">
        <div class="summary-grid">${summaryHtml}
        </div>
      </div>
    </details>

    <section class="card">
      <h2>Step Results</h2>
      <div class="table-wrap">
        <table>
          <thead>
            <tr><th>Step</th><th>Assertion</th><th>Result</th><th>Notes</th></tr>
          </thead>
          <tbody>${stepRows || `
          <tr><td colspan="4" class="empty">No steps recorded</td></tr>`}
          </tbody>
        </table>
      </div>
    </section>

    ${apiSectionHtml}
    <section class="card stats-card">
      <h2>Statistics</h2>
      <div class="stats-grid">
        <div class="stat"><div class="stat-value">${total}</div><div class="stat-label">Total Steps</div></div>
        <div class="stat stat-pass"><div class="stat-value">${counts.pass}</div><div class="stat-label">Passed</div></div>
        <div class="stat stat-fail"><div class="stat-value">${counts.fail}</div><div class="stat-label">Failed</div></div>
        <div class="stat stat-skip"><div class="stat-value">${counts.skip}</div><div class="stat-label">Skipped</div></div>
        <div class="stat"><div class="stat-value">${successRate}%</div><div class="stat-label">Success Rate</div></div>
      </div>
    </section>
    ${failureSectionHtml}
    <div class="footer">Generated automatically — self-contained report, no external dependencies.</div>
  </div>
</body>
</html>
`;
}

function main() {
  const outPath = process.argv[2];
  if (!outPath) {
    console.error('Usage: html_report_generator.js <output-html-path>  (JSON data via stdin)');
    process.exit(1);
  }

  let raw;
  try {
    raw = fs.readFileSync(0, 'utf8');
  } catch (e) {
    console.error('Failed to read JSON from stdin: ' + e.message);
    process.exit(1);
  }

  let data;
  try {
    data = JSON.parse(raw);
  } catch (e) {
    console.error('Invalid JSON on stdin: ' + e.message);
    process.exit(1);
  }

  const html = render(data);
  fs.writeFileSync(outPath, html, 'utf8');
  console.log('HTML report written to ' + outPath);
}

main();
