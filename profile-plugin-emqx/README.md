# profile-plugin-emqx

EMQX 5 broker for a teamspace, wrapping the upstream `emqx` chart.

## Config changes roll EMQX

`emqx.recreatePods: true` makes the upstream chart add a `checksum/config`
annotation to the StatefulSet pod template. It is a hash of the generated
ConfigMap, which carries `emqx.emqxConfig` (the `EMQX_*` environment). Changing
any `emqxConfig` value therefore restarts `emqx-0` once, so a chart upgrade
that changes broker config takes effect without a manual restart.

## Certificate renewal needs no restart

The TLS listener on 8883 reads `/certs/tls.crt` and `/certs/tls.key`. They come
from the Secret `domain-wildcard-tls`, mounted as a directory at `/certs` (no
`subPath`), so kubelet updates the files in place when profile-controller copies
a renewed certificate into the teamspace. EMQX picks the new files up by hot
reload (about 2 minutes, no restart, no dropped clients). Do not add a
`subPath` to the mount and do not add a restart-on-secret-change tool: either
would break this or restart EMQX on every renewal.
