#!/usr/bin/env bash
set -euo pipefail

MANIFEST_FILE="manifest-oauth2-proxy-secret.yaml"
NAMESPACE="teknoir-auth"
SECRET_NAME="oauth2-proxy-secret"

cookie_secret="${1:-}"
if [ -z "${cookie_secret}" ]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to generate a cookie secret." >&2
    exit 1
  fi

  cookie_secret="$(python3 - <<'PY'
import os,base64
print(base64.b64encode(os.urandom(16)).decode())
PY
)"
else
  secret_len="${#cookie_secret}"
  if [ "${secret_len}" -ne 16 ] && [ "${secret_len}" -ne 24 ] && [ "${secret_len}" -ne 32 ]; then
    echo "Cookie secret must be 16, 24, or 32 bytes (got ${secret_len})." >&2
    echo "Tip: generate with: python3 - <<'PY'" >&2
    echo "import os,base64; print(base64.b64encode(os.urandom(16)).decode())" >&2
    echo "PY" >&2
    exit 1
  fi
fi

read -r -p "Enter Keycloak client secret, you can only get this after you have created the client: " client_secret
if [ -z "${client_secret}" ]; then
  echo "Client secret is required." >&2
  exit 1
fi


# TODO: Apply this manifest instead of storing to file.
cat > "${MANIFEST_FILE}" <<EOF
---
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  client-secret: "${client_secret}"
  cookie-secret: "${cookie_secret}"
EOF

echo "Wrote manifest to ${MANIFEST_FILE}"
echo "cookie secret: ${cookie_secret}"
