# GHCR Auth via Static PAT + SOPS

This cluster authenticates with GitHub Container Registry (`ghcr.io/st-john-software/*`) using a static GitHub PAT stored as a SOPS-encrypted `dockerconfigjson` Secret in Git. Flux's `kustomize-controller` decrypts at reconcile time using an age key held in `flux-system/sops-age`.

We previously used an ESO `GithubAccessToken` generator with a GitHub App PEM (auto-rotating tokens), but the operational complexity wasn't worth it for a homelab — see #535/#536. Mirrors the approach already in use in `production-infra`.

## Architecture

```
GitHub PAT (read:packages)
    └── SOPS-encrypted Secret (apps/ghcr-pull-secret.enc.yaml)
            └── Flux kustomize-controller decrypts via flux-system/sops-age
                    └── ghcr-pull dockerconfigjson Secret in default ns
                            └── Deployment imagePullSecrets → pull from ghcr.io
```

## One-Time Cluster Setup

The age private key must be present in `flux-system/sops-age` before Flux can decrypt anything. To bootstrap:

```bash
# Generate a per-cluster age key (do not reuse production-infra's key)
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/fleet-infra.agekey
chmod 600 ~/.config/sops/age/fleet-infra.agekey

# Apply to the cluster
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=$HOME/.config/sops/age/fleet-infra.agekey

# Back up the keyfile somewhere safe (password manager / 1Password)
# Without it, encrypted secrets in Git are unrecoverable.
```

The age public key is committed in `.sops.yaml` at the repo root and used as the encryption recipient.

## Adding GHCR Auth to a New App

### Apps in the `default` namespace

The shared `ghcr-pull` Secret is created from `apps/ghcr-pull-secret.enc.yaml`. Just add `imagePullSecrets` to your Deployment:

```yaml
spec:
  template:
    spec:
      imagePullSecrets:
        - name: ghcr-pull
```

The Secret's name is `ghcr-pull` — the file is `ghcr-pull-secret.enc.yaml`, but don't copy the filename into `imagePullSecrets`. CI enforces this via `scripts/check-image-pull-secrets.sh`.

### Apps in a different namespace

Kubernetes `imagePullSecrets` are namespaced — the Secret must exist in the same namespace as the Pod. Create a per-namespace SOPS-encrypted Secret in your app directory:

```yaml
# apps/my-app/ghcr-pull-secret.enc.yaml (encrypted with sops)
apiVersion: v1
kind: Secret
type: kubernetes.io/dockerconfigjson
metadata:
  name: ghcr-pull
  namespace: my-namespace
stringData:
  .dockerconfigjson: |
    {"auths":{"ghcr.io":{"auth":"BASE64_OF_USERNAME:PAT"}}}
```

Encrypt with `sops -e -i apps/my-app/ghcr-pull-secret.enc.yaml` before committing. Add it to your app's `kustomization.yaml`:

```yaml
resources:
  - ghcr-pull-secret.enc.yaml
```

> **Note:** the Flux `apps` Kustomization has `decryption` enabled cluster-wide for `./apps`, so any `*.enc.yaml` under that path is automatically decrypted at reconcile time.

## Editing the Encrypted Secret

```bash
# In-place edit (sops opens the decrypted contents in $EDITOR, re-encrypts on save)
sops apps/ghcr-pull-secret.enc.yaml

# Or decrypt to view, then re-encrypt
sops -d apps/ghcr-pull-secret.enc.yaml
sops -e -i apps/ghcr-pull-secret.enc.yaml
```

`sops` finds the age private key automatically if it's at `~/.config/sops/age/keys.txt`, or via `SOPS_AGE_KEY_FILE=$HOME/.config/sops/age/fleet-infra.agekey`.

## PAT Rotation

1. Create a new fine-grained PAT on GitHub with **Read access to packages** scoped to the `St-John-Software` org.
2. Compute the dockerconfigjson auth string: `printf 'USERNAME:PAT' | base64 -w0`.
3. `sops apps/ghcr-pull-secret.enc.yaml` and update the encoded auth.
4. Commit + PR + merge. Flux re-applies the Secret within ~1 minute.
5. Revoke the old PAT in GitHub.

## Dependency Order

Flux reconciles `infrastructure` → `config` → `apps`. The `sops-age` Secret in `flux-system` is created out-of-band (manual `kubectl create`) and must exist before the `apps` Kustomization can decrypt anything. If `sops-age` is missing, the apps Kustomization will fail with a decryption error.

If you ever rebuild the cluster:
1. Restore the age key file from backup.
2. Recreate the `sops-age` Secret as shown in [One-Time Cluster Setup](#one-time-cluster-setup).
3. Push any commit to trigger a fresh reconcile (or force one).
