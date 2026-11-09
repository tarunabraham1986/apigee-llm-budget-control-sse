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

export PATH="$PATH:$HOME/.local/bin:$HOME/.apigeecli/bin"

if [ -z "$PROJECT" ] || [ -z "$APIGEE_ENV" ] || [[ "$PROJECT" == *_TO_SET ]] || [[ "$APIGEE_ENV" == *_TO_SET ]]; then
  echo "Error: Please configure PROJECT and APIGEE_ENV in env.sh"
  exit 1
fi

TOKEN="${TOKEN:-$(gcloud auth print-access-token)}"
SUFFIX=$(date +%s)

MKT_DEV_EMAIL="marketing-sse-lead@example.com"
ENG_DEV_EMAIL="engineering-sse-lead@example.com"
MKT_PROD="llm-budget-sse-marketing-product"
ENG_PROD="llm-budget-sse-engineering-product"

echo "Ensuring Demo Developers..."
apigeecli developers create --user marketing-sse-lead --email "$MKT_DEV_EMAIL" --first MarketingSSE --last Lead --org "$PROJECT" --token "$TOKEN" --disable-check &>/dev/null || true
apigeecli developers create --user engineering-sse-lead --email "$ENG_DEV_EMAIL" --first EngineeringSSE --last Lead --org "$PROJECT" --token "$TOKEN" --disable-check &>/dev/null || true

DEV_A_ID=$(apigeecli developers get --email "$MKT_DEV_EMAIL" --org "$PROJECT" --token "$TOKEN" --disable-check 2>/dev/null | jq -r '.developerId // empty' || true)
DEV_B_ID=$(apigeecli developers get --email "$ENG_DEV_EMAIL" --org "$PROJECT" --token "$TOKEN" --disable-check 2>/dev/null | jq -r '.developerId // empty' || true)

echo "Cleaning up previous SSE Demo Apps to reset developer.app.id quota wallets..."
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

echo "Ensuring Tiered API Products (Marketing = 20,000 micro-\$ [\$0.02], Engineering = 1,000,000 micro-\$ [\$1.00])..."
# Marketing Product: $0.02/month = 20,000 micro-dollars
apigeecli products create --name "$MKT_PROD" \
  --display-name "LLM Budget SSE Marketing Product" \
  --envs "$APIGEE_ENV" \
  --opgrp "${SCRIPT_DIR}/config/operations.json" \
  --quota-counter-scope PROXY \
  --approval auto \
  --attrs "budget_limit_micro_dollars=20000,budget_interval=1,budget_timeunit=month" \
  --org "$PROJECT" \
  --token "$TOKEN" \
  --disable-check &>/dev/null || \
apigeecli products update --name "$MKT_PROD" \
  --display-name "LLM Budget SSE Marketing Product" \
  --envs "$APIGEE_ENV" \
  --opgrp "${SCRIPT_DIR}/config/operations.json" \
  --quota-counter-scope PROXY \
  --approval auto \
  --attrs "budget_limit_micro_dollars=20000,budget_interval=1,budget_timeunit=month" \
  --org "$PROJECT" \
  --token "$TOKEN" \
  --disable-check >/dev/null

# Engineering Product: $1.00/month = 1,000,000 micro-dollars
apigeecli products create --name "$ENG_PROD" \
  --display-name "LLM Budget SSE Engineering Product" \
  --envs "$APIGEE_ENV" \
  --opgrp "${SCRIPT_DIR}/config/operations.json" \
  --quota-counter-scope PROXY \
  --approval auto \
  --attrs "budget_limit_micro_dollars=1000000,budget_interval=1,budget_timeunit=month" \
  --org "$PROJECT" \
  --token "$TOKEN" \
  --disable-check &>/dev/null || \
apigeecli products update --name "$ENG_PROD" \
  --display-name "LLM Budget SSE Engineering Product" \
  --envs "$APIGEE_ENV" \
  --opgrp "${SCRIPT_DIR}/config/operations.json" \
  --quota-counter-scope PROXY \
  --approval auto \
  --attrs "budget_limit_micro_dollars=1000000,budget_interval=1,budget_timeunit=month" \
  --org "$PROJECT" \
  --token "$TOKEN" \
  --disable-check >/dev/null

APP_A_NAME="marketing-sse-app-${SUFFIX}"
APP_B_NAME="engineering-sse-app-${SUFFIX}"

echo "Creating Fresh Demo Developer Apps (${APP_A_NAME}, ${APP_B_NAME})..."
apigeecli apps create --name "$APP_A_NAME" --email "$MKT_DEV_EMAIL" --prods "$MKT_PROD" --org "$PROJECT" --token "$TOKEN" --disable-check >/dev/null
apigeecli apps create --name "$APP_B_NAME" --email "$ENG_DEV_EMAIL" --prods "$ENG_PROD" --org "$PROJECT" --token "$TOKEN" --disable-check >/dev/null

MARKETING_KEY=$(apigeecli apps get --name "$APP_A_NAME" --org "$PROJECT" --token "$TOKEN" --disable-check | jq -r '.[0].credentials[0].consumerKey')
ENGINEERING_KEY=$(apigeecli apps get --name "$APP_B_NAME" --org "$PROJECT" --token "$TOKEN" --disable-check | jq -r '.[0].credentials[0].consumerKey')

cat > "${SCRIPT_DIR}/demo-keys.env" <<EOF
export MARKETING_APP_NAME="${APP_A_NAME}"
export MARKETING_KEY="${MARKETING_KEY}"
export ENGINEERING_APP_NAME="${APP_B_NAME}"
export ENGINEERING_KEY="${ENGINEERING_KEY}"
EOF

echo "================================================================="
echo "Demo Resources Ready!"
echo "  Marketing App   : ${APP_A_NAME} (Cap: 20,000 micro-\$ / \$0.02)"
echo "  Marketing Key   : ${MARKETING_KEY}"
echo "  Engineering App : ${APP_B_NAME} (Cap: 1,000,000 micro-\$ / \$1.00)"
echo "  Engineering Key : ${ENGINEERING_KEY}"
echo "  Saved to        : ${SCRIPT_DIR}/demo-keys.env"
echo "================================================================="
