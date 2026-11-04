#!/usr/bin/env python3
"""Build a static Envoy bootstrap that reproduces the ingress gateway filter chain.

Input: the rendered EnvoyFilter (helm template of templates/istio-auth.yaml).
The HTTP_FILTER patches are taken verbatim from it, in the order Istio applies them:
  ext_authz (INSERT_FIRST) -> denial Lua (INSERT_BEFORE ext_authz) -> marker Lua (INSERT_AFTER ext_authz).
Result chain: lua, ext_authz, lua.authz_passed, router.

Both listeners allow WebSocket upgrades and use a 32 KiB per-connection buffer limit, so the harness
notices when a change starts buffering normal responses or breaks upgrades.

Two listeners: "gw" with the full chain, "nomarker" without the marker filter (checks the documented
fallback when the marker patch is lost).
"""
import json
import sys

import yaml

rendered, cert, key, ports_json = sys.argv[1:5]
ports = json.loads(ports_json)

docs = [d for d in yaml.safe_load_all(open(rendered)) if d]
ef = next(d for d in docs if d.get("kind") == "EnvoyFilter")
filters = {}
for p in ef["spec"]["configPatches"]:
    if p["applyTo"] != "HTTP_FILTER":
        continue
    v = p["patch"]["value"]
    filters[v["name"]] = (p["patch"]["operation"], v)

ext = filters["envoy.filters.http.ext_authz"]
assert ext[0] == "INSERT_FIRST", ext[0]
lua = filters.get("envoy.filters.http.lua")
assert lua and lua[0] == "INSERT_BEFORE", lua and lua[0]
marker = filters.get("envoy.filters.http.lua.authz_passed")
if marker:
    assert marker[0] == "INSERT_AFTER", marker[0]

BUFFER_LIMIT = 32768

AUTHZ_CLUSTER = ext[1]["typed_config"]["http_service"]["server_uri"]["cluster"]

ROUTER = {
    "name": "envoy.filters.http.router",
    "typed_config": {"@type": "type.googleapis.com/envoy.extensions.filters.http.router.v3.Router"},
}


def chain(with_marker):
    out = [lua[1], ext[1]]
    if with_marker and marker:
        out.append(marker[1])
    out.append(ROUTER)
    return out


def disabled_authz():
    return {
        "envoy.filters.http.ext_authz": {
            "@type": "type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthzPerRoute",
            "disabled": True,
        }
    }


def route(prefix, per_filter=None):
    r = {"match": {"prefix": prefix}, "route": {"cluster": "backend", "timeout": "30s"}}
    if per_filter:
        r["typed_per_filter_config"] = per_filter
    return r


route_config = {
    "name": "local",
    "virtual_hosts": [
        # like the argocd vhost: ext_authz off, Lua (and the marker) still on
        {
            "name": "argocd",
            "domains": ["argocd.teknoir.test"],
            "typed_per_filter_config": disabled_authz(),
            "routes": [route("/")],
        },
        {
            "name": "all",
            "domains": ["*"],
            "routes": [
                # like the oauth2-proxy-auth route: ext_authz off for /oauth2/
                route("/oauth2/", disabled_authz()),
                route("/"),
            ],
        },
    ],
}


def listener(name, port, with_marker):
    return {
        "name": name,
        "address": {"socket_address": {"address": "127.0.0.1", "port_value": port}},
        # small on purpose: anything the Lua (or Envoy) buffered beyond this would fail the large-body checks
        "per_connection_buffer_limit_bytes": BUFFER_LIMIT,
        "filter_chains": [
            {
                "transport_socket": {
                    "name": "envoy.transport_sockets.tls",
                    "typed_config": {
                        "@type": "type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.DownstreamTlsContext",
                        "common_tls_context": {
                            "alpn_protocols": ["h2", "http/1.1"],
                            "tls_certificates": [
                                {
                                    "certificate_chain": {"filename": cert},
                                    "private_key": {"filename": key},
                                }
                            ],
                        },
                    },
                },
                "filters": [
                    {
                        "name": "envoy.filters.network.http_connection_manager",
                        "typed_config": {
                            "@type": "type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager",
                            "stat_prefix": name,
                            "codec_type": "AUTO",
                            # as on the real gateway: WebSocket upgrades are allowed
                            "upgrade_configs": [{"upgrade_type": "websocket"}],
                            "use_remote_address": True,
                            "route_config": route_config,
                            "http_filters": chain(with_marker),
                        },
                    }
                ],
            }
        ],
    }


def cluster(name, port):
    return {
        "name": name,
        "type": "STATIC",
        "connect_timeout": "2s",
        "load_assignment": {
            "cluster_name": name,
            "endpoints": [
                {
                    "lb_endpoints": [
                        {"endpoint": {"address": {"socket_address": {"address": "127.0.0.1", "port_value": port}}}}
                    ]
                }
            ],
        },
    }


bootstrap = {
    "admin": {"address": {"socket_address": {"address": "127.0.0.1", "port_value": ports["admin"]}}},
    "static_resources": {
        "listeners": [
            listener("gw", ports["gw"], True),
            listener("nomarker", ports["nomarker"], False),
        ],
        "clusters": [cluster("backend", ports["backend"]), cluster(AUTHZ_CLUSTER, ports["authz"])],
    },
}
print(json.dumps(bootstrap, indent=1))
