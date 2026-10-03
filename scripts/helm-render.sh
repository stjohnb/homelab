#!/usr/bin/env bash
# Render every HelmRelease in a manifest tree with `helm template`, at the
# release's pinned chart version, from its pinned HelmRepository URL, with the
# release's own `values:`.
#
# Why: every other check in this repo (kustomize-validate, kubeconform,
# security-scan, kustomize-diff) only ever sees the HelmRelease *object* — a
# blob of `values:`. The Pods, DaemonSets, ClusterRoles, PriorityClasses and
# retention policies that Flux's helm-controller actually creates from the
# chart are invisible to all of them, so chart defaults land unreviewed unless
# a human downloads the chart tarball by hand (#1491).
#
# Usage: ./scripts/helm-render.sh <manifest-root> <output-dir>
#
#   <manifest-root>  directory holding apps/ and clusters/ — "." for the
#                    working tree, or a git worktree path so the PR's copy of
#                    this script can render the BASE branch's manifests.
#   <output-dir>     created if missing, emptied if it exists; receives one
#                    <namespace>-<release>.yaml per HelmRelease.
#
# Requires: helm, yq (mikefarah), jq — all in flake.nix's `default` devShell.
# Needs network: fetches each chart from its upstream repository. Each
# `helm template` call is retried up to HELM_RETRIES times with backoff to
# absorb a transient upstream stall (e.g. a hung index.yaml fetch).
#
# Set HELM_RENDER_HOME to reuse a chart cache across invocations; by default
# each run gets a private throwaway home so concurrent jobs on the shared
# self-hosted runners never race over ~/.cache/helm.
set -uo pipefail

# The live cluster's version, so capability-gated templates
# (`.Capabilities.KubeVersion`) render what helm-controller would produce.
KUBE_VERSION="1.34.3"

# CRDs installed by other releases. Charts gate ServiceMonitor/PrometheusRule/
# Certificate/IngressRoute templates on `.Capabilities.APIVersions.Has`, which
# `helm template` leaves empty unless told otherwise — without these the
# monitoring objects silently vanish from the rendering.
API_VERSIONS=(
  "monitoring.coreos.com/v1"
  "cert-manager.io/v1"
  "traefik.io/v1alpha1"
)

# `helm template --repo` re-fetches the repository's index.yaml and the chart
# tarball on every call and has no retry of its own; a hung upstream fetch
# (charts.jetstack.io, 2026-09-23) otherwise fails the whole render.
HELM_RETRIES=3
HELM_RETRY_DELAYS=(10 20)

# Field separator for the yq→jq→bash handoff. ASCII unit separator, not tab:
# tab is IFS *whitespace*, so bash would collapse runs of them and silently
# shift an empty field's value into the next variable.
US=$'\x1f'

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <manifest-root> <output-dir>" >&2
  exit 2
fi

ROOT="$1"
OUT_DIR="$2"

if [ ! -d "$ROOT" ]; then
  echo "❌ manifest root not found: $ROOT" >&2
  exit 1
fi

for tool in helm yq jq; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "❌ $tool not found. Enter the devShell: nix develop" >&2
    exit 1
  fi
done

# Private helm home unless the caller supplied one. `helm template --repo`
# writes the fetched repository index and chart tarball under it.
if [ -n "${HELM_RENDER_HOME:-}" ]; then
  HELM_HOME="$HELM_RENDER_HOME"
  mkdir -p "$HELM_HOME" || exit 1
else
  HELM_HOME="$(mktemp -d)" || exit 1
  trap 'rm -rf "$HELM_HOME"' EXIT
fi
export HELM_CACHE_HOME="$HELM_HOME/cache"
export HELM_CONFIG_HOME="$HELM_HOME/config"
export HELM_DATA_HOME="$HELM_HOME/data"
mkdir -p "$HELM_CACHE_HOME" "$HELM_CONFIG_HOME" "$HELM_DATA_HOME" || exit 1

# Start from an empty output directory so a release deleted from the manifests
# disappears from the diff instead of lingering from a previous run.
case "$OUT_DIR" in
  "" | "/" | ".")
    echo "❌ refusing to clear output directory '$OUT_DIR'" >&2
    exit 2
    ;;
esac
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR" || exit 1

# Candidate files: grep first (cheap) so yq only parses files that could match.
# gotk-components.yaml is excluded because it is the Flux CRD bundle —
# thousands of documents, not one of them an actual HelmRelease or
# HelmRepository, and parsing it costs seconds for nothing. `sort` keeps the
# rendering order deterministic so the base/PR diff stays stable.
candidate_files() {
  local kind="$1" dir
  for dir in apps clusters; do
    [ -d "$ROOT/$dir" ] || continue
    grep -rl "kind: $kind" "$ROOT/$dir" --include='*.yaml' --include='*.yml' 2>/dev/null
  done | grep -v '/flux-system/gotk-components.yaml$' | sort -u
}

# Emit one compact JSON line per document of the requested kind. Selecting on
# `.kind` rather than on the filename is what keeps notifications.yaml and
# infrastructure-kustomization.yaml — which merely *mention* HelmRelease in an
# Alert eventSource and a Kustomization healthCheck — out of the results.
docs_of_kind() {
  local file="$1" kind="$2"
  yq -N -o=json -I=0 "select(.kind == \"$kind\")" "$file"
}

# --- Repository map: "<namespace>/<name>" -> url, type -----------------------
declare -A REPO_URL
declare -A REPO_TYPE
# Counted separately: under `set -u`, bash errors on ${#assoc[@]} for an
# associative array that has never been assigned to.
REPO_COUNT=0

while IFS= read -r file; do
  [ -n "$file" ] || continue
  while IFS="$US" read -r ns name url type; do
    [ -n "$name" ] || continue
    if [ -z "$url" ]; then
      echo "❌ HelmRepository ${ns}/${name} in $file has no spec.url" >&2
      exit 1
    fi
    REPO_URL["${ns}/${name}"]="$url"
    REPO_TYPE["${ns}/${name}"]="$type"
    REPO_COUNT=$((REPO_COUNT + 1))
  done < <(docs_of_kind "$file" HelmRepository | jq -r '
    [
      (.metadata.namespace // "default"),
      (.metadata.name // ""),
      (.spec.url // ""),
      (.spec.type // "default")
    ] | join("\u001f")')
done < <(candidate_files HelmRepository)

echo "Discovered $REPO_COUNT HelmRepository sources under $ROOT"

# --- Render each HelmRelease -------------------------------------------------
RENDERED=0

while IFS= read -r file; do
  [ -n "$file" ] || continue

  # Path relative to the manifest root, so the `# Source:` header of a
  # base-branch rendering matches the PR's and never shows up as a diff hunk.
  rel="${file#"$ROOT"/}"
  rel="${rel#./}"

  while IFS= read -r hr_json; do
    [ -n "$hr_json" ] || continue

    IFS="$US" read -r release namespace chart version src_name src_ns \
      < <(jq -r '
        [
          (.spec.releaseName // .metadata.name // ""),
          (.spec.targetNamespace // .metadata.namespace // "default"),
          (.spec.chart.spec.chart // ""),
          (.spec.chart.spec.version // ""),
          (.spec.chart.spec.sourceRef.name // ""),
          (.spec.chart.spec.sourceRef.namespace // .metadata.namespace // "default")
        ] | join("\u001f")' <<< "$hr_json")

    # Fail loudly instead of skipping. A release this script cannot render is a
    # release whose chart defaults stay unreviewed — exactly the gap the script
    # exists to close. `spec.chartRef` (OCI/chart-object references) is unused
    # today and would land here.
    if [ -z "$release" ]; then
      echo "❌ $rel: a HelmRelease document has neither spec.releaseName nor metadata.name" >&2
      exit 1
    fi
    if [ -z "$chart" ]; then
      echo "❌ $rel: release '$release' has no spec.chart.spec.chart — spec.chartRef is not supported by this renderer" >&2
      exit 1
    fi
    if [ -z "$version" ]; then
      echo "❌ $rel: release '$release' has no spec.chart.spec.version — every chart must be pinned" >&2
      exit 1
    fi

    src_key="${src_ns}/${src_name}"
    if [ -z "${REPO_URL[$src_key]+set}" ]; then
      echo "❌ $rel: release '$release' references sourceRef '$src_key', which matches no HelmRepository under $ROOT" >&2
      exit 1
    fi
    url="${REPO_URL[$src_key]}"

    # JSON is valid YAML, so helm reads this as a values file unchanged.
    values_file="$HELM_HOME/values-${namespace}-${release}.json"
    if ! jq '.spec.values // {}' <<< "$hr_json" > "$values_file"; then
      echo "❌ $rel: release '$release' — could not extract spec.values" >&2
      exit 1
    fi

    out_file="$OUT_DIR/${namespace}-${release}.yaml"
    if [ -e "$out_file" ]; then
      echo "❌ $rel: two HelmReleases both render to ${namespace}-${release}.yaml" >&2
      exit 1
    fi

    # An `oci://` HelmRepository is addressed as a chart reference, not through
    # --repo. None are in use today; handled so that adding one cannot silently
    # render the wrong thing.
    helm_args=(template "$release")
    if [ "${REPO_TYPE[$src_key]}" = "oci" ]; then
      helm_args+=("${url%/}/${chart}")
    else
      helm_args+=("$chart" --repo "$url")
    fi
    helm_args+=(
      --version "$version"
      --namespace "$namespace"
      --values "$values_file"
      --kube-version "$KUBE_VERSION"
      --skip-tests
    )
    for api in "${API_VERSIONS[@]}"; do
      helm_args+=(--api-versions "$api")
    done
    # No --include-crds: cert-manager's and kube-prometheus-stack's CRDs run to
    # tens of thousands of lines and would drown the reviewable signal. Flux
    # installs them separately via `install.crds: CreateReplace`.

    echo "Rendering $rel → ${namespace}/${release} (${chart} ${version})"
    attempt=1
    succeeded=0
    while [ "$attempt" -le "$HELM_RETRIES" ]; do
      if helm "${helm_args[@]}" > "$out_file.tmp" 2> "$out_file.err"; then
        succeeded=1
        break
      fi
      cat "$out_file.err" >&2
      if [ "$attempt" -lt "$HELM_RETRIES" ]; then
        delay="${HELM_RETRY_DELAYS[$((attempt - 1))]}"
        echo "⚠️ helm template attempt ${attempt}/${HELM_RETRIES} failed for ${namespace}/${release}; retrying in ${delay}s" >&2
        sleep "$delay"
      fi
      attempt=$((attempt + 1))
    done
    if [ "$succeeded" -ne 1 ]; then
      echo "❌ helm template failed for ${namespace}/${release} ($chart $version from $url)" >&2
      exit 1
    fi

    {
      echo "--- # Source: ${rel}"
      cat "$out_file.tmp"
    } > "$out_file"
    rm -f "$out_file.tmp" "$out_file.err"

    RENDERED=$((RENDERED + 1))
  done < <(docs_of_kind "$file" HelmRelease)
done < <(candidate_files HelmRelease)

echo ""
echo "Rendered $RENDERED HelmReleases into $OUT_DIR"

# A discovery expression that matches nothing must not look like a clean run —
# the same guard as check-kubesec.sh's EXPECTED check.
if [ "$RENDERED" -eq 0 ]; then
  echo "❌ No HelmReleases matched — the discovery expression is broken, not the manifests" >&2
  exit 1
fi
