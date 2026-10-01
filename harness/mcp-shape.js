// Trims an MCP answer before the model sees it (pi-mcp.ts's tool_result
// handler). pi already coerces arguments from each tool's schema and cuts text
// over 20 KB; what it cannot know is which fields of an answer a plan reads.
// Plain CommonJS, so test/js/mcp_shape_test.js loads it under plain Node.

// An administrator picks OpenProject's answer format instance-wide (full,
// structured-only, content-only), so prefer structuredContent, else the JSON in
// content[0].text, else the raw text.
function payloadOf(result) {
  if (result.structuredContent !== undefined) return result.structuredContent;
  const text = Array.isArray(result.content) && result.content[0] && result.content[0].text;
  if (typeof text !== 'string') return result.content;
  try { return JSON.parse(text); } catch { return text; }
}

// A description arrives as a string or as OpenProject's `{ raw, html }`.
function excerpt(description, limit = 300) {
  const text = typeof description === 'string' ? description
    : (description && (description.raw || description.html)) || '';
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
}

// A HAL link (`{ href, title }`), a `{ name }` object, or a plain string.
function title(value) {
  if (!value) return null;
  if (typeof value === 'string') return value;
  return value.name || value.title || null;
}

// A full work package runs to ~8 KB (every date, cost and _links field); a
// search returns 40 of them.
function trimWorkPackage(item) {
  const links = item._links || {};
  return {
    id: item.id,
    displayId: item.displayId || item.id,
    subject: item.subject,
    type: title(item.type) || title(links.type),
    status: title(item.status) || title(links.status),
    project: title(item.project) || title(links.project),
    updatedAt: item.updatedAt || item.updated_at || null,
    description: excerpt(item.description),
  };
}

// The fields a question about a pull request, issue or commit reads. A GitHub
// record is larger than a work package; URL variants, node ids and avatars go.
const GH_KEEP = new Set([
  'number', 'title', 'state', 'draft', 'merged', 'merged_at', 'html_url',
  'sha', 'message', 'date', 'created_at', 'updated_at', 'closed_at',
  'name', 'body', 'filename', 'status', 'additions', 'deletions', 'changes',
  'total_count', 'conclusion', 'ref', 'label', 'login', 'commit', 'author',
  'user', 'labels', 'head', 'base', 'items', 'path',
]);
const GH_MAX_STRING = 600;
const GH_MAX_ITEMS = 30;
const GH_MAX_DEPTH = 3;

// A person is only their login.
function trimGitHub(value, depth = 0) {
  if (Array.isArray(value)) {
    const out = value.slice(0, GH_MAX_ITEMS).map(v => trimGitHub(v, depth + 1));
    if (value.length > GH_MAX_ITEMS) out.push(`…[${value.length - GH_MAX_ITEMS} more]`);
    return out;
  }
  if (value && typeof value === 'object') {
    if (typeof value.login === 'string') return value.login;
    if (depth >= GH_MAX_DEPTH) return undefined;
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      if (!GH_KEEP.has(k)) continue;
      const t = trimGitHub(v, depth + 1);
      if (t !== undefined) out[k] = t;
    }
    return Object.keys(out).length ? out : undefined;
  }
  if (typeof value === 'string' && value.length > GH_MAX_STRING) return `${value.slice(0, GH_MAX_STRING)}…`;
  return value;
}

function summarize(server, tool, payload) {
  if (typeof payload === 'string') return payload;
  if (server === 'openproject') {
    if (tool === 'search_work_packages' && payload && Array.isArray(payload.items)) {
      const items = payload.items.map(trimWorkPackage);
      return JSON.stringify({ total: payload.total, returned: items.length, items });
    }
    return JSON.stringify(payload);
  }
  // A payload that trims to nothing is a shape this trimmer has not seen.
  const trimmed = trimGitHub(payload);
  const empty = trimmed === undefined || (typeof trimmed === 'object' && !Object.keys(trimmed).length);
  return JSON.stringify(empty ? payload : trimmed);
}

// pi's MCP_OUTPUT_MAX_BYTES. A trimmed answer still above it keeps pi's own
// content instead, which pi has already cut and saved in full to a temp file.
const PI_LIMIT_BYTES = 20 * 1024;

// The model-facing content for one MCP CallToolResult, or null to keep pi's own.
function shapeCallResult(server, tool, result) {
  if (!result) return null;
  const payload = payloadOf(result);
  if (payload === undefined) return null;
  const text = summarize(server, tool, payload);
  if (Buffer.byteLength(text, 'utf8') > PI_LIMIT_BYTES) return null;
  return [{ type: 'text', text }];
}

module.exports = { shapeCallResult, PI_LIMIT_BYTES };
