# Agent notes

**Reference.** Read this when debugging manually on the shared automation host and need a verified host/kubeconfig/CI gotcha. Not for subsystem architecture — see [OVERVIEW.md](OVERVIEW.md) for the doc map.

Durable, high-signal operator facts refined from past agent memory stores and re-verified against the current repo or host environment.

## Shared Claws host kubeconfig mapping

On the shared Claws automation host, the default `kubectl` context for this repo is the homelab cluster managed by `fleet-infra`: `kubectl config current-context` is `default`, the active API server is `https://192.168.0.251:6443`, and `kubectl get gitrepository -n flux-system` reports `ssh://git@github.com/St-John-Software/fleet-infra`. A separate `~/.claws/prod-kubeconfig.yaml` also exists for the sibling `production-infra` cluster.

Why this matters: both clusters expose similarly named resources and secrets, so a manual debug read against the wrong kubeconfig can look plausible while returning the wrong state. Before any out-of-band inspection, verify the target with `kubectl get gitrepository -n flux-system`.

## SOPS age key: use the fleet-infra-specific keyfile, not the default

On the shared Claws automation host, `sops`/`age` operations against this repo's `*.enc.yaml` files must set `SOPS_AGE_KEY_FILE=~/.config/sops/age/fleet-infra.agekey` explicitly (see [ghcr-auth.md](ghcr-auth.md)). The host's default `~/.config/sops/age/keys.txt` decrypts the *sibling* `production-infra` cluster's secrets, not this repo's — using it against a fleet-infra `.enc.yaml` fails with a generic "no identity matched any of the recipients" error, not a helpful "wrong repo/wrong key" message. `.sops.yaml`'s recipient (`age17tuhxkp7ma9xfzpsan63c94qdn4c48v6f0z5uak7updragn8ep9q0y3xfz`) only matches the fleet-infra-specific keyfile.

## SSH aliases on the automation host mirror `nixos-config`, not this repo

`~/.ssh/config` host aliases on the shared Claws host (`nas`/`k3s-nas`, `ryzen`, `k3s`, `proxmox`, `homeassistant`, etc.) are hand-synced to mirror the sibling `St-John-Software/nixos-config` repo's `home/common.nix` (`programs.ssh.settings`) — nothing in fleet-infra declares them. If an alias fails to connect ("no route to host" or similar), diff the local `~/.ssh/config` against that file before assuming the underlying box is down; there is no `truenas` host anymore (see [nas-k3s.md](nas-k3s.md) for the 2026-07-27 NixOS migration).
