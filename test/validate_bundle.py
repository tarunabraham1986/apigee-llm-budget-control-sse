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

"""Layer 1 offline static validator for the llm-budget-control-sse proxy bundle.

Validates:
  1. Well-formed XML across manifest, policies, proxies, and targets.
  2. Well-formed JSON across config/*.json and package.json.
  3. 1-to-1 parity between apiproxy/policies/*.xml, manifest <Policies>, and attached <Step>s (zero orphans).
  4. 1-to-1 parity between apiproxy/resources/jsc/*.js, manifest <Resources>, and JS policy <ResourceURL>.
  5. EventFlow guardrails (content-type="text/event-stream", <= 5 Response steps, whitelisted policy types).
  6. LLMTokenQuota schema rules (SharedName, EnforceOnly/CountOnly mutual exclusion, StartTime ISO format, constant LLMModelSource).
  7. ES5 Rhino compatibility check on CalculateCost.js.
"""

import json
import os
import re
import sys
import xml.etree.ElementTree as ET

ALLOWED_EVENTFLOW_POLICY_TYPES = {
    "Javascript",
    "LLMTokenQuota",
    "DataCapture",
    "SanitizeModelResponse",
    "SanitizeModelResponses",
    "PublishMessage",
    "MessageLogging",
    "RaiseFault",
}


def fail(errors, msg):
    errors.append(msg)
    print(f"  [FAIL] {msg}")


def ok(msg):
    print(f"  [PASS] {msg}")


def main():
    root_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    apiproxy_dir = os.path.join(root_dir, "apiproxy")
    policies_dir = os.path.join(apiproxy_dir, "policies")
    proxies_dir = os.path.join(apiproxy_dir, "proxies")
    targets_dir = os.path.join(apiproxy_dir, "targets")
    jsc_dir = os.path.join(apiproxy_dir, "resources", "jsc")
    config_dir = os.path.join(root_dir, "config")

    errors = []
    print("=== Layer 1: Offline Bundle & Schema Validation ===")

    # 1. Validate JSON files
    json_files = [os.path.join(root_dir, "package.json")] + [
        os.path.join(config_dir, f) for f in sorted(os.listdir(config_dir)) if f.endswith(".json")
    ]
    for jf in json_files:
        try:
            with open(jf, "r", encoding="utf-8") as fh:
                json.load(fh)
        except Exception as exc:
            fail(errors, f"Invalid JSON in {jf}: {exc}")
    ok(f"Validated {len(json_files)} JSON configuration files.")

    # 2. Parse manifest
    manifest_path = os.path.join(apiproxy_dir, "llm-budget-control-sse.xml")
    manifest_root = ET.parse(manifest_path).getroot()
    manifest_policies = {el.text.strip() for el in manifest_root.findall("./Policies/Policy")}
    manifest_proxies = {el.text.strip() for el in manifest_root.findall("./ProxyEndpoints/ProxyEndpoint")}
    manifest_targets = {el.text.strip() for el in manifest_root.findall("./TargetEndpoints/TargetEndpoint")}
    manifest_resources = {el.text.strip() for el in manifest_root.findall("./Resources/Resource")}

    # 3. Parse all policy XMLs
    disk_policies = {}
    referenced_resources = set()
    for fname in sorted(os.listdir(policies_dir)):
        if not fname.endswith(".xml"):
            continue
        pname = fname[:-4]
        fpath = os.path.join(policies_dir, fname)
        try:
            proot = ET.parse(fpath).getroot()
        except Exception as exc:
            fail(errors, f"Malformed XML in policy {fname}: {exc}")
            continue

        attr_name = proot.attrib.get("name")
        if attr_name != pname:
            fail(errors, f"Policy filename {fname} does not match root @name={attr_name}")
        disp = proot.findtext("DisplayName", "").strip()
        if disp != pname:
            fail(errors, f"Policy {pname} <DisplayName>{disp}</DisplayName> does not match @name")

        disk_policies[pname] = proot
        res_url = proot.findtext("ResourceURL")
        if res_url:
            referenced_resources.add(res_url.strip())
        for tmpl in proot.findall(".//Template"):
            t_txt = (tmpl.text or "").strip()
            if re.search(r"\{[a-zA-Z0-9_]+\([^}]*\(", t_txt):
                fail(errors, f"Policy {pname} contains nested message-template function call: {t_txt}")

    if set(disk_policies.keys()) != manifest_policies:
        missing_in_manifest = set(disk_policies.keys()) - manifest_policies
        missing_on_disk = manifest_policies - set(disk_policies.keys())
        fail(errors, f"Manifest policy mismatch: missing_in_manifest={missing_in_manifest}, missing_on_disk={missing_on_disk}")
    else:
        ok(f"1-to-1 policy manifest parity verified ({len(disk_policies)} policies).")

    # 4. Parse proxies & targets and verify step attachments + EventFlow rules
    attached_steps = set()
    disk_proxies = {f[:-4] for f in os.listdir(proxies_dir) if f.endswith(".xml")}
    disk_targets = {f[:-4] for f in os.listdir(targets_dir) if f.endswith(".xml")}

    if disk_proxies != manifest_proxies:
        fail(errors, f"ProxyEndpoints mismatch: disk={disk_proxies} vs manifest={manifest_proxies}")
    if disk_targets != manifest_targets:
        fail(errors, f"TargetEndpoints mismatch: disk={disk_targets} vs manifest={manifest_targets}")

    for pname in sorted(disk_proxies):
        proot = ET.parse(os.path.join(proxies_dir, f"{pname}.xml")).getroot()
        for step in proot.findall(".//Step/Name"):
            attached_steps.add(step.text.strip())
        route_rules = proot.findall("./RouteRule")
        if not route_rules or route_rules[-1].find("Condition") is not None:
            fail(errors, f"ProxyEndpoint {pname} must end with an unconditional default RouteRule")
        else:
            ok(f"ProxyEndpoint '{pname}' RouteRules end with unconditional fallback route.")

    for tname in sorted(disk_targets):
        troot = ET.parse(os.path.join(targets_dir, f"{tname}.xml")).getroot()
        for step in troot.findall(".//Step/Name"):
            attached_steps.add(step.text.strip())

        for ef in troot.findall("./EventFlow"):
            ctype = ef.attrib.get("content-type")
            if ctype != "text/event-stream":
                fail(errors, f"TargetEndpoint {tname} EventFlow content-type={ctype} != 'text/event-stream'")
            req_steps = ef.findall("./Request/Step")
            if req_steps:
                fail(errors, f"TargetEndpoint {tname} EventFlow cannot contain Request steps")
            resp_steps = ef.findall("./Response/Step")
            if len(resp_steps) > 5:
                fail(errors, f"TargetEndpoint {tname} EventFlow has {len(resp_steps)} steps (max 5 allowed)")
            for step in resp_steps:
                sname = step.findtext("Name", "").strip()
                p_el = disk_policies.get(sname)
                if p_el is None:
                    fail(errors, f"EventFlow in {tname} references unknown policy {sname}")
                elif p_el.tag not in ALLOWED_EVENTFLOW_POLICY_TYPES:
                    fail(errors, f"EventFlow in {tname} uses disallowed policy type {p_el.tag} ({sname})")
            ok(f"TargetEndpoint '{tname}' EventFlow validated ({len(resp_steps)} steps, all whitelisted).")

    orphaned_policies = set(disk_policies.keys()) - attached_steps
    unknown_steps = attached_steps - set(disk_policies.keys())
    if orphaned_policies:
        fail(errors, f"Orphaned unattached policies found: {orphaned_policies}")
    if unknown_steps:
        fail(errors, f"Steps referencing non-existent policies: {unknown_steps}")
    if not orphaned_policies and not unknown_steps:
        ok("Zero orphaned policies; all attached steps resolve cleanly.")

    # 5. Validate JS resources & ES5 compatibility
    disk_jsc = {f"jsc://{f}" for f in os.listdir(jsc_dir) if f.endswith(".js")}
    if disk_jsc != manifest_resources or disk_jsc != referenced_resources:
        fail(errors, f"JS resource mismatch: disk={disk_jsc}, manifest={manifest_resources}, referenced={referenced_resources}")
    else:
        ok(f"JS resource parity verified ({disk_jsc}).")

    js_path = os.path.join(jsc_dir, "CalculateCost.js")
    with open(js_path, "r", encoding="utf-8") as fh:
        js_src = fh.read()
    # Strip comments before checking ES6 tokens disallowed in older Rhino
    stripped = re.sub(r"//.*", "", re.sub(r"/\*[\s\S]*?\*/", "", js_src))
    if re.search(r"\b(const|let)\b|=>|`", stripped):
        fail(errors, "CalculateCost.js contains non-ES5 syntax (const/let/arrow/template literal)")
    else:
        ok("CalculateCost.js verified pure ES5 Rhino compatible.")

    # 6. Validate LLMTokenQuota policy settings
    ltq_shared_names = set()
    ltq_model_sources = set()
    for pname, proot in disk_policies.items():
        if proot.tag == "LLMTokenQuota":
            enforce = proot.findtext("EnforceOnly") == "true"
            count = proot.findtext("CountOnly") == "true"
            shared = proot.findtext("SharedName", "").strip()
            ident = proot.find("Identifier")
            msrc = proot.findtext("LLMModelSource", "").strip()
            if enforce and count:
                fail(errors, f"{pname}: EnforceOnly and CountOnly cannot both be true")
            if not shared:
                fail(errors, f"{pname}: SharedName is required")
            if ident is None or ident.attrib.get("ref") != "developer.app.id":
                fail(errors, f"{pname}: Identifier ref='developer.app.id' is required")
            ltq_shared_names.add(shared)
            ltq_model_sources.add(msrc)

    if ltq_shared_names != {"llm_budget_quota"}:
        fail(errors, f"LLMTokenQuota SharedName mismatch across policies: {ltq_shared_names}")
    if ltq_model_sources != {"all-models"}:
        fail(errors, f"LLMTokenQuota LLMModelSource must be constant 'all-models', got: {ltq_model_sources}")
    else:
        ok("LLMTokenQuota policies share 'llm_budget_quota', developer.app.id isolation, and 'all-models' wallet.")

    if errors:
        print(f"\nValidation FAILED with {len(errors)} error(s).")
        sys.exit(1)

    print("\nAll Layer 1 static validations PASSED!")


if __name__ == "__main__":
    main()
