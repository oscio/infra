#!/usr/bin/env bash
# Pulls the cluster's selfsigned platform root CA out of the
# `cert-manager/platform-root-ca` Secret and adds it to the macOS
# login keychain so https:// + wss:// hosts under
#   *.<domain>     (e.g. console.dev.openschema.io)
#   *.vm.<domain>  (e.g. vm-XXXX-term.vm.dev.openschema.io)
# are trusted by Safari, Chrome, curl, etc.
#
# Why login.keychain-db (not System.keychain): adding to the user
# keychain doesn't require sudo. Trust still applies to every
# browser running as that user, which is what we need on a dev mac.
#
# Usage:
#   ./infra/scripts/trust-platform-ca.sh                     # uses kubectl current-context
#   ./infra/scripts/trust-platform-ca.sh --context=dev       # explicit context
#   ./infra/scripts/trust-platform-ca.sh --context=dev --secret-namespace=cert-manager --secret-name=platform-root-ca
#
# Idempotent — re-running with the same cert is a no-op.
# After install, **fully quit and relaunch your browser** so it
# re-reads the keychain.
set -euo pipefail

CONTEXT=""
NAMESPACE="cert-manager"
SECRET="platform-root-ca"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

for arg in "$@"; do
  case "$arg" in
    --context=*)          CONTEXT="${arg#*=}" ;;
    --secret-namespace=*) NAMESPACE="${arg#*=}" ;;
    --secret-name=*)      SECRET="${arg#*=}" ;;
    -h|--help)
      sed -n '2,/^set -euo pipefail/p' "$0" | sed -n '/^#/p' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown arg: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script targets macOS — login.keychain-db is mac-specific." >&2
  exit 1
fi

if ! command -v kubectl >/dev/null; then
  echo "kubectl not found in PATH" >&2
  exit 1
fi

CTX_FLAG=()
if [[ -n "$CONTEXT" ]]; then
  CTX_FLAG=(--context="$CONTEXT")
fi

CRT_FILE="$(mktemp -t platform-root-ca).crt"
trap 'rm -f "$CRT_FILE"' EXIT

echo "==> Reading $NAMESPACE/$SECRET ${CONTEXT:+from context $CONTEXT}"
kubectl "${CTX_FLAG[@]}" get secret "$SECRET" -n "$NAMESPACE" \
  -o jsonpath='{.data.tls\.crt}' \
  | base64 -d > "$CRT_FILE"

if [[ ! -s "$CRT_FILE" ]]; then
  echo "Empty cert — wrong namespace/secret?" >&2
  exit 1
fi

CN=$(openssl x509 -in "$CRT_FILE" -noout -subject 2>/dev/null \
       | sed -E 's/.*CN[= ]+([^,/]+).*/\1/' || true)
echo "    subject: ${CN:-<unknown>}"

echo "==> Adding to $KEYCHAIN as a trusted SSL root"
# -r trustRoot: the cert IS the anchor. -k: target keychain.
# Re-adding the same cert succeeds silently (no-op).
security add-trusted-cert -r trustRoot -k "$KEYCHAIN" "$CRT_FILE"

echo "==> Verifying"
if security verify-cert -c "$CRT_FILE" -p ssl >/dev/null 2>&1; then
  echo "    ✓ verification successful"
else
  echo "    ✗ verify-cert failed — Safari/Chrome may not pick this up" >&2
  exit 1
fi

cat <<MSG

Done. Quit and relaunch your browser so it re-reads the keychain.
Then https:// AND wss:// hosts under the platform's wildcards (e.g.
'*.<domain>', '*.vm.<domain>') will be trusted without manual
'Show Details → visit website' prompts.
MSG
