// What mcp-gw does to a tools/call besides allowing it: coerce numeric ids in
// the request, and trim the answer before it reaches the model. Both used to
// live in the harness's own MCP client; with pi's native client the gateway is
// the one place that sees every call.

// The fields each upstream types as `number`. A model routinely stringifies a
// number whatever the schema says, and the server's "value at `/project_id` is
// not a number" names no fix, so the model retries the same call.
const NUMERIC_ARGS = {
  openproject: ['work_package_id', 'project_id', 'status_id', 'type_id', 'id', 'page'],
  github: ['issue_number', 'page', 'perPage', 'pullNumber'],
};

// A non-integer string (a `TTP2` identifier) is left for the server to reject.
function coerce(value) {
  if (Array.isArray(value)) return value.map(coerce);
  if (typeof value === 'string' && /^-?\d+$/.test(value.trim())) return Number(value.trim());
  return value;
}

function coerceArgs(server, args) {
  if (!args || typeof args !== 'object') return args;
  const out = { ...args };
  for (const key of NUMERIC_ARGS[server] || []) {
    if (key in out) out[key] = coerce(out[key]);
  }
  return out;
}

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

// One careless call must not fill the context window; truncation is said.
const MAX_ANSWER_BYTES = 25_000;

function cap(text) {
  if (Buffer.byteLength(text, 'utf8') <= MAX_ANSWER_BYTES) return text;
  return `${text.slice(0, MAX_ANSWER_BYTES)}\n…[truncated — answer exceeded ${MAX_ANSWER_BYTES} bytes]`;
}

function summarize(server, tool, payload) {
  if (typeof payload === 'string') return cap(payload);
  if (server === 'openproject') {
    if (tool === 'search_work_packages' && payload && Array.isArray(payload.items)) {
      const items = payload.items.map(trimWorkPackage);
      return cap(JSON.stringify({ total: payload.total, returned: items.length, items }));
    }
    return cap(JSON.stringify(payload));
  }
  // A payload that trims to nothing is a shape this trimmer has not seen.
  const trimmed = trimGitHub(payload);
  const empty = trimmed === undefined || (typeof trimmed === 'object' && !Object.keys(trimmed).length);
  return cap(JSON.stringify(empty ? payload : trimmed));
}

// Rewrites a tools/call JSON-RPC answer to one trimmed text block.
// structuredContent is dropped: pi hands the model `content`, and keeping the
// untrimmed copy beside it would undo the trim for any consumer that reads it.
function shapeResult(server, tool, rpc) {
  if (!rpc || !rpc.result) return rpc;
  const payload = payloadOf(rpc.result);
  if (payload === undefined) return rpc;
  const text = summarize(server, tool, payload);
  const result = { content: [{ type: 'text', text }] };
  if (rpc.result.isError) result.isError = true;
  return { ...rpc, result };
}

module.exports = { NUMERIC_ARGS, MAX_ANSWER_BYTES, coerceArgs, shapeResult, trimGitHub };
