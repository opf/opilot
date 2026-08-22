// Plain CommonJS, no pi/typebox imports — loaded by pi-op-mcp.ts (the actual
// extension entry point, which pi's jiti loader resolves) AND by
// test/js/pi_op_mcp_test.js under plain Node, for the same reason
// pi-guards.ts carries no type annotations: this is what the test can load
// straight off disk, and it holds everything in this feature worth asserting
// — request building, the three response-format parsers, the trimmer, and
// the error mapping. pi-op-mcp.ts itself is untestable outside the harness
// image (it imports typebox and @earendil-works/pi-ai, which only jiti's
// module resolution can find), so keep new logic here, not there.
//
// The op names below MUST match opgw.js's READ_ONLY_OPS. The two run in
// different containers so the duplication is unavoidable; opgw.js is the
// authority (it decides what actually executes) — this copy only shapes the
// schema the model sees.
const OPERATIONS = Object.freeze([
  'search_work_packages', 'list_work_package_comments', 'list_work_package_relations',
  'search_projects', 'search_versions', 'list_types', 'list_statuses', 'search_custom_fields',
]);

// The flat optional fields the MCP schemas declare across these operations
// (work_package_id/custom_field_id-style identifiers, plus a few write-tool
// fields carried over for schema symmetry — the gateway is what actually
// enforces read-only, not this list). Flat fields beat one opaque `arguments`
// blob because the model sees the real parameter names instead of a nested object.
const FLAT_ARG_NAMES = Object.freeze([
  'work_package_id', 'subject', 'project_id', 'status_id', 'type_id', 'id', 'name', 'sharing', 'page',
]);

// Builds the JSON-RPC `tools/call` body opgw expects. Only the flat fields the
// caller actually set are forwarded as `arguments` — an unset optional field
// must not become a literal `null`/`undefined` the MCP server has to parse.
function buildRequestBody(params) {
  const args = {};
  for (const key of FLAT_ARG_NAMES) {
    if (params[key] !== undefined && params[key] !== null && params[key] !== '') args[key] = params[key];
  }
  return {
    jsonrpc: '2.0',
    id: 1, // one request per HTTP call, no session — see MCP.md's transport facts
    method: 'tools/call',
    params: { name: params.operation, arguments: args },
  };
}

// Parses a JSON-RPC response into `{ isError, payload }` or `{ isError: true,
// errorText }`. An administrator picks the response format instance-wide
// (Full / structured-content-only / content-only — MCP.md, "What one call
// returns"), so all three are handled: prefer `structuredContent`, else parse
// the JSON string in `content[0].text`, else fall back to the raw text.
function parseToolResult(rpc) {
  if (rpc && rpc.error) {
    return { isError: true, errorText: rpc.error.message || JSON.stringify(rpc.error) };
  }
  const result = rpc && rpc.result;
  if (!result) return { isError: true, errorText: 'the MCP server returned no result' };

  let payload;
  if (result.structuredContent !== undefined) {
    payload = result.structuredContent;
  } else if (Array.isArray(result.content) && result.content[0] && typeof result.content[0].text === 'string') {
    const text = result.content[0].text;
    try { payload = JSON.parse(text); } catch { payload = text; }
  } else {
    payload = result.content;
  }

  if (result.isError) {
    const text = typeof payload === 'string' ? payload : JSON.stringify(payload);
    return { isError: true, errorText: text };
  }
  return { isError: false, payload };
}

// A description field can arrive as a bare string or as OpenProject's usual
// `{ raw, html }` shape — accept either rather than assuming one.
function descriptionExcerpt(description, limit = 300) {
  let text = '';
  if (typeof description === 'string') text = description;
  else if (description && typeof description.raw === 'string') text = description.raw;
  else if (description && typeof description.html === 'string') text = description.html;
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
}

// A HAL-style link field (`{ href, title }`) or a plain string/name — accept
// either, since which shape the "Full" response format uses per field is not
// pinned down without a live probe of a real search_work_packages answer.
function linkTitle(value) {
  if (!value) return null;
  if (typeof value === 'string') return value;
  if (typeof value.name === 'string') return value.name;
  if (typeof value.title === 'string') return value.title;
  return null;
}

// One work-package item, trimmed to what a plan actually reads. A full item
// runs to about 8 KB (MCP.md, "What one call returns") — every date and cost
// field, the whole `_links` section — so this is the whole reason to own this
// file rather than use a generic MCP client.
function trimWorkPackageItem(item) {
  return {
    id: item.id,
    displayId: item.displayId || item.id,
    subject: item.subject,
    type: linkTitle(item.type) || linkTitle(item._links && item._links.type),
    status: linkTitle(item.status) || linkTitle(item._links && item._links.status),
    project: linkTitle(item.project) || linkTitle(item._links && item._links.project),
    updatedAt: item.updatedAt || item.updated_at || null,
    description: descriptionExcerpt(item.description),
  };
}

// The whole tool answer is capped at about 25 KB (MCP.md) — one careless call
// must not fill the context window. Truncation is noted rather than silent.
const MAX_ANSWER_BYTES = 25_000;

function cap(text) {
  if (Buffer.byteLength(text, 'utf8') <= MAX_ANSWER_BYTES) return text;
  return `${text.slice(0, MAX_ANSWER_BYTES)}\n…[truncated — answer exceeded ${MAX_ANSWER_BYTES} bytes]`;
}

// Turns a parsed MCP payload into the text handed back to the model.
// `search_work_packages` is the one operation known to return full records at
// volume (40 items/page, ~8 KB each), so it is the one operation trimmed;
// every other operation's answer is small enough to pass through as-is.
function summarize(operation, payload) {
  if (operation === 'search_work_packages' && payload && Array.isArray(payload.items)) {
    const items = payload.items.map(trimWorkPackageItem);
    return cap(JSON.stringify({ total: payload.total, returned: items.length, items }));
  }
  return cap(typeof payload === 'string' ? payload : JSON.stringify(payload));
}

// The 404 "MCP server is not available" case is a NORMAL state (no
// Enterprise add-on, or an administrator disabled it) — never a run failure.
function unavailableMessage() {
  return 'op_query: the OpenProject MCP server is not available on this instance ' +
    '(no Enterprise MCP add-on, or an administrator disabled it) — use the local mirrors instead.';
}

module.exports = {
  OPERATIONS, FLAT_ARG_NAMES, MAX_ANSWER_BYTES,
  buildRequestBody, parseToolResult, summarize, unavailableMessage,
};
