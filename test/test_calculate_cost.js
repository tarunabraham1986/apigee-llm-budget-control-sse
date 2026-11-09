/**
 * Copyright 2026 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * Offline unit test suite for apiproxy/resources/jsc/CalculateCost.js.
 * Mocks Apigee's `context` object to verify buffered and multi-chunk SSE
 * cost accounting across Gemini, OpenAI, Anthropic, and KVM fallback rates.
 */

const assert = require("assert");
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const scriptPath = path.join(__dirname, "..", "apiproxy", "resources", "jsc", "CalculateCost.js");
const scriptCode = fs.readFileSync(scriptPath, "utf8");

function createMockContext(initialVars) {
  const store = Object.assign({}, initialVars);
  return {
    store,
    getVariable(name) {
      return Object.prototype.hasOwnProperty.call(store, name) ? store[name] : null;
    },
    setVariable(name, value) {
      store[name] = value;
    },
  };
}

function runCalc(ctx) {
  vm.runInNewContext(scriptCode, { context: ctx });
}

// 1. Gemini Buffered (prompt + candidates + thoughts)
{
  const ctx = createMockContext({
    llm_provider: "google",
    model_cost_config: JSON.stringify({ input_cost_per_million: 1.25, output_cost_per_million: 10.0 }),
    "response.content": JSON.stringify({
      candidates: [{ content: { parts: [{ text: "Solar watch!" }] }, finishReason: "STOP" }],
      usageMetadata: { promptTokenCount: 100, candidatesTokenCount: 50, thoughtsTokenCount: 250 },
    }),
  });
  runCalc(ctx);
  // 100 * 1.25 + (50 + 250) * 10.0 = 125 + 3000 = 3125 micro-dollars
  assert.strictEqual(ctx.store.should_record_cost, "true");
  assert.strictEqual(ctx.store.llm_input_tokens, 100);
  assert.strictEqual(ctx.store.llm_output_tokens, 300);
  assert.strictEqual(ctx.store.llm_transaction_cost_micro, 3125);
  console.log("[PASS] Gemini Buffered (with thoughtsTokenCount)");
}

// 2. Gemini Multi-Chunk SSE (intermediate chunks skipped, terminal finishReason recorded once)
{
  const ctx = createMockContext({
    llm_provider: "google",
    model_cost_config: JSON.stringify({ input_cost_per_million: 0.30, output_cost_per_million: 2.50 }),
  });

  // Chunk 1: intermediate chunk repeating promptTokenCount without finishReason
  ctx.setVariable(
    "response.event.current.data",
    JSON.stringify({
      candidates: [{ content: { parts: [{ text: "Part 1 " }] } }],
      usageMetadata: { promptTokenCount: 200 },
    })
  );
  runCalc(ctx);
  assert.strictEqual(ctx.store.should_record_cost, "false");

  // Chunk 2: terminal chunk with finishReason
  ctx.setVariable(
    "response.event.current.data",
    JSON.stringify({
      candidates: [{ content: { parts: [{ text: "Part 2" }] }, finishReason: "STOP" }],
      usageMetadata: { promptTokenCount: 200, candidatesTokenCount: 80, thoughtsTokenCount: 20 },
    })
  );
  runCalc(ctx);
  // 200 * 0.30 + 100 * 2.50 = 60 + 250 = 310 micro-dollars
  assert.strictEqual(ctx.store.should_record_cost, "true");
  assert.strictEqual(ctx.store.llm_transaction_cost_micro, 310);

  // Chunk 3: hypothetical trailing empty chunk -> must NOT record again
  ctx.setVariable("response.event.current.data", "[DONE]");
  runCalc(ctx);
  assert.strictEqual(ctx.store.should_record_cost, "false");
  console.log("[PASS] Gemini Multi-Chunk SSE (single terminal recording)");
}

// 3. OpenAI SSE (usage chunk + trailing [DONE])
{
  const ctx = createMockContext({
    llm_provider: "openai",
    model_cost_config: JSON.stringify({ input_cost_per_million: 2.50, output_cost_per_million: 10.0 }),
  });

  ctx.setVariable("response.event.current.data", JSON.stringify({ choices: [{ delta: { content: "Hi" } }], usage: null }));
  runCalc(ctx);
  assert.strictEqual(ctx.store.should_record_cost, "false");

  ctx.setVariable("response.event.current.data", JSON.stringify({ choices: [], usage: { prompt_tokens: 40, completion_tokens: 60 } }));
  runCalc(ctx);
  // 40 * 2.50 + 60 * 10.0 = 100 + 600 = 700 micro-dollars
  assert.strictEqual(ctx.store.should_record_cost, "true");
  assert.strictEqual(ctx.store.llm_transaction_cost_micro, 700);

  ctx.setVariable("response.event.current.data", "[DONE]");
  runCalc(ctx);
  assert.strictEqual(ctx.store.should_record_cost, "false");
  console.log("[PASS] OpenAI Multi-Chunk SSE + [DONE] no-op");
}

// 4. Anthropic SSE (message_start + content_block_delta + message_delta + message_stop)
{
  const ctx = createMockContext({
    llm_provider: "anthropic",
    model_cost_config: JSON.stringify({ input_cost_per_million: 3.0, output_cost_per_million: 15.0 }),
  });

  ctx.setVariable("response.event.current.data", JSON.stringify({ type: "message_start", message: { usage: { input_tokens: 100, output_tokens: 1 } } }));
  runCalc(ctx);
  assert.strictEqual(ctx.store.should_record_cost, "false");

  ctx.setVariable("response.event.current.data", JSON.stringify({ type: "content_block_delta", delta: { text: "Hello" } }));
  runCalc(ctx);
  assert.strictEqual(ctx.store.should_record_cost, "false");

  ctx.setVariable("response.event.current.data", JSON.stringify({ type: "message_delta", usage: { output_tokens: 40 } }));
  runCalc(ctx);
  // 100 * 3.0 + 40 * 15.0 = 300 + 600 = 900 micro-dollars
  assert.strictEqual(ctx.store.should_record_cost, "true");
  assert.strictEqual(ctx.store.llm_input_tokens, 100);
  assert.strictEqual(ctx.store.llm_output_tokens, 40);
  assert.strictEqual(ctx.store.llm_transaction_cost_micro, 900);

  ctx.setVariable("response.event.current.data", JSON.stringify({ type: "message_stop" }));
  runCalc(ctx);
  assert.strictEqual(ctx.store.should_record_cost, "false");
  console.log("[PASS] Anthropic Multi-Chunk SSE (cached input_tokens + message_delta)");
}

// 5. KVM Default Fallback Rate (unlisted model)
{
  const ctx = createMockContext({
    llm_provider: "google",
    model_cost_config: null,
    default_cost_config: JSON.stringify({ input_cost_per_million: 0.50, output_cost_per_million: 2.50 }),
    "response.content": JSON.stringify({
      usageMetadata: { promptTokenCount: 1000, candidatesTokenCount: 200 },
    }),
  });
  runCalc(ctx);
  // 1000 * 0.50 + 200 * 2.50 = 500 + 500 = 1000 micro-dollars
  assert.strictEqual(ctx.store.should_record_cost, "true");
  assert.strictEqual(ctx.store.llm_transaction_cost_micro, 1000);
  console.log("[PASS] KVM default_cost_config fallback");
}

console.log("\nAll CalculateCost.js unit tests PASSED!");
