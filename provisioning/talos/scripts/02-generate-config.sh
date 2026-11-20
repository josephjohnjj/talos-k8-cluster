#!/bin/sh
set -eu

: "${CLUSTER_NAME:=k8-talos-cluster}"
: "${KUBERNETES_ENDPOINT:?Set KUBERNETES_ENDPOINT to https://<dns-name>:6443}"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TALOS_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)
GENERATED_DIR="$TALOS_DIR/generated"

if [ -e "$GENERATED_DIR" ]; then
  echo "Refusing to overwrite $GENERATED_DIR; move it aside or remove it deliberately." >&2
  exit 1
fi

client_version=$(talosctl version --client)
if ! printf '%s\n' "$client_version" | grep -Eq '^[[:space:]]*Tag:[[:space:]]*v1\.14\.5[[:space:]]*$'; then
  echo "Script 02 requires talosctl v1.14.5." >&2
  exit 1
fi

umask 077
mkdir "$GENERATED_DIR"
talosctl gen config "$CLUSTER_NAME" "$KUBERNETES_ENDPOINT" \
  --output-dir "$GENERATED_DIR" \
  --with-docs=false \
  --with-examples=false \
  --install-disk /dev/xvda \
  --config-patch "@$TALOS_DIR/patches/cluster.yaml" \
  --config-patch-control-plane "@$TALOS_DIR/patches/controlplane.yaml"
talosctl machineconfig patch "$GENERATED_DIR/worker.yaml" \
  --patch "@$TALOS_DIR/patches/ingress.yaml" \
  --output "$GENERATED_DIR/ingress.yaml"

echo "Generated Talos configuration in $GENERATED_DIR. Keep it secret."
