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
  echo "env.sh not found. Please configure env.sh before running deployment."
  exit 1
fi

source "${SCRIPT_DIR}/env.sh"

for var in PROJECT APIGEE_ENV APIGEE_HOST; do
  if [ -z "${!var}" ] || [[ "${!var}" == *_TO_SET ]]; then
    echo "Error: Please configure $var in env.sh before running deployment."
    exit 1
  fi
done

if [ -z "$REGION" ] || [ "$REGION" = "REGION_TO_SET" ]; then
  REGION="us-west1"
fi

if [ -z "$TOKEN" ]; then
  TOKEN=$(gcloud auth print-access-token)
fi

export PATH="$PATH:$HOME/.local/bin:$HOME/.apigeecli/bin"
if ! command -v apigeecli &> /dev/null; then
  echo "Installing apigeecli..."
  curl -sL https://raw.githubusercontent.com/apigee/apigeecli/main/downloadLatest.sh | sh -
  export PATH="$PATH:$HOME/.apigeecli/bin"
fi

SA_NAME="apigee-llm-budget-sa"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

echo "1. Ensuring Vertex AI Service Account (${SA_EMAIL})..."
if ! gcloud iam service-accounts describe "${SA_EMAIL}" --project "$PROJECT" &>/dev/null; then
  gcloud iam service-accounts create "$SA_NAME" \
    --display-name "Apigee LLM Budget Control Service Account" \
    --project "$PROJECT"
  echo "Waiting 5 seconds for Service Account propagation..."
  sleep 5
fi

echo "Granting Vertex AI User role to ${SA_EMAIL}..."
gcloud projects add-iam-policy-binding "$PROJECT" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/aiplatform.user" \
  --quiet >/dev/null

PROJECT_NUMBER=$(gcloud projects describe "${PROJECT}" --format="value(projectNumber)")
APIGEE_SA="service-${PROJECT_NUMBER}@gcp-sa-apigee.iam.gserviceaccount.com"

echo "Granting Service Account Token Creator role to Apigee Service Agent (${APIGEE_SA})..."
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --member="serviceAccount:${APIGEE_SA}" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project "$PROJECT" \
  --quiet >/dev/null

echo "2. Syncing Environment KVMs non-destructively (llm-model-costs & llm-provider-config)..."
apigeecli kvms create --name llm-model-costs --env "$APIGEE_ENV" --org "$PROJECT" --token "$TOKEN" --disable-check &>/dev/null || true
apigeecli kvms create --name llm-provider-config --env "$APIGEE_ENV" --org "$PROJECT" --token "$TOKEN" --disable-check &>/dev/null || true

upsert_kvm_file() {
  local map_name="$1"
  local json_file="$2"
  local entries_url="https://apigee.googleapis.com/v1/organizations/${PROJECT}/environments/${APIGEE_ENV}/keyvaluemaps/${map_name}/entries"

  while IFS= read -r entry; do
    local k
    local v
    local payload
    local code
    k=$(echo "$entry" | jq -r '.name')
    v=$(echo "$entry" | jq -r '.value')
    v="${v//VERTEXAI_PROJECT_ID/$PROJECT}"
    v="${v//VERTEXAI_REGION/$REGION}"
    payload=$(jq -n --arg name "$k" --arg value "$v" '{name: $name, value: $value}')

    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$entries_url" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Content-Type: application/json" \
      -d "$payload")

    if [ "$code" -eq 409 ] && [[ "$k" != *"__credential" ]]; then
      code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "${entries_url}/${k}" \
        -H "Authorization: Bearer ${TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$payload")
    fi

    if [ "$code" -ne 200 ] && [ "$code" -ne 201 ] && [ "$code" -ne 409 ]; then
      echo "Failed upserting KVM entry ${map_name}/${k} (HTTP ${code})"
      exit 1
    fi
  done < <(jq -c '.keyValueEntries[]' "$json_file")
}

upsert_kvm_file "llm-model-costs" "${SCRIPT_DIR}/config/env__envname__llm-model-costs__kvmfile__0.json"
upsert_kvm_file "llm-provider-config" "${SCRIPT_DIR}/config/env__envname__llm-provider-config__kvmfile__0.json"

echo "3. Ensuring Analytics Data Collectors..."
apigeecli datacollectors create -d "LLM Provider" -n dc_llm_provider -p STRING --org "$PROJECT" --token "$TOKEN" --disable-check &>/dev/null || true
apigeecli datacollectors create -d "LLM Model" -n dc_llm_model -p STRING --org "$PROJECT" --token "$TOKEN" --disable-check &>/dev/null || true
apigeecli datacollectors create -d "LLM Prompt Tokens" -n dc_llm_prompt_tokens -p INTEGER --org "$PROJECT" --token "$TOKEN" --disable-check &>/dev/null || true
apigeecli datacollectors create -d "LLM Candidates Tokens" -n dc_llm_candidates_tokens -p INTEGER --org "$PROJECT" --token "$TOKEN" --disable-check &>/dev/null || true
apigeecli datacollectors create -d "LLM Transaction Cost V2" -n dc_llm_transaction_cost_v2 -p FLOAT --org "$PROJECT" --token "$TOKEN" --disable-check &>/dev/null || true

echo "4. Importing & Deploying Unified API Proxy (llm-budget-control-sse)..."
PROXY_REV=$(apigeecli apis create bundle -f "${SCRIPT_DIR}/apiproxy" -n llm-budget-control-sse --org "$PROJECT" --token "$TOKEN" --disable-check | jq -r ."revision")
echo "Imported llm-budget-control-sse revision: ${PROXY_REV}"
apigeecli apis deploy --wait --name llm-budget-control-sse --ovr --rev "$PROXY_REV" --org "$PROJECT" --env "$APIGEE_ENV" --token "$TOKEN" --sa "$SA_EMAIL" --disable-check

echo "5. Provisioning Tiered Demo API Products & Developer Apps..."
bash "${SCRIPT_DIR}/setup-demo-resources.sh"

echo "6. Attempting Custom Analytics Report creation (llm-budget-sse-cost-analysis)..."
curl -s -X POST \
  "https://apigee.googleapis.com/v1/organizations/${PROJECT}/reports" \
  --header "Authorization: Bearer ${TOKEN}" \
  --header "Accept: application/json" \
  --header "Content-Type: application/json" \
  --data '{"name":"llm-budget-sse-cost-analysis","displayName":"LLM Budget SSE and Buffered Cost Analysis","metrics":[{"name":"dc_llm_transaction_cost_v2","function":"sum"},{"name":"dc_llm_prompt_tokens","function":"sum"},{"name":"dc_llm_candidates_tokens","function":"sum"}],"dimensions":["api_product","developer_app","dc_llm_provider","dc_llm_model"],"properties":[{"value":[{}]}],"chartType":"column"}' \
  > /dev/null || true

echo ""
echo "================================================================="
echo "Deployment of llm-budget-control-sse Complete!"
echo "Proxy Base URL: https://${APIGEE_HOST}/v2/samples/llm-budget-control-sse"
echo "Run './run-demo-traffic.sh' to test Buffered + SSE budget control."
echo "Run 'python3 test/run_debug_tests.py' for automated trace assertions."
echo "================================================================="
