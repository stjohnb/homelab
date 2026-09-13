# UniFi Network (tofu-controller)

**Depth:** **Reference**
**Read this when:** changing the home network's UniFi configuration: networks, SSIDs, or zone-based firewall policies.
**Read instead:** [infrastructure-overview.md](infrastructure-overview.md) for the Flux layer that installs tofu-controller.

The home network used to be one flat `192.168.0.0/24` configured by clicking around the UniFi console at `192.168.0.1`. It is the last thing in the estate that was not git-backed. This subsystem puts it under OpenTofu, run in-cluster by [tofu-controller](https://github.com/flux-iac/tofu-controller) and reconciled by Flux, with the first managed resource set being an isolated IoT VLAN (#1188).

## Current state: plan-only

`clusters/my-cluster/tofu/terraform-unifi.yaml` sets `planOnly: true`. **Nothing is written to the console yet.** The controller clones the repo, runs `tofu plan`, and stops. Flipping to apply is a separate, deliberate PR — see [Going from plan to apply](#going-from-plan-to-apply).

## Layout

| Path | What it is |
|---|---|
| `clusters/my-cluster/infrastructure/tofu-controller/` | `HelmRepository` + `HelmRelease` installing the controller into `flux-system`. Chart pinned to an exact version. |
| `clusters/my-cluster/tofu-kustomization.yaml` | The `tofu` Flux Kustomization — a fourth reconciliation layer, `dependsOn: infrastructure`, `wait: false`. |
| `clusters/my-cluster/tofu/terraform-unifi.yaml` | The `Terraform` CR (`infra.contrib.fluxcd.io/v1alpha2`) pointing at `./tofu/unifi`. |
| `clusters/my-cluster/tofu/networkpolicy.yaml` | Egress restrictions on the runner pod. |
| `clusters/my-cluster/tofu/provider-mirror.yaml` | PVC + one-shot Job that populates the offline provider mirror, plus the mirror-only `tofu.tfrc` ConfigMap. |
| `tofu/unifi/*.tf` | The OpenTofu configuration itself. |
| `tofu/unifi/.terraform.lock.hcl` | Committed provider lockfile. |
| `tfplan-default-unifi` (ConfigMap, `flux-system`) | Not in git. Written by the controller because the CR sets `storeReadablePlan: human`; owned by the `Terraform` CR. Key `tfplan`. |

### Why a fourth Flux layer

The CR could not go anywhere that already exists:

- Not `config/` — that Kustomization is `wait: true`, and a **plan-only** `Terraform` CR never reports `Ready=True`. It would stall `config` and therefore `apps`.
- Not `infrastructure/` — the `Terraform` CRD does not exist on the first reconcile, so the whole layer would fail to apply.

So `tofu` is its own layer with `wait: false` and `retryInterval: 1m`. On the very first reconcile after merge it can fail once with `no matches for kind "Terraform"` until the Helm install lands the CRD, then self-heals within a minute. **That single transient Slack alert is expected.**

The CR lives in `flux-system` because the chart only provisions the `tf-runner` ServiceAccount and RBAC in `runner.allowedNamespaces`, and the runner pod (`unifi-tf-runner`) is created in the same namespace as the CR. The runner is pinned to the `k3s` node — `ryzen` and `k3s-nas` are powered off most of the day, and the console is only reachable while the runner is actually scheduled.

State lives in the Secret `tfstate-default-unifi` in `flux-system`. `spec.backendConfig` is deliberately omitted; there are no local state files anywhere.

## The house rule

**Once a resource is managed here, the UniFi UI is read-only for it.** A hand edit in the console shows up as drift and is reverted on the next reconcile. If you want a change to a managed network, SSID or policy, change the `.tf` file and open a PR. This is the whole point of the subsystem — treat the console like `kubectl edit` on a Flux-managed Deployment.

The corollary: **do not import the existing console wholesale.** We own only what we create. The pre-existing default LAN and the built-in `Internal`/`External`/`Gateway` zones are referenced through data sources in `tofu/unifi/data.tf`, so nothing that was already there is managed or at risk from a plan. Selective `import` blocks for specific resources are allowed later; a bulk import never is.

## The IoT network

The first managed resource set. Everything below is created by `tofu/unifi/`:

| Resource | Detail |
|---|---|
| `unifi_network.iot` | `IoT`, VLAN 20, `192.168.20.0/24`, DHCP `.100`–`.254`, 1-day lease. `purpose = "corporate"`, **not** `guest` — a guest network adds a captive portal and client isolation, which would stop devices reaching Home Assistant. |
| `unifi_wlan.iot` | SSID `IoT` on that network. WPA2-PSK (`wpapsk`, `wpa3_support = false`), 2.4 GHz only, no L2 isolation. |
| `unifi_firewall_zone.iot` | A new `IoT` zone containing only the new network. |
| 7 × `unifi_firewall_zone_policy` | The policy set below. |
| 2 × `unifi_firewall_zone_policy_order` | Deterministic evaluation order for the two zone pairs that have more than one custom policy. |

Policies:

| Policy | Action | Source → destination |
|---|---|---|
| `iot_to_internet` | ALLOW | IoT → External |
| `iot_to_gateway_dns` | ALLOW | IoT → Gateway, tcp/udp 53 |
| `iot_to_gateway_dhcp` | ALLOW | IoT → Gateway, udp 67 |
| `iot_to_gateway_block` | BLOCK | IoT → Gateway (everything else, console UI included) |
| `iot_to_ha_mqtt` | ALLOW | IoT → Internal, tcp 1883 to `192.168.0.89` only |
| `iot_to_lan_block` | BLOCK | IoT → Internal (catch-all) |
| `lan_to_iot` | ALLOW | Internal → IoT |

Every ALLOW sets `auto_allow_return_traffic = true`, which is how established and related return traffic gets back.

Ordering is load-bearing: the MQTT hole must be evaluated before the IoT → LAN catch-all block, and the two gateway allows before the gateway block. `index` on a zone policy is controller-assigned and read-only, so `unifi_firewall_zone_policy_order` is the only supported way to assert it. Both order resources use `before_predefined_ids`, putting our custom policies ahead of the controller's built-ins for their zone pair. The resource is flagged experimental upstream and needs UniFi OS 9.0.0 with the zone-based firewall migrated — the same requirement the zone policies themselves carry. Confirm it behaves as expected in the first plan.

There is deliberately **no mDNS reflector**. Cast/HomeKit discovery from the trusted side into IoT is off by default; enable `multicast_dns` on the network only if it turns out to be wanted.

Home Assistant (`192.168.0.89`), the NAS (`192.168.0.128`), `ryzen` (`192.168.0.69`), `dashpi` and `astropi` all stay on the trusted LAN. Their `192.168.0.x` addresses are literals across this repo and `home-assistant-config`. Moving devices onto the new SSID and updating their static `Endpoints` (`apps/awtrix/endpoints.yaml`) and Gatus checks is a follow-up, once the new addresses are known.

## Supply-chain posture

The thing this subsystem writes to is the network every other thing in the house depends on, so the chain from a dependency bump to a live change is deliberately slow and reviewable.

- **Provider pinned exactly**: `filipowm/unifi` `1.1.0` in `tofu/unifi/versions.tf` — not a range. It is the only actively maintained fork of the archived `paultyng/unifi` provider that supports zone-based firewall resources and API-key auth. `ubiquiti-community/unifi` is alive but its firewall resource still targets the legacy rule API and cannot write policies on a modern console; the official-API providers (`murasame29`, BadgerOps) are pre-release.
- **Controller chart pinned exactly**: `tofu-controller` `0.16.5`.
- **`.terraform.lock.hcl` is committed**, so a provider bump is a reviewable diff of hashes. Renovate bumps the version constraint only — regenerate the lockfile in the same PR with `tofu -chdir=tofu/unifi providers lock -platform=linux_amd64`, or the `tofu-validate` CI job fails on a hash mismatch. That failure is the intended review gate, not a bug.
- **14-day soak**: `renovate.json` gives this provider a `minimumReleaseAge` of 14 days, well above the repo-wide 3 days.
- **CI validates offline**: the `tofu-validate` job runs `fmt -check`, `init -backend=false` and `validate` inside the repo's own devShell (`opentofu` comes from `flake.nix`). `task tofu-validate` runs the same thing locally, and `task validate` includes it.
- **The runner cannot phone home at all**: it has no public egress and resolves providers from an offline filesystem mirror — see [The runner has no internet egress](#the-runner-has-no-internet-egress). A provider bump is therefore four edits in one PR: `tofu/unifi/versions.tf`, `tofu/unifi/.terraform.lock.hcl`, the mirror Job's name suffix, and its `PROVIDER_VERSION` env var. `scripts/check-tofu-provider-mirror.sh` fails if any of the four drift, and also fails if a `0.0.0.0/0` egress rule ever reappears in the NetworkPolicy; it runs from `task tofu-validate` and from the `tofu-validate` CI job. The Job's `tf-runner` image tag must track the controller chart version (the same script enforces it) — Renovate does not manage it, because its `kubernetes` fileMatch covers `apps/` only.

### The runner has no internet egress

`clusters/my-cluster/tofu/networkpolicy.yaml` restricts the runner pod's egress to four destinations:

| Allowed | Why |
|---|---|
| `kube-dns`, udp/tcp 53 | name resolution |
| `192.168.0.1:443` | the UniFi console |
| `10.43.0.1` and `192.168.0.251`, 443/6443 | the Kubernetes API, where the state Secret lives. Both addresses, because kube-router evaluates either depending on the path. |
| `source-controller:9090` | the runner pulls the Git artifact tarball from it |

There is deliberately **no public-internet rule** (#1247). `tofu init` resolves providers only through `/opt/opentofu/plugins`, a read-only PVC mount selected by `/etc/opentofu/tofu.tfrc` — a `provider_installation` block containing a `filesystem_mirror` and, deliberately, no `direct` block. Omitting `direct` is what makes `registry.opentofu.org` unreachable by construction; the NetworkPolicy makes it unreachable by network. The runner therefore cannot phone home at all: even a malicious provider release that survived the lockfile gate has nowhere to send the API key or the console config.

The mirror itself is filled by the `tofu-provider-mirror-<version>` Job in `clusters/my-cluster/tofu/provider-mirror.yaml`. That Job carries the label `app.kubernetes.io/name: tofu-provider-mirror`, so it is **not** selected by this policy and still reaches `registry.opentofu.org` — it is the only pod in the subsystem that does. It runs the same upstream `ghcr.io/flux-iac/tf-runner` image the controller runs the runner with, so the mirror is written by the same `tofu`.

The policy is **egress-only**. Never add an `Ingress` section: the controller dials the runner over gRPC on port 30000, and an ingress policy would cut that off.

### Provider mirror troubleshooting

- **`doesn't match any of the checksums`** in the runner log means `.terraform.lock.hcl` is missing a `linux_amd64` `h1:` entry for the pinned version — mirror installs verify against `h1:` hashes, not `zh:`. Regenerate with `tofu -chdir=tofu/unifi providers lock -platform=linux_amd64`. **Never** add a `direct` block to `tofu.tfrc` to work around it; that re-opens the hole this design closes.
- **Provider not found on the first reconcile after merge**: the runner can start before the mirror Job finishes. That reconcile's plan fails; the next one succeeds (30m, or `flux reconcile kustomization tofu`). Not a manual step.
- The Job is **immutable**. Any edit to its pod template — a `resources` tweak included — needs a new `metadata.name`, or Flux's apply fails with `field is immutable` and the `tofu` Kustomization goes NotReady.

## Credentials

The runner takes its console credentials from the environment, supplied by the Secret `unifi-tofu-credentials` in `flux-system` (`envFrom` in the CR). Either `UNIFI_USERNAME` + `UNIFI_PASSWORD` (what is in use today) or `UNIFI_API_KEY` works — the provider accepts both. They belong to a **dedicated local admin** on the console, never a personal account.

The IoT passphrase is *not* an env var. It reaches OpenTofu through `spec.varsFrom` on the `Terraform` CR, from the key `iot_wifi_passphrase`.

> **No key in this Secret may start with `TF_VAR_`.** `envFrom` injects every key into the runner pod, and terraform-exec aborts `init` on sight of any `TF_VAR_*` variable: `error setting env for Terraform: ... manual setting of env var "TF_VAR_iot_wifi_passphrase" detected`. Variables go through `varsFrom`, credentials go through `envFrom`.

The Secret is created imperatively — nothing here is committed in plaintext:

```bash
kubectl delete secret unifi-tofu-credentials -n flux-system --ignore-not-found
kubectl create secret generic unifi-tofu-credentials -n flux-system \
  --from-literal=UNIFI_USERNAME='<local-admin>' \
  --from-literal=UNIFI_PASSWORD='<password>' \
  --from-literal=iot_wifi_passphrase='<passphrase>'
```

A missing `iot_wifi_passphrase` key does **not** fail: `varsFrom` turns an absent key into an empty string. The `validation` block on the variable in `tofu/unifi/variables.tf` is what catches it, with `iot_wifi_passphrase must be 8-63 characters`.

Until the Secret exists the runner pod fails to start and the `Terraform` CR sits NotReady. Nothing alerts on `Terraform` CRs and the `tofu` layer is `wait: false`, so that is harmless. Converting this to a SOPS-encrypted `*.enc.yaml` alongside the rest of the repo's secrets is worthwhile later cleanup.

This fail-closed behavior is deliberate, not a bug to paper over: the owner explicitly rejected making `secretRef` optional (#1269) — failing closed without credentials is the intended behaviour, especially once the CR moves off `planOnly` to auto-apply, where silently skipping credentials could apply an incomplete plan. Do not make `secretRef` optional to avoid the NotReady state.

## Manual steps for a human

These cannot be automated and must happen before the configuration is applied:

1. **Confirm the console is on Network 9.x or later with the zone-based firewall migrated.** The provider's zone resources require it. See [Ubiquiti's migration guide](https://help.ui.com/hc/en-us/articles/28223082254743-Migrating-to-Zone-Based-Firewalls-in-UniFi).
2. **Create the dedicated local admin and its credentials**, then run the `kubectl create secret` above. Mind the `TF_VAR_` prohibition in that section.
3. **Confirm #1187 has produced at least one console backup on the NAS.** Nothing gets applied before a restorable backup exists.
4. **Read and approve the first plan** (below).

## Going from plan to apply

```bash
flux get terraforms

# The plan itself. `spec.storeReadablePlan: human` on the CR makes the
# controller write the `tofu show` output here; `describe terraform unifi`
# only shows the status message, not the plan.
kubectl -n flux-system get configmap tfplan-default-unifi -o jsonpath='{.data.tfplan}'

# If the CR never got as far as producing a plan:
kubectl -n flux-system describe terraform unifi
kubectl -n flux-system logs -l app.kubernetes.io/name=tf-runner --tail=200
```

The ConfigMap appears only once a plan has actually been produced, and is replaced wholesale on each new plan. A plan over 1 MiB is split into `tfplan-default-unifi-0`, `-1`, … — not expected for this resource set.

The IoT passphrase renders as `(sensitive value)`: the variable is `sensitive = true` and the provider marks `unifi_wlan.passphrase` sensitive too. It must never appear in this ConfigMap, in the CR status, or in the runner logs — if it does, stop and treat it as a leak.

Read the plan and check it creates **exactly** the resources listed under [The IoT network](#the-iot-network) and touches nothing else.

> **A plan that shows a change to anything other than the new resources means stop.** Do not approve it; work out what the configuration is claiming ownership of first.

The most likely first-plan failure is a **data-source name mismatch** — the LAN might be `LAN` rather than `Default`, the AP group might not be `All APs`, the built-in zones might be named differently on this console. Those are reads: they cannot damage anything. Fix the literal in `tofu/unifi/data.tf` and re-plan.

Once the plan is right, open a follow-up PR replacing `planOnly: true` with `approvePlan: auto` in `clusters/my-cluster/tofu/terraform-unifi.yaml`. From then on, drift in the console is reverted on the next reconcile.

## Adding the next managed resource

1. Add the resource to the appropriate file under `tofu/unifi/` (or a new file — the directory is flat and files are grouped by kind: `network.tf`, `wlan.tf`, `firewall.tf`).
2. If it depends on something that already exists in the console, reference it with a **data source** in `data.tf`. Do not import it.
3. Run `task tofu-validate` locally.
4. Open a PR. If the CR is still plan-only, read the plan after merge before flipping anything; if it is on `approvePlan: auto`, the change goes live on the next reconcile — so review it like a `kubectl apply`.
5. Update the tables in this document.
