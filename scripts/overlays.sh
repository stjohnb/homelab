#!/usr/bin/env bash
# Single source of truth for the kustomize overlays that repo-wide checks
# enumerate. Each line is "<overlay-path>:<effective-default-namespace>".
#
# The namespace is the targetNamespace set by the overlay's Flux
# Kustomization under clusters/my-cluster/ — apps and migrations get
# `default`; infrastructure and config set no targetNamespace, so their
# field is empty. Consumers that only need paths take "${entry%%:*}".
#
# Overlays are discovered nowhere else: if you add a Flux Kustomization
# layer, add it here and every check picks it up.
#
# Usage: ./scripts/overlays.sh
set -uo pipefail

cat <<'EOF'
apps:default
migrations:default
clusters/my-cluster/infrastructure:
clusters/my-cluster/config:
EOF
