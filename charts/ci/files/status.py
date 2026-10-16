#!/usr/bin/env python3
"""Set a GitHub commit status. Env: ORG REPO SHA STATE (pending|success|failure|error,
or an Argo workflow status) CONTEXT DESCRIPTION TARGET_URL."""
import json
import os
import urllib.request

state = os.environ["STATE"].lower()
state = {"succeeded": "success", "failed": "failure", "error": "error", "running": "pending"}.get(state, state)
body = {"state": state, "context": os.environ["CONTEXT"], "description": os.environ.get("DESCRIPTION", "")[:140],
        "target_url": os.environ.get("TARGET_URL", "")}
req = urllib.request.Request(f"https://api.github.com/repos/{os.environ['ORG']}/{os.environ['REPO']}/statuses/{os.environ['SHA']}",
                             data=json.dumps(body).encode(), method="POST")
req.add_header("Authorization", "Bearer " + open("/github/token").read().strip())
req.add_header("Accept", "application/vnd.github+json")
with urllib.request.urlopen(req, timeout=30) as r:
    print(f"status: {body['context']} = {state} ({r.status})")
