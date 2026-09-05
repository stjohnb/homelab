# Job container image for the in-cluster Forgejo Actions runner.
#
# act_runner supplies no node to job containers, so JS actions (actions/checkout)
# need node from the image; every ported perudo workflow step runs `nix develop`,
# so nix must be baked in too (installing it at job time was rejected in
# St-John-Software/perudo#211). Referenced from apps/forgejo-runner/config.yaml.
FROM docker.io/nixos/nix:2.35.2 AS nix

FROM data.forgejo.org/oci/node:22-bookworm

LABEL org.opencontainers.image.source=https://github.com/St-John-Software/fleet-infra
LABEL org.opencontainers.image.description="Forgejo Actions job image: node 22, git, bash, nix"

# The nix store, its SQLite database and the default profile all live under
# /nix, so copying that one tree is a complete single-user nix installation.
COPY --from=nix /nix /nix

# nix must reach PATH via ENV, not a profile script: act_runner runs `run:`
# steps with a NON-login bash, so /etc/profile.d is never sourced. Appended
# (not prepended) so git/bash/coreutils still come from Debian — the nixos/nix
# default profile also carries those. perudo's setup-nix additionally probes
# /nix/var/nix/profiles/default/bin/nix directly, which this satisfies.
ENV PATH="${PATH}:/nix/var/nix/profiles/default/bin"
ENV NIX_SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENV USER=root
ENV HOME=/root

# Single-user nix in an unprivileged container:
#   build-users-group empty -> builds run as root, no nixbld users needed
#   sandbox off             -> no CAP_SYS_ADMIN (container.privileged: false)
#   flakes on               -> workflows still pass --extra-experimental-features
RUN mkdir -p /etc/nix && printf '%s\n' \
      'build-users-group =' \
      'sandbox = false' \
      'experimental-features = nix-command flakes' \
      'max-jobs = auto' \
      > /etc/nix/nix.conf

RUN nix --version && node --version && git --version && bash --version | head -1
