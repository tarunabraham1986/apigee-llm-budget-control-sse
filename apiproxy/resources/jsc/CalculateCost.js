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
 * Unified LLM token usage and micro-dollar cost calculator for both:
 *   1. Buffered JSON responses (ProxyEndpoint Response PostFlow)
 *   2. Streaming SSE EventFlow chunks (TargetEndpoint EventFlow)
 *
 * In SSE mode, should_record_cost is reset to "false" on every chunk and flips
 * to "true" ONLY ONCE on the terminal usage chunk so LTQ-CountBudget and
 * DC-CollectCostMetrics execute exactly once per stream.
 */
(function () {
  function toLong(val) {
    var intVal = parseInt(val || 0, 10);
    if (isNaN(intVal)) {
      intVal = 0;
    }
    if (typeof java !== "undefined" && java.lang && java.lang.Long) {
      return java.lang.Long.valueOf(intVal);
    }
    return intVal;
  }

  function parseJsonSafe(raw) {
    if (!raw || typeof raw !== "string") {
      return null;
    }
    var trimmed = raw.trim();
    if (!trimmed || trimmed === "[DONE]") {
      return null;
    }
    try {
      return JSON.parse(trimmed);
    } catch (e) {
      return null;
    }
  }

  function extractSsePayload(eventData, eventContent) {
    var candidate = "";
    if (eventData !== null && eventData !== undefined && String(eventData).trim() !== "") {
      candidate = String(eventData).trim();
    } else if (eventContent !== null && eventContent !== undefined && String(eventContent).trim() !== "") {
      var lines = String(eventContent).split(/\r?\n/);
      var dataParts = [];
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim();
        if (line.indexOf("data:") === 0) {
          dataParts.push(line.substring(5).trim());
        }
      }
      if (dataParts.length > 0) {
        candidate = dataParts.join("\n").trim();
      } else {
        candidate = String(eventContent).trim();
      }
    }

    if (candidate.indexOf("data:") === 0) {
      candidate = candidate.substring(5).trim();
    }
    return parseJsonSafe(candidate);
  }

  function resolveRates() {
    var modelCfg = parseJsonSafe(context.getVariable("model_cost_config"));
    var defaultCfg = parseJsonSafe(context.getVariable("default_cost_config"));
    var activeCfg = null;

    if (modelCfg && modelCfg.input_cost_per_million !== undefined && modelCfg.output_cost_per_million !== undefined) {
      activeCfg = modelCfg;
    } else if (defaultCfg && defaultCfg.input_cost_per_million !== undefined && defaultCfg.output_cost_per_million !== undefined) {
      activeCfg = defaultCfg;
    }

    var inRate = activeCfg ? parseFloat(activeCfg.input_cost_per_million) : 0.50;
    var outRate = activeCfg ? parseFloat(activeCfg.output_cost_per_million) : 2.50;
    if (isNaN(inRate)) {
      inRate = 0.50;
    }
    if (isNaN(outRate)) {
      outRate = 2.50;
    }
    return { inputRate: inRate, outputRate: outRate };
  }

  // Always reset per-event gate before inspecting current message/chunk
  context.setVariable("should_record_cost", "false");

  var provider = String(context.getVariable("llm_provider") || "google").toLowerCase();
  var eventData = context.getVariable("response.event.current.data");
  var eventContent = context.getVariable("response.event.current.content");
  var isSseEvent = (eventData !== null && eventData !== undefined) || (eventContent !== null && eventContent !== undefined);

  var inputTokens = 0;
  var outputTokens = 0;
  var readyToRecord = false;

  if (isSseEvent) {
    // Guard against duplicate recording if terminal usage was already processed
    if (context.getVariable("sse_cost_recorded") === "true") {
      return;
    }

    var sseObj = extractSsePayload(eventData, eventContent);
    if (!sseObj) {
      return;
    }

    if (provider === "google") {
      var candidates = sseObj.candidates;
      var hasFinishReason = !!(candidates && candidates.length > 0 && candidates[0] && candidates[0].finishReason);
      if (hasFinishReason) {
        context.setVariable("sse_saw_finish_reason", "true");
      }
      var usageMeta = sseObj.usageMetadata;
      if ((hasFinishReason || context.getVariable("sse_saw_finish_reason") === "true") && usageMeta) {
        inputTokens = parseInt(usageMeta.promptTokenCount || 0, 10);
        var candTokens = parseInt(usageMeta.candidatesTokenCount || 0, 10);
        var thoughtTokens = parseInt(usageMeta.thoughtsTokenCount || 0, 10);
        outputTokens = candTokens + thoughtTokens;
        context.setVariable("google_prompt_tokens", toLong(inputTokens));
        context.setVariable("google_output_tokens", toLong(candTokens));
        context.setVariable("google_thoughts_tokens", toLong(thoughtTokens));
        readyToRecord = true;
      }
    } else if (provider === "openai") {
      var oaUsage = sseObj.usage || (sseObj.response && sseObj.response.usage);
      if (oaUsage && (oaUsage.prompt_tokens !== undefined || oaUsage.input_tokens !== undefined)) {
        inputTokens = parseInt(oaUsage.prompt_tokens !== undefined ? oaUsage.prompt_tokens : (oaUsage.input_tokens || 0), 10);
        outputTokens = parseInt(oaUsage.completion_tokens !== undefined ? oaUsage.completion_tokens : (oaUsage.output_tokens || 0), 10);
        readyToRecord = true;
      }
    } else if (provider === "anthropic") {
      if (sseObj.type === "message_start" && sseObj.message && sseObj.message.usage) {
        var startInput = parseInt(sseObj.message.usage.input_tokens || 0, 10);
        context.setVariable("anthropic_cached_input_tokens", String(startInput));
        return;
      }
      if (sseObj.type === "message_delta" && sseObj.usage) {
        var cachedInput = parseInt(context.getVariable("anthropic_cached_input_tokens") || 0, 10);
        inputTokens = (sseObj.usage.input_tokens !== undefined) ? parseInt(sseObj.usage.input_tokens, 10) : cachedInput;
        outputTokens = parseInt(sseObj.usage.output_tokens || 0, 10);
        readyToRecord = true;
      }
    }
  } else {
    // Buffered JSON response mode
    var bufferedObj = parseJsonSafe(context.getVariable("response.content"));
    if (!bufferedObj) {
      return;
    }

    if (provider === "google" && bufferedObj.usageMetadata) {
      var gMeta = bufferedObj.usageMetadata;
      inputTokens = parseInt(gMeta.promptTokenCount || 0, 10);
      var gCand = parseInt(gMeta.candidatesTokenCount || 0, 10);
      var gThought = parseInt(gMeta.thoughtsTokenCount || 0, 10);
      outputTokens = gCand + gThought;
      context.setVariable("google_prompt_tokens", toLong(inputTokens));
      context.setVariable("google_output_tokens", toLong(gCand));
      context.setVariable("google_thoughts_tokens", toLong(gThought));
      readyToRecord = true;
    } else if (provider === "openai") {
      var bOaUsage = bufferedObj.usage || (bufferedObj.response && bufferedObj.response.usage);
      if (bOaUsage) {
        inputTokens = parseInt(bOaUsage.prompt_tokens !== undefined ? bOaUsage.prompt_tokens : (bOaUsage.input_tokens || 0), 10);
        outputTokens = parseInt(bOaUsage.completion_tokens !== undefined ? bOaUsage.completion_tokens : (bOaUsage.output_tokens || 0), 10);
        readyToRecord = true;
      }
    } else if (provider === "anthropic" && bufferedObj.usage) {
      inputTokens = parseInt(bufferedObj.usage.input_tokens || 0, 10);
      outputTokens = parseInt(bufferedObj.usage.output_tokens || 0, 10);
      readyToRecord = true;
    } else if (bufferedObj.usageMetadata) {
      inputTokens = parseInt(bufferedObj.usageMetadata.promptTokenCount || 0, 10);
      outputTokens = parseInt(bufferedObj.usageMetadata.candidatesTokenCount || 0, 10) + parseInt(bufferedObj.usageMetadata.thoughtsTokenCount || 0, 10);
      readyToRecord = true;
    } else if (bufferedObj.usage) {
      inputTokens = parseInt(bufferedObj.usage.prompt_tokens || bufferedObj.usage.input_tokens || 0, 10);
      outputTokens = parseInt(bufferedObj.usage.completion_tokens || bufferedObj.usage.output_tokens || 0, 10);
      readyToRecord = true;
    }
  }

  if (!readyToRecord) {
    return;
  }

  var rates = resolveRates();
  var inputCostUsd = (inputTokens / 1000000) * rates.inputRate;
  var outputCostUsd = (outputTokens / 1000000) * rates.outputRate;
  var totalCostUsd = inputCostUsd + outputCostUsd;

  var totalCostMicro = Math.round(totalCostUsd * 1000000);
  if (totalCostMicro === 0 && (inputTokens > 0 || outputTokens > 0) && (rates.inputRate > 0 || rates.outputRate > 0)) {
    totalCostMicro = 1;
  }
  var totalCostRounded = totalCostMicro / 1000000;

  context.setVariable("llm_input_tokens", toLong(inputTokens));
  context.setVariable("llm_output_tokens", toLong(outputTokens));
  context.setVariable("llm_transaction_cost", totalCostRounded);
  context.setVariable("llm_transaction_cost_micro", toLong(totalCostMicro));
  context.setVariable("should_record_cost", "true");

  if (isSseEvent) {
    context.setVariable("sse_cost_recorded", "true");
  }
})();
