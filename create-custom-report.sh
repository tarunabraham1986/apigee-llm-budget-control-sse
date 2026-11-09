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

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ ! -f "${SCRIPT_DIR}/env.sh" ]; then
  echo "env.sh not found."
  exit 1
fi

source "${SCRIPT_DIR}/env.sh"

if [ -z "$PROJECT" ] || [[ "$PROJECT" == *_TO_SET ]]; then
  echo "Error: Please configure PROJECT in env.sh"
  exit 1
fi

TOKEN="${TOKEN:-$(gcloud auth print-access-token)}"
TMP_RESP=$(mktemp)

echo "Creating Custom Report (llm-budget-sse-cost-analysis)..."
RESPONSE=$(curl -s -w "%{http_code}" -o "$TMP_RESP" -X POST \
  "https://apigee.googleapis.com/v1/organizations/${PROJECT}/reports" \
  --header "Authorization: Bearer ${TOKEN}" \
  --header "Accept: application/json" \
  --header "Content-Type: application/json" \
  --data '{"name":"llm-budget-sse-cost-analysis","displayName":"LLM Budget SSE and Buffered Cost Analysis","metrics":[{"name":"dc_llm_transaction_cost_v2","function":"sum"},{"name":"dc_llm_prompt_tokens","function":"sum"},{"name":"dc_llm_candidates_tokens","function":"sum"}],"dimensions":["api_product","developer_app","dc_llm_provider","dc_llm_model"],"properties":[{"value":[{}]}],"chartType":"column"}')

if [ "$RESPONSE" -eq 201 ] || [ "$RESPONSE" -eq 200 ]; then
  echo "Custom Report 'llm-budget-sse-cost-analysis' created successfully!"
elif [ "$RESPONSE" -eq 409 ]; then
  echo "Custom Report 'llm-budget-sse-cost-analysis' already exists."
else
  echo "Failed to create Custom Report (HTTP ${RESPONSE}):"
  cat "$TMP_RESP"
  echo ""
  echo "If the new Data Collectors have not ingested traffic yet, run './run-demo-traffic.sh', wait ~10 minutes, and re-run this script."
fi

rm -f "$TMP_RESP"
