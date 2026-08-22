# CI/dev environment for fleet-infra.
#
# The org's CI runs on self-hosted NixOS runners (`ryzen`, `beefy-actions`),
# and the runners deliberately provide almost nothing beyond `nix`, `git` and
# docker. Every tool a workflow shells out to comes from THIS file, entered
# via `nix develop` — that is what keeps repos with conflicting toolchains
# able to share the same runner machines: each repo's dependencies live in
# the nix store keyed by hash, isolated by construction, instead of being
# installed globally on the runner.
#
# So: if CI needs a new tool, add it to the matching devShell below. Never
# `sudo apt-get install` (NixOS runners have no apt or sudo), never a
# curl-a-binary installer (prebuilt tarballs hardcode /lib64/ld-linux and
# only work on NixOS through the nix-ld shim), never ask for the tool to be
# added to the runner's own package set.
{
  description = "fleet-infra — dev and CI toolchain";

  # nixpkgs-unstable: the same channel the runner hosts are built from.
  # The pin here is independent — flake.lock in this repo decides what CI
  # actually gets, and bumping it is this repo's own decision.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems
        (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        # Everything ci.yml needs. mkShell's stdenv already puts coreutils,
        # grep, sed, awk, find/xargs and diffutils on PATH — those cover the
        # plain-bash check scripts (check-trivyignore.sh,
        # check-image-tag-consistency.sh) and the GNU `date -d` calls.
        default = pkgs.mkShell {
          packages = with pkgs; [
            yamllint # yaml-lint job
            kustomize # kustomize-validate / kubeconform / diff / verify jobs
            fluxcd # was fluxcd/flux2/action; kept for parity with old CI
            kubeconform # kubeconform job
            kubesec # security-scan job
            trivy # image-scan job
            gitleaks # secret-detection job
            jq # security-scan, kustomize-diff jobs
            curl # Flux CRD schema download
            crane # image-verify job (go-containerregistry)
            nodejs_22 # renovate-check job (npx renovate-config-validator)
            # mikefarah/yq — the Go one the check scripts require. The nixpkgs
            # attr `yq` is the python kislyuk wrapper with a DIFFERENT
            # expression language; the scripts silently misbehave under it.
            yq-go
            # kubeconform job strips the top-level `sops:` field from
            # SOPS-encrypted Secrets with a python one-liner before validating.
            (python3.withPackages (ps: [ ps.pyyaml ]))
          ];
        };

        # Small shell for the maintenance/notification workflows that only
        # talk to the GitHub API: notify-failures.yml,
        # cleanup-actions-storage.yml, and the tag-computation step of
        # build-arpwatch.yml / the bump steps of update-bin-scraper.yml,
        # and the comment-posting step of ci.yml's kustomize-diff job.
        # Separate from `default` so those jobs don't pay for the scanner
        # toolchain closure.
        scripts = pkgs.mkShell {
          packages = with pkgs; [
            gh
          ];
        };
      });
    };
}
