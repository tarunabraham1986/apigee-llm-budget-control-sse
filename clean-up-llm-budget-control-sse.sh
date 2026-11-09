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

if [ -z "$PROJECT" ] || [ -z "$APIGEE_ENV" ] || [[ "$PROJECT" == *_TO_SET ]] || [[ "$APIGEE_ENV" == *_TO_SET ]]; then
  echo "Error: Please configure PROJECT and APIGEE_ENV in env.sh"
  exit 1
fi

TOKEN="${TOKEN:-$(gcloud auth print-access-token)}"
export PATH="$PATH:$HOME/.local/bin:$HOME/.apigeecli/bin"

MKT_DEV_EMAIL="marketing-sse-lead@example.com"
ENG_DEV_EMAIL="engineering-sse-lead@example.com"

echo "Deleting SSE Demo Developer Apps..."
DEV_A_ID=$(apigeecli developers get --email "$MKT_DEV_EMAIL" --org "$PROJECT" --token "$TOKEN" --disable-check 2>/dev/null | jq -r '.developerId // empty' || true)
DEV_B_ID=$(apigeecli developers get --email "$ENG_DEV_EMAIL" --org "$PROJECT" --token "$TOKEN" --disable-check 2>/dev/null | jq -r '.developerId // empty' || true)

if [ -n "$DEV_A_ID" ]; then
  for app_name in $(apigeecli developers getapps --name "$MKT_DEV_EMAIL" --expand --org "$PROJECT" --token "$TOKEN" --disable-check 2>/dev/null | jq -r '.app[]?.name // empty' 2>/dev/null || true); do
    apigeecli apps delete --name "$app_name" --id "$DEV_A_ID" --org "$PROJECT" --token "$TOKEN" --disable-check &>/dev/null || true
  done
fi
if [ -n "$DEV_B_ID" ]; then
  for app_name in $(apigeecli developers getapps --name "$ENG_DEV_EMAIL" --expand --org "$PROJECT" --token "$TOKEN" --disable-check 2>/dev/null | jq -r '.app[]?.name // empty' 2>/dev/null || true); do
    apigeecli apps delete --name "$app_name" --id "$DEV_B_ID" --org "$PROJECT" --token "$TOKEN" --disable-check &>/dev/null || true
  done
fi

echo "Deleting SSE Demo API Products & Developers..."
apigeecli products delete --name llm-budget-sse-marketing-product --org "$PROJECT" --token "$TOKEN" --disable-check &>/dev/null || true
apigeecli products delete --name llm-budget-sse-engineering-product --org "$PROJECT" --token "$TOKEN" --disable-check &>/dev/null || true
apigeecli developers delete --email "$MKT_DEV_EMAIL" --org "$PROJECT" --token "$TOKEN" --disable-check &>/dev/null || true
apigeecli developers delete --email "$ENG_DEV_EMAIL" --org "$PROJECT" --token "$TOKEN" --disable-check &>/dev/null || true

rm -f "${SCRIPT_DIR}/demo-keys.env"

echo "Undeploying and Deleting API Proxy (llm-budget-control-sse)..."
apigeecli apis delete --name llm-budget-control-sse --org "$PROJECT" --token "$TOKEN" --disable-check &>/dev/null || true

echo "Deleting Custom Report (llm-budget-sse-cost-analysis)..."
curl -s -X DELETE \
  "https://apigee.googleapis.com/v1/organizations/${PROJECT}/reports/llm-budget-sse-cost-analysis" \
  --header "Authorization: Bearer ${TOKEN}" \
  > /dev/null || true

echo "Note: Shared KVMs (llm-model-costs, llm-provider-config), Service Account, and Data Collectors were preserved so coexisting samples remain intact."
echo "Clean-up of llm-budget-control-sse Complete!"
