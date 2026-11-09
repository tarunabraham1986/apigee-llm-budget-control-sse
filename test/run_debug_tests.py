#!/usr/bin/env python3
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

"""Automated Apigee Debug Session & End-to-End Test Suite for llm-budget-control-sse.

Covers Layers 3, 4, and 5 of the Test Plan:
  - Missing API key -> HTTP 401
  - Buffered Gemini call -> HTTP 200 + all 7 x-llm-* headers (x-llm-streaming: false)
  - Streaming SSE Gemini call (without x-llm-provider header) -> HTTP 200 + SSE chunks + identical 7 headers (x-llm-streaming: true)
  - Cross-model shared wallet verification (gemini-2.5-flash + gemini-2.5-pro deduct from same App wallet)
  - Cross-mode budget exhaustion on Marketing App (20,000 micro-$ cap) -> HTTP 429 on BOTH Buffered and SSE
  - Developer App isolation -> Engineering App (1,000,000 micro-$ cap) continues returning HTTP 200
  - Apigee Debug Session trace assertions -> LTQ-CountBudget and DC-CollectCostMetrics execute ONCE per buffered or multi-chunk SSE call
"""

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

EXPECTED_TELEMETRY_HEADERS = [
    "x-llm-provider",
    "x-llm-model",
    "x-llm-streaming",
    "x-llm-budget-limit-micro",
    "x-llm-budget-used-before-request-micro",
    "x-llm-budget-remaining-before-request-micro",
    "x-llm-budget-reset-utc",
]


def load_shell_exports(filepath):
    data = {}
    if not os.path.exists(filepath):
        return data
    cmd = ["bash", "-c", f'source "{filepath}" && env']
    out = subprocess.check_output(cmd, text=True)
    for line in out.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            data[k] = v
    return data


def http_request(url, method="GET", headers=None, json_body=None, timeout=60):
    hdrs = dict(headers or {})
    raw_data = None
    if json_body is not None:
        raw_data = json.dumps(json_body).encode("utf-8")
        hdrs.setdefault("Content-Type", "application/json")

    req = urllib.request.Request(url, data=raw_data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            resp_headers = {k.lower(): v for k, v in resp.info().items()}
            body_text = resp.read().decode("utf-8", errors="replace")
            return resp.status, resp_headers, body_text
    except urllib.error.HTTPError as err:
        resp_headers = {k.lower(): v for k, v in (err.headers.items() if err.headers else [])}
        body_text = err.read().decode("utf-8", errors="replace")
        return err.code, resp_headers, body_text


def get_deployed_revision(project, env_name, proxy_name, token):
    url = f"https://apigee.googleapis.com/v1/organizations/{project}/environments/{env_name}/apis/{proxy_name}/deployments"
    status, _, body = http_request(url, headers={"Authorization": f"Bearer {token}"})
    if status != 200:
        raise RuntimeError(f"Failed to query deployments for {proxy_name} (HTTP {status}): {body}")
    parsed = json.loads(body)
    deployments = parsed.get("deployments", [])
    if not deployments:
        raise RuntimeError(f"Proxy {proxy_name} has no active deployments in env {env_name}")
    return str(deployments[0]["revision"])


def parse_trace_transaction(tx_data):
    variables = {}
    executed_counts = {}

    for point in tx_data.get("point", []):
        point_id = point.get("id")
        results = point.get("results", [])

        step_name = None
        condition_false = False

        for res in results:
            action = res.get("ActionResult")
            if action == "VariableAccess":
                for access in res.get("accessList", []):
                    for op in ("Set", "Get"):
                        op_data = access.get(op)
                        if op_data and op_data.get("name") is not None and op_data.get("value") is not None:
                            variables[op_data["name"]] = op_data["value"]

            if point_id == "Execution" and action == "DebugInfo":
                for prop in res.get("properties", {}).get("property", []):
                    if prop.get("name") == "stepDefinition-name":
                        step_name = prop.get("value")
                    if prop.get("name") in ("expressionResult", "ExpressionResult") and str(prop.get("value")).lower() == "false":
                        condition_false = True

            if point_id == "Execution" and action == "Condition":
                for prop in res.get("properties", {}).get("property", []):
                    if prop.get("name") in ("expressionResult", "ExpressionResult") and str(prop.get("value")).lower() == "false":
                        condition_false = True

        if point_id == "Execution" and step_name and not condition_false:
            executed_counts[step_name] = executed_counts.get(step_name, 0) + 1

    return variables, executed_counts


def assert_true(cond, msg, failures):
    if cond:
        print(f"  [PASS] {msg}")
    else:
        print(f"  [FAIL] {msg}")
        failures.append(msg)


def assert_telemetry_headers(hdrs, label, failures, expected_streaming=None):
    missing = [h for h in EXPECTED_TELEMETRY_HEADERS if h not in hdrs or hdrs[h] == ""]
    assert_true(not missing, f"{label}: all 7 x-llm-* headers present (missing={missing})", failures)
    if expected_streaming is not None:
        assert_true(
            hdrs.get("x-llm-streaming") == expected_streaming,
            f"{label}: x-llm-streaming == '{expected_streaming}' (got '{hdrs.get('x-llm-streaming')}')",
            failures,
        )


def main():
    parser = argparse.ArgumentParser(description="Run E2E + Apigee Debug trace tests for llm-budget-control-sse")
    parser.add_argument("--deploy", action="store_true", help="Run deploy-llm-budget-control-sse.sh before testing")
    parser.add_argument("--skip-reset-apps", action="store_true", help="Reuse existing demo-keys.env without resetting apps")
    args = parser.parse_args()

    root_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    env_vars = load_shell_exports(os.path.join(root_dir, "env.sh"))

    project = env_vars.get("PROJECT")
    apigee_env = env_vars.get("APIGEE_ENV")
    apigee_host = env_vars.get("APIGEE_HOST")
    region = env_vars.get("REGION", "us-west1")
    if not region or region == "REGION_TO_SET":
        region = "us-west1"

    if (
        not project
        or not apigee_env
        or not apigee_host
        or project.endswith("_TO_SET")
        or apigee_env.endswith("_TO_SET")
        or apigee_host.endswith("_TO_SET")
    ):
        print("Error: Please configure PROJECT, APIGEE_ENV, and APIGEE_HOST in env.sh")
        sys.exit(1)

    if args.deploy:
        print("=== Running deploy-llm-budget-control-sse.sh ===")
        subprocess.run(["bash", os.path.join(root_dir, "deploy-llm-budget-control-sse.sh")], check=True)
    elif not args.skip_reset_apps or not os.path.exists(os.path.join(root_dir, "demo-keys.env")):
        print("=== Refreshing Demo Apps for Clean Quota Wallets (setup-demo-resources.sh) ===")
        subprocess.run(["bash", os.path.join(root_dir, "setup-demo-resources.sh")], check=True)

    demo_vars = load_shell_exports(os.path.join(root_dir, "demo-keys.env"))
    marketing_key = demo_vars.get("MARKETING_KEY")
    engineering_key = demo_vars.get("ENGINEERING_KEY")
    if not marketing_key or not engineering_key:
        print("Error: MARKETING_KEY or ENGINEERING_KEY missing in demo-keys.env")
        sys.exit(1)

    print("Waiting 6 seconds for fresh App credentials to propagate...")
    time.sleep(6)

    token = subprocess.check_output(["gcloud", "auth", "print-access-token"], text=True).strip()
    revision = get_deployed_revision(project, apigee_env, "llm-budget-control-sse", token)
    print(f"Active deployed revision for llm-budget-control-sse: {revision}")

    debug_base = (
        f"https://apigee.googleapis.com/v1/organizations/{project}/environments/{apigee_env}"
        f"/apis/llm-budget-control-sse/revisions/{revision}/debugsessions"
    )
    status, _, dbg_body = http_request(
        f"{debug_base}?timeout=600",
        method="POST",
        headers={"Authorization": f"Bearer {token}"},
        json_body={},
    )
    if status not in (200, 201):
        print(f"Failed to create Apigee Debug Session (HTTP {status}): {dbg_body}")
        sys.exit(1)
    session_id = json.loads(dbg_body)["name"].split("/")[-1]
    print(f"Created Debug Session: {session_id} (waiting 5s for session activation...)")
    time.sleep(5)

    failures = []
    base_url = f"https://{apigee_host}/v2/samples/llm-budget-control-sse"

    def vertex_url(model, stream=False):
        verb = "streamGenerateContent?alt=sse" if stream else "generateContent"
        return f"{base_url}/v1/projects/{project}/locations/{region}/publishers/google/models/{model}:{verb}"

    # --- Test 1: Missing API Key -> 401 ---
    print("\n--- Test 1: Missing API Key (Expect 401) ---")
    st1, _, _ = http_request(
        vertex_url("gemini-2.5-flash"),
        method="POST",
        json_body={"contents": [{"role": "user", "parts": [{"text": "Hi"}]}]},
    )
    assert_true(st1 == 401, f"Missing x-apikey returns HTTP 401 (got {st1})", failures)

    # --- Test 2: Engineering App Buffered Call (gemini-2.5-flash) ---
    print("\n--- Test 2: Engineering App Buffered Call (gemini-2.5-flash) ---")
    st2, h2, b2 = http_request(
        vertex_url("gemini-2.5-flash", stream=False),
        method="POST",
        headers={"x-apikey": engineering_key, "x-llm-provider": "google"},
        json_body={"contents": [{"role": "user", "parts": [{"text": "Reply with the word buffered."}]}]},
    )
    assert_true(st2 == 200, f"Buffered Gemini call returns HTTP 200 (got {st2})", failures)
    assert_telemetry_headers(h2, "Buffered Call", failures, expected_streaming="false")
    assert_true(h2.get("x-llm-budget-used-before-request-micro") == "0", "Initial opening used balance == 0", failures)

    time.sleep(3)

    # --- Test 3: Engineering App Streaming SSE Call (Auto-Detect Provider, Multi-Chunk) ---
    print("\n--- Test 3: Engineering App Streaming SSE Call (Auto-Detect Provider) ---")
    st3, h3, b3 = http_request(
        vertex_url("gemini-2.5-flash", stream=True),
        method="POST",
        headers={"x-apikey": engineering_key, "Accept": "text/event-stream"},
        json_body={"contents": [{"role": "user", "parts": [{"text": "Count from 1 to 15 separated by spaces."}]}]},
    )
    assert_true(st3 == 200, f"SSE Gemini call returns HTTP 200 (got {st3})", failures)
    assert_true("text/event-stream" in h3.get("content-type", ""), f"SSE Content-Type is text/event-stream (got {h3.get('content-type')})", failures)
    sse_data_lines = [ln for ln in b3.splitlines() if ln.startswith("data:")]
    assert_true(len(sse_data_lines) >= 1, f"Received SSE data chunks (count={len(sse_data_lines)})", failures)
    assert_telemetry_headers(h3, "SSE Call", failures, expected_streaming="true")
    assert_true(h3.get("x-llm-provider") == "google", "Auto-detected x-llm-provider == 'google' without request header", failures)
    used_before_sse = int(h3.get("x-llm-budget-used-before-request-micro", "0"))
    assert_true(used_before_sse > 0, f"SSE opening balance reflects Test 2 buffered spend ({used_before_sse} micro-$)", failures)

    time.sleep(3)

    # --- Test 4: Cross-Model Shared Wallet + Verify SSE Spend Added ---
    print("\n--- Test 4: Engineering App Cross-Model Wallet Check (gemini-2.5-pro) ---")
    st4, h4, _ = http_request(
        vertex_url("gemini-2.5-pro", stream=False),
        method="POST",
        headers={"x-apikey": engineering_key},
        json_body={"contents": [{"role": "user", "parts": [{"text": "Say ok."}]}]},
    )
    assert_true(st4 == 200, f"Cross-model Pro call returns HTTP 200 (got {st4})", failures)
    used_after_sse = int(h4.get("x-llm-budget-used-before-request-micro", "0"))
    assert_true(
        used_after_sse > used_before_sse,
        f"Shared wallet incremented by SSE call ({used_before_sse} -> {used_after_sse} micro-$)",
        failures,
    )

    # --- Test 5: Exhaust Marketing App ($0.02 = 20,000 micro-$) across Buffered + SSE ---
    print("\n--- Test 5: Marketing App Cross-Mode Budget Exhaustion (20,000 micro-$ cap) ---")
    for idx in range(1, 5):
        use_sse = idx % 2 == 0
        st_m, _, _ = http_request(
            vertex_url("gemini-2.5-pro", stream=use_sse),
            method="POST",
            headers={"x-apikey": marketing_key},
            json_body={"contents": [{"role": "user", "parts": [{"text": "Write a 180-word launch summary and feature breakdown for a solar smartwatch."}]}]},
        )
        print(f"  Marketing spend call #{idx} (sse={use_sse}) -> HTTP {st_m}")
        time.sleep(3)
        if st_m == 429:
            break

    st5_buf, h5_buf, b5_buf = http_request(
        vertex_url("gemini-2.5-flash", stream=False),
        method="POST",
        headers={"x-apikey": marketing_key},
        json_body={"contents": [{"role": "user", "parts": [{"text": "Blocked buffered check"}]}]},
    )
    assert_true(st5_buf == 429, f"Over-budget Buffered call blocked with HTTP 429 (got {st5_buf})", failures)
    assert_telemetry_headers(h5_buf, "Over-Budget Buffered 429", failures, expected_streaming="false")
    assert_true(
        h5_buf.get("x-llm-budget-remaining-before-request-micro") == "0",
        "Over-budget Buffered 429 reports remaining-before-request-micro == 0",
        failures,
    )
    err_buf = json.loads(b5_buf)
    assert_true(err_buf.get("error", {}).get("status") == "RESOURCE_EXHAUSTED", "429 JSON error status == RESOURCE_EXHAUSTED", failures)

    st5_sse, h5_sse, _ = http_request(
        vertex_url("gemini-2.5-flash", stream=True),
        method="POST",
        headers={"x-apikey": marketing_key, "Accept": "text/event-stream"},
        json_body={"contents": [{"role": "user", "parts": [{"text": "Blocked SSE check"}]}]},
    )
    assert_true(st5_sse == 429, f"Over-budget SSE call blocked with HTTP 429 (got {st5_sse})", failures)
    assert_telemetry_headers(h5_sse, "Over-Budget SSE 429", failures, expected_streaming="true")

    # --- Test 6: Developer App Isolation ---
    print("\n--- Test 6: Developer App Isolation (Engineering App SSE -> Expect 200) ---")
    st6, _, _ = http_request(
        vertex_url("gemini-2.5-flash", stream=True),
        method="POST",
        headers={"x-apikey": engineering_key, "Accept": "text/event-stream"},
        json_body={"contents": [{"role": "user", "parts": [{"text": "Say isolated."}]}]},
    )
    assert_true(st6 == 200, f"Engineering App SSE still succeeds with HTTP 200 while Marketing is 429 (got {st6})", failures)

    # --- Layer 5: Debug Session Trace Inspection ---
    print("\n--- Layer 5: Inspecting Apigee Debug Session Traces ---")
    time.sleep(8)
    st_list, _, list_body = http_request(
        f"{debug_base}/{session_id}/data",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert_true(st_list == 200, f"Retrieved Debug Session transaction list (HTTP {st_list})", failures)
    tx_ids = json.loads(list_body) if st_list == 200 else []
    print(f"  Captured {len(tx_ids)} trace transaction(s) in session {session_id}")

    saw_buffered_200 = False
    saw_sse_200 = False
    saw_quota_429 = False

    for tx_id in tx_ids:
        st_tx, _, tx_body = http_request(
            f"{debug_base}/{session_id}/data/{tx_id}",
            headers={"Authorization": f"Bearer {token}"},
        )
        if st_tx != 200:
            continue
        variables, counts = parse_trace_transaction(json.loads(tx_body))
        is_sse = variables.get("is_sse_request")
        ltq_count_runs = counts.get("LTQ-CountBudget", 0)
        dc_runs = counts.get("DC-CollectCostMetrics", 0)
        fmt_429_runs = counts.get("AM-FormatQuotaViolation", 0)

        if fmt_429_runs > 0:
            saw_quota_429 = True
            assert_true(
                counts.get("JS-CalculateCost", 0) == 0 and ltq_count_runs == 0,
                f"Trace {tx_id} (429): zero target/cost execution on blocked request",
                failures,
            )
        elif is_sse == "false" and ltq_count_runs > 0:
            saw_buffered_200 = True
            assert_true(ltq_count_runs == 1, f"Trace {tx_id} (Buffered 200): LTQ-CountBudget ran exactly once ({ltq_count_runs})", failures)
            assert_true(dc_runs == 1, f"Trace {tx_id} (Buffered 200): DC-CollectCostMetrics ran exactly once ({dc_runs})", failures)
        elif is_sse == "true" and counts.get("JS-CalculateCost", 0) > 0:
            saw_sse_200 = True
            assert_true(
                ltq_count_runs == 1,
                f"Trace {tx_id} (SSE 200, JS runs={counts.get('JS-CalculateCost')}): LTQ-CountBudget ran ONCE ({ltq_count_runs})",
                failures,
            )
            assert_true(
                dc_runs == 1,
                f"Trace {tx_id} (SSE 200): DC-CollectCostMetrics ran ONCE ({dc_runs})",
                failures,
            )

    assert_true(saw_buffered_200, "Verified at least one Buffered 200 trace in Debug Session", failures)
    assert_true(saw_sse_200, "Verified at least one SSE EventFlow 200 trace in Debug Session", failures)
    assert_true(saw_quota_429, "Verified at least one Over-Budget 429 trace in Debug Session", failures)

    print("\n=================================================================")
    if failures:
        print(f"TEST SUITE FAILED ({len(failures)} assertion failure(s)):")
        for f in failures:
            print(f"  - {f}")
        sys.exit(1)
    print("ALL E2E & APIGEE DEBUG TRACE ASSERTIONS PASSED!")
    print("=================================================================")


if __name__ == "__main__":
    main()
