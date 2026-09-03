// Plain CommonJS twin of op-mcp-client.js, for GitHub's MCP upstream. Loaded by
// pi-mcp.ts (the extension entry point, which pi's jiti loader resolves) AND by
// test/js/gh_mcp_client_test.js under plain Node — so, for the same reason as
// its OpenProject sibling, everything worth asserting lives here rather than in
// the .ts half: request building, response parsing, the trimmer, the cap.
//
// The op names below MUST match GH_READ_ONLY_OPS in mcp-gw.js. The two run in
// different containers, so the duplication is unavoidable; mcp-gw.js is the
// authority (it decides what actually executes) — this copy only shapes the
// schema the model sees.
//
// Six operations, and deliberately none about refs. `git for-each-ref
// --contains` in the clones answers "which tags or branches contain this
// commit" with no network at all, so list_tags/list_releases/list_branches
// would only be a slower second answer. What is here is what a clone cannot do.
const OPERATIONS = Object.freeze([
  'pull_request_read', 'list_pull_requests',
  'issue_read', 'list_issues',
  'get_commit', 'list_commits',
]);

// The flat fields these six declare. `owner` and `repo` are required by every
// one of them, which is what lets mcp-gw.js pin the repository with an exact
// comparison rather than a substring test on a free-text query.
const FLAT_ARG_NAMES = Object.freeze([
  'owner', 'repo', 'method', 'pullNumber', 'issue_number', 'sha', 'path',
  'author', 'state', 'base', 'head', 'since', 'until', 'page', 'perPage',
]);

// Declared as numbers by the upstream schema. A model routinely stringifies a
// number whatever the schema says, and the upstream's own error ("value at
// `/pullNumber` is not a number") names no fix, so it retries forever.
const NUMERIC_ARG_NAMES = Object.freeze(['pullNumber', 'issue_number', 'page', 'perPage']);

function coerceArg(key, value) {
  if (!NUMERIC_ARG_NAMES.includes(key)) return value;
  if (typeof value === 'number') return value;
  if (typeof value === 'string' && /^-?\d+$/.test(value.trim())) return Number(value.trim());
  return value;
}

// Builds the JSON-RPC `tools/call` body mcp-gw expects. Only the flat fields
// actually set are forwarded, so an unset optional field is absent rather than
// null — the upstream rejects a null where it wants a string.
function buildRequestBody(params) {
  const args = {};
  for (const key of FLAT_ARG_NAMES) {
    if (params[key] !== undefined && params[key] !== null && params[key] !== '') {
      args[key] = coerceArg(key, params[key]);
    }
  }
  return {
    jsonrpc: '2.0',
    id: 1, // one request per HTTP call; a live probe confirmed GitHub's
           // endpoint needs no `initialize` and issues no session id
    method: 'tools/call',
    params: { name: params.operation, arguments: args },
  };
}

// Same three response shapes op-mcp-client.js handles, for the same reason:
// prefer `structuredContent`, else parse the JSON string in `content[0].text`,
// else fall back to the raw text.
function parseToolResult(rpc) {
  if (rpc && rpc.error) {
    return { isError: true, errorText: rpc.error.message || JSON.stringify(rpc.error) };
  }
  const result = rpc && rpc.result;
  if (!result) return { isError: true, errorText: 'the GitHub MCP server returned no result' };

  let payload;
  if (result.structuredContent !== undefined) {
    payload = result.structuredContent;
  } else if (Array.isArray(result.content) && result.content[0] && typeof result.content[0].text === 'string') {
    try {
      payload = JSON.parse(result.content[0].text);
    } catch {
      payload = result.content[0].text;
    }
  } else {
    payload = result.content;
  }

  if (result.isError) {
    const text = typeof payload === 'string' ? payload : JSON.stringify(payload);
    return { isError: true, errorText: text };
  }
  return { isError: false, payload };
}

// The fields a question about a pull request, an issue or a commit actually
// reads. Everything else GitHub returns — URL variants, node ids, avatar links,
// permissions blocks — is dropped. A single pull request record is larger than
// the ~8 KB work-package records that forced op-mcp-client.js to trim, so this
// is not tidiness.
const KEEP = new Set([
  'number', 'title', 'state', 'draft', 'merged', 'merged_at', 'html_url',
  'sha', 'message', 'date', 'created_at', 'updated_at', 'closed_at',
  'name', 'body', 'filename', 'status', 'additions', 'deletions', 'changes',
  'total_count', 'conclusion', 'ref', 'label', 'login', 'commit', 'author',
  'user', 'labels', 'head', 'base', 'items', 'path',
]);

const MAX_STRING = 600;
const MAX_ITEMS = 30;
const MAX_DEPTH = 3;

// A person is only ever their login here; the rest of a GitHub user object is
// avatar and API-URL noise.
function trim(value, depth = 0) {
  if (Array.isArray(value)) {
    const out = value.slice(0, MAX_ITEMS).map(v => trim(v, depth + 1));
    if (value.length > MAX_ITEMS) out.push(`…[${value.length - MAX_ITEMS} more]`);
    return out;
  }
  if (value && typeof value === 'object') {
    if (typeof value.login === 'string') return value.login;
    if (depth >= MAX_DEPTH) return undefined;
    const out = {};
    for (const [k, v] of Object.entries(value)) {
      if (!KEEP.has(k)) continue;
      const t = trim(v, depth + 1);
      if (t !== undefined) out[k] = t;
    }
    return Object.keys(out).length ? out : undefined;
  }
  if (typeof value === 'string' && value.length > MAX_STRING) {
    return `${value.slice(0, MAX_STRING)}…`;
  }
  return value;
}

// Capped for the same reason as the OpenProject side: one careless call must
// not fill the context window, and truncation is noted rather than silent.
const MAX_ANSWER_BYTES = 25_000;

function cap(text) {
  if (Buffer.byteLength(text, 'utf8') <= MAX_ANSWER_BYTES) return text;
  return `${text.slice(0, MAX_ANSWER_BYTES)}\n…[truncated — answer exceeded ${MAX_ANSWER_BYTES} bytes]`;
}

// Turns a parsed MCP payload into the text handed back to the model. A payload
// that trims to nothing is returned raw instead: an empty object tells the
// model less than an answer it can read, and a shape this trimmer has not seen
// is exactly when it must not make things worse.
function summarize(_operation, payload) {
  if (typeof payload === 'string') return cap(payload);
  const trimmed = trim(payload);
  if (trimmed === undefined || (typeof trimmed === 'object' && !Object.keys(trimmed).length)) {
    return cap(JSON.stringify(payload));
  }
  return cap(JSON.stringify(trimmed));
}

// The GitHub route is off unless a read token is configured, so this is what a
// 404 from the gateway means — not a broken upstream.
function unavailableMessage() {
  return 'gh_query: the GitHub MCP route is not configured on this deployment — ' +
    'use the local repository clones instead.';
}

module.exports = {
  OPERATIONS, FLAT_ARG_NAMES, NUMERIC_ARG_NAMES, KEEP, MAX_ANSWER_BYTES,
  buildRequestBody, parseToolResult, trim, summarize, unavailableMessage,
};
