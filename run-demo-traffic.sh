#!/bin/bash

# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
source "${SCRIPT_DIR}/env.sh"

if [ ! -f "${SCRIPT_DIR}/demo-keys.env" ]; then
  echo "demo-keys.env not found. Run ./setup-demo-resources.sh first."
  exit 1
fi
source "${SCRIPT_DIR}/demo-keys.env"

if [ -z "$PROJECT" ] || [ -z "$APIGEE_HOST" ] || [[ "$PROJECT" == *_TO_SET ]] || [[ "$APIGEE_HOST" == *_TO_SET ]]; then
  echo "Error: Please configure PROJECT and APIGEE_HOST in env.sh"
  exit 1
fi

if [ -z "$REGION" ] || [ "$REGION" = "REGION_TO_SET" ]; then
  REGION="us-west1"
fi
BASE_URL="https://${APIGEE_HOST}/v2/samples/llm-budget-control-sse"

print_telemetry_headers() {
  local hdr_file="$1"
  grep -iE "^(http/|content-type:|x-llm-)" "$hdr_file" | tr -d '\r' | sed 's/^/    /'
}

send_buffered() {
  local label="$1"
  local key="$2"
  local model="$3"
  local prompt="$4"
  local include_provider_hdr="${5:-true}"

  local hdr_file
  local body_file
  hdr_file=$(mktemp)
  body_file=$(mktemp)

  echo ">>> [BUFFERED] ${label} (model=${model})"
  local extra_hdr=()
  if [ "$include_provider_hdr" = "true" ]; then
    extra_hdr=(-H "x-llm-provider: google")
  fi

  local status
  status=$(curl -s -D "$hdr_file" -o "$body_file" -w "%{http_code}" -X POST \
    "${BASE_URL}/v1/projects/${PROJECT}/locations/${REGION}/publishers/google/models/${model}:generateContent" \
    -H "x-apikey: ${key}" \
    "${extra_hdr[@]}" \
    -H "Content-Type: application/json" \
    -d "{\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"${prompt}\"}]}]}")

  echo "  HTTP Status: ${status}"
  echo "  Telemetry Headers:"
  print_telemetry_headers "$hdr_file"

  if [ "$status" -eq 200 ]; then
    local text
    text=$(jq -r '.candidates[0].content.parts[0].text // empty' "$body_file" 2>/dev/null | tr '\n' ' ' | cut -c1-140)
    echo "  Completion : ${text}..."
  else
    echo "  Error Body : $(cat "$body_file" | tr '\n' ' ')"
  fi
  echo "-----------------------------------------------------------------"
  LAST_STATUS="$status"
  rm -f "$hdr_file" "$body_file"
}

send_sse() {
  local label="$1"
  local key="$2"
  local model="$3"
  local prompt="$4"
  local include_provider_hdr="${5:-true}"

  local hdr_file
  local body_file
  hdr_file=$(mktemp)
  body_file=$(mktemp)

  echo ">>> [SSE STREAM] ${label} (model=${model})"
  local extra_hdr=()
  if [ "$include_provider_hdr" = "true" ]; then
    extra_hdr=(-H "x-llm-provider: google")
  fi

  local status
  status=$(curl -s -N -D "$hdr_file" -o "$body_file" -w "%{http_code}" -X POST \
    "${BASE_URL}/v1/projects/${PROJECT}/locations/${REGION}/publishers/google/models/${model}:streamGenerateContent?alt=sse" \
    -H "x-apikey: ${key}" \
    "${extra_hdr[@]}" \
    -H "Accept: text/event-stream" \
    -H "Content-Type: application/json" \
    -d "{\"contents\":[{\"role\":\"user\",\"parts\":[{\"text\":\"${prompt}\"}]}]}")

  echo "  HTTP Status: ${status}"
  echo "  Telemetry Headers:"
  print_telemetry_headers "$hdr_file"

  if [ "$status" -eq 200 ]; then
    local chunk_count
    chunk_count=$(grep -c "^data:" "$body_file" || true)
    local combined_text
    combined_text=$(grep "^data:" "$body_file" | sed 's/^data: *//' | jq -r '.candidates[0].content.parts[0].text // empty' 2>/dev/null | tr -d '\n' | cut -c1-140)
    echo "  SSE Chunks : ${chunk_count}"
    echo "  Stream Text: ${combined_text}..."
  else
    echo "  Error Body : $(cat "$body_file" | tr '\n' ' ')"
  fi
  echo "-----------------------------------------------------------------"
  LAST_STATUS="$status"
  rm -f "$hdr_file" "$body_file"
}

echo "================================================================="
echo "Buffered + SSE LLM Budget Control Traffic Simulation"
echo "================================================================="

# 1. Negative Auth Check (Missing API Key -> 401)
echo ">>> [AUTH CHECK] Calling without x-apikey (expect HTTP 401)"
UNAUTH_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  "${BASE_URL}/v1/projects/${PROJECT}/locations/${REGION}/publishers/google/models/gemini-2.5-flash:generateContent" \
  -H "Content-Type: application/json" \
  -d '{"contents":[{"role":"user","parts":[{"text":"Hello"}]}]}')
echo "  HTTP Status: ${UNAUTH_STATUS}"
echo "-----------------------------------------------------------------"

# 2. Engineering App ($1.00 cap): Buffered Flash + SSE Pro (Cross-Model Shared Wallet)
send_buffered "Engineering App #1 (Buffered Flash)" "$ENGINEERING_KEY" "gemini-2.5-flash" "Explain API gateways in one sentence."
sleep 3
send_sse "Engineering App #2 (SSE Pro - Auto-Detect Provider)" "$ENGINEERING_KEY" "gemini-2.5-pro" "List 3 benefits of Server-Sent Events in one short sentence." "false"
sleep 3
send_buffered "Engineering App #3 (Verify SSE Spend Recorded in Opening Balance)" "$ENGINEERING_KEY" "gemini-2.5-flash" "Say ready in two words."

# 3. Marketing App ($0.02 = 20,000 micro-dollar cap): Interleave Buffered + SSE until 429
echo ">>> Exhausting Marketing App budget (20,000 micro-dollars / \$0.02) across Buffered + SSE..."
LAST_STATUS=200
for attempt in 1 2 3 4; do
  if [ "$LAST_STATUS" -eq 429 ]; then
    break
  fi
  if [ $((attempt % 2)) -eq 1 ]; then
    send_buffered "Marketing App Attempt #${attempt} (Buffered Pro)" "$MARKETING_KEY" "gemini-2.5-pro" "Write a 150-word product launch blurb for a solar smartwatch."
  else
    send_sse "Marketing App Attempt #${attempt} (SSE Pro)" "$MARKETING_KEY" "gemini-2.5-pro" "Write a 200-word social media newsletter for a solar smartwatch."
  fi
  sleep 3
done

# 4. Verify BOTH Buffered and SSE requests are now blocked pre-flight with 429
send_buffered "Marketing App Post-Exhaustion Check (Buffered -> Expect 429)" "$MARKETING_KEY" "gemini-2.5-flash" "Should be blocked pre-flight."
send_sse "Marketing App Post-Exhaustion Check (SSE -> Expect 429)" "$MARKETING_KEY" "gemini-2.5-flash" "Should also be blocked pre-flight."

# 5. Verify App Isolation: Engineering App SSE still succeeds (200 OK)
send_sse "Engineering App Isolation Check (SSE Flash -> Expect 200)" "$ENGINEERING_KEY" "gemini-2.5-flash" "Confirm tenant isolation in one short sentence." "false"

echo "Simulation Complete!"
