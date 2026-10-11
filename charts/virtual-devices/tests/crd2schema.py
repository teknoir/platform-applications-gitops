#!/usr/bin/env python3
"""Convert CustomResourceDefinitions into kubeconform JSON schemas.

Usage: python3 -I crd2schema.py OUT_DIR FILE...

Writes OUT_DIR/<group>/<kind>_<version>.json (kubeconform's
{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json layout) for every CRD
found in FILE (multi-document YAML; other kinds are ignored). Objects that declare
`properties` get "additionalProperties": false unless they preserve unknown fields,
so kubeconform -strict also rejects misspelled fields in custom resources.
"""
import json
import os
import sys

import yaml


def strict(node):
    if isinstance(node, dict):
        if (
            node.get("type") == "object"
            and "properties" in node
            and "additionalProperties" not in node
            and not node.get("x-kubernetes-preserve-unknown-fields")
        ):
            node["additionalProperties"] = False
        for value in node.values():
            strict(value)
    elif isinstance(node, list):
        for value in node:
            strict(value)
    return node


def main():
    out_dir, files = sys.argv[1], sys.argv[2:]
    written = 0
    for path in files:
        with open(path) as f:
            for doc in yaml.safe_load_all(f):
                if not doc or doc.get("kind") != "CustomResourceDefinition":
                    continue
                group = doc["spec"]["group"]
                kind = doc["spec"]["names"]["kind"].lower()
                for version in doc["spec"]["versions"]:
                    schema = version.get("schema", {}).get("openAPIV3Schema")
                    if not schema:
                        continue
                    schema = strict(json.loads(json.dumps(schema)))
                    # metadata is validated by the API server, not by the CRD schema.
                    schema.setdefault("properties", {})["metadata"] = {"type": "object"}
                    target = os.path.join(out_dir, group, f"{kind}_{version['name']}.json")
                    os.makedirs(os.path.dirname(target), exist_ok=True)
                    with open(target, "w") as out:
                        json.dump(schema, out)
                    written += 1
    print(f"crd2schema: wrote {written} schema(s) to {out_dir}")


if __name__ == "__main__":
    main()
