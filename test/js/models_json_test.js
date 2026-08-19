// Plain-Node test for server.js's models.json generation and model-id
// validation. No test framework (the repo has none for JS): run with
// `node test/js/models_json_test.js`.
//
// The generated file is what points pi at a self-hosted upstream. Nothing else
// checks it — a wrong provider name or a missing compat flag surfaces as an
// opaque pi start-up error three layers away.
const assert = require('assert');
const { buildModelsJson, providerPrefix, MODEL_RE, ALLOWED_TOOL_GRANTS } = require('../../server.js');

let failures = 0;
function test(name, fn) {
  try {
    fn();
    console.log(`PASS ${name}`);
  } catch (e) {
    failures++;
    console.log(`FAIL ${name}\n  ${e.message}`);
  }
}

const only = obj => {
  const names = Object.keys(obj.providers);
  assert.strictEqual(names.length, 1, `expected one provider, got ${names}`);
  return { name: names[0], config: obj.providers[names[0]] };
};

// ── the model id regex ────────────────────────────────────────────────────

test('an Ollama-style id with a colon is accepted', () => {
  // The colon was missing from the character class, so every Ollama tag was
  // rejected as "malformed model". Every id below is a real-world shape.
  for (const id of ['local/qwen2.5-coder:7b', 'local/gpt-oss:20b', 'selfhosted/llama3.1:8b']) {
    assert.ok(MODEL_RE.test(id), `${id} should be accepted`);
  }
});

test('the existing OpenRouter slugs still pass', () => {
  for (const id of ['openrouter/anthropic/claude-sonnet-5', 'openrouter/anthropic/claude-haiku-4.5']) {
    assert.ok(MODEL_RE.test(id), `${id} should be accepted`);
  }
});

test('the regex still refuses anything that could smuggle a CLI arg', () => {
  for (const bad of ['-rf /tmp', 'a b', '--model', '', 'a;b', 'a|b', 'a$b']) {
    assert.ok(!MODEL_RE.test(bad), `${JSON.stringify(bad)} must be refused`);
  }
});

test('the tool-grant allowlist still matches harness.rb', () => {
  // ALLOWED_TOOL_GRANTS duplicates TOOLS_READ/TOOLS_IMPL in lib/opilot/harness.rb
  // and carries a "must stay in sync" comment with nothing enforcing it. This
  // does not close that gap, but it does pin the current values.
  assert.ok(ALLOWED_TOOL_GRANTS.has('read,grep,find,ls,bash'));
  assert.ok(ALLOWED_TOOL_GRANTS.has('read,grep,find,ls,bash,write,edit'));
  assert.strictEqual(ALLOWED_TOOL_GRANTS.size, 2);
});

// ── copy versus generate ──────────────────────────────────────────────────

test('the provider prefix is the one signal deciding copy versus generate', () => {
  assert.strictEqual(providerPrefix('openrouter/anthropic/claude-sonnet-5'), 'openrouter');
  assert.strictEqual(providerPrefix('local/qwen2.5-coder:7b'), 'local');
  assert.strictEqual(providerPrefix('no-prefix'), '');
});

test('the generated provider is named after the prefix the operator chose', () => {
  const { name } = only(buildModelsJson({
    OPILOT_MODEL_HEAVY: 'selfhosted/qwen2.5-coder:7b',
    OPILOT_MODEL_LIGHT: 'selfhosted/qwen2.5-coder:7b',
  }));
  assert.strictEqual(name, 'selfhosted');
});

// ── the generated body ────────────────────────────────────────────────────

test('ids lose the prefix, and heavy/light collapse when they are the same model', () => {
  const { config } = only(buildModelsJson({
    OPILOT_MODEL_HEAVY: 'local/qwen2.5-coder:7b',
    OPILOT_MODEL_LIGHT: 'local/qwen2.5-coder:7b',
  }));
  assert.deepStrictEqual(config.models, [{ id: 'qwen2.5-coder:7b' }]);
});

test('two different models produce two entries, heavy first', () => {
  const { config } = only(buildModelsJson({
    OPILOT_MODEL_HEAVY: 'local/qwen2.5-coder:32b',
    OPILOT_MODEL_LIGHT: 'local/qwen2.5-coder:7b',
  }));
  assert.deepStrictEqual(config.models, [{ id: 'qwen2.5-coder:32b' }, { id: 'qwen2.5-coder:7b' }]);
});

test('baseUrl is authgw, never the model server directly', () => {
  // The harness has no other route out, and authgw re-applies the upstream's
  // own path prefix — hence /v1 here whatever the upstream serves.
  const { config } = only(buildModelsJson({ OPILOT_MODEL_HEAVY: 'local/m' }));
  assert.strictEqual(config.baseUrl, 'http://authgw:47292/v1');
  assert.strictEqual(config.apiKey, '$OPILOT_GW_TOKEN');
});

test('openai-completions is the default and carries the compat pair', () => {
  // Mandatory, not optional: Ollama, vLLM and SGLang understand neither the
  // developer role nor reasoning_effort.
  const { config } = only(buildModelsJson({ OPILOT_MODEL_HEAVY: 'local/m' }));
  assert.strictEqual(config.api, 'openai-completions');
  assert.deepStrictEqual(config.compat, {
    supportsDeveloperRole: false, supportsReasoningEffort: false,
  });
});

test('a non-default protocol omits the compat pair', () => {
  // Those two flags are openai-completions concepts; the other protocols have
  // their own compat keys and would be confused by these.
  for (const api of ['anthropic-messages', 'google-generative-ai', 'openai-responses']) {
    const { config } = only(buildModelsJson({ OPILOT_MODEL_HEAVY: 'local/m', OPILOT_MODEL_API: api }));
    assert.strictEqual(config.api, api);
    assert.strictEqual('compat' in config, false, `${api} should not carry openai compat flags`);
  }
});

test('contextWindow appears only when configured', () => {
  const without = only(buildModelsJson({ OPILOT_MODEL_HEAVY: 'local/m' }));
  assert.deepStrictEqual(without.config.models, [{ id: 'm' }]);

  const with_ = only(buildModelsJson({
    OPILOT_MODEL_HEAVY: 'local/m', OPILOT_MODEL_CONTEXT_WINDOW: '262144',
  }));
  assert.deepStrictEqual(with_.config.models, [{ id: 'm', contextWindow: 262144 }]);

  // A junk value falls back to pi's own default rather than emitting NaN.
  const junk = only(buildModelsJson({
    OPILOT_MODEL_HEAVY: 'local/m', OPILOT_MODEL_CONTEXT_WINDOW: 'lots',
  }));
  assert.deepStrictEqual(junk.config.models, [{ id: 'm' }]);
});

test('a light model on another provider is ignored rather than mixed in', () => {
  // One generated provider, so a slug from a different one cannot belong to it.
  const { config } = only(buildModelsJson({
    OPILOT_MODEL_HEAVY: 'local/big',
    OPILOT_MODEL_LIGHT: 'openrouter/anthropic/claude-haiku-4.5',
  }));
  assert.deepStrictEqual(config.models, [{ id: 'big' }]);
});

// ── failing loudly ────────────────────────────────────────────────────────

test('bad configuration throws at boot instead of confusing pi later', () => {
  assert.throws(() => buildModelsJson({ OPILOT_MODEL_HEAVY: 'no-prefix' }), /provider prefix/);
  assert.throws(() => buildModelsJson({}), /provider prefix/);
  assert.throws(
    () => buildModelsJson({ OPILOT_MODEL_HEAVY: 'local/m', OPILOT_MODEL_API: 'grpc' }),
    /OPILOT_MODEL_API must be one of/,
  );
  assert.throws(() => buildModelsJson({ OPILOT_MODEL_HEAVY: 'local/' }), /no model id/);
});

console.log(failures === 0 ? '\nall passed' : `\n${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
