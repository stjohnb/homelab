# Transmission with WireGuard VPN

Transmission BitTorrent client running in k3s with all traffic routed through Mullvad via WireGuard.

## Architecture

```
Internet
   ↑
   │ Mullvad exit: 146.70.189.2 (ie-dub)
   │
┌──┴─────────────────────────┐
│  k3s Pod (default ns)      │
│  ┌──────────────────────┐  │
│  │ WireGuard Container  │  │
│  │ (kill switch in      │  │
│  │  PostUp/PostDown)    │  │
│  └──────────────────────┘  │
│  ┌──────────────────────┐  │
│  │ Transmission         │  │
│  │ Port: 9091 (web)     │  │
│  │ Port: 51413 (peer)   │  │
│  └──────────────────────┘  │
└────────────────────────────┘
```

## Security Features

### Kill Switch
- iptables rules in WireGuard PostUp/PostDown block all non-tunnel traffic
- If WireGuard fails, no packets can leak to the internet
- Only allows traffic to Mullvad endpoint (146.70.189.2:51820) and through wg0 interface
- Health check rules allow kubelet probes on eth0

### Network Isolation
- NetworkPolicy restricts pod communication
- Blocks access to local network (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)
- Only allows: DNS, WireGuard to Mullvad, and web UI access

## Prerequisites

### 1. Mullvad WireGuard Config (✅ Complete)
Config is stored in the `transmission-wireguard` secret (`wg0.conf` key). Generated from Mullvad's
account page (Linux / WireGuard config → ie-dub), with an added kill switch block in PostUp/PostDown.

### 2. Storage Configuration (✅ Complete)
Config is on **local-path**, media/downloads are on NFS:

- **Config PVC**: `transmission-local-config-pvc` (5Gi, `storageClassName: local-path`) —
  defined in `pvc.yaml`, mounted at `/config`. Node-local on `k3s-nas`, **not** on NFS.
- **Downloads PV**: `192.168.0.128:/mnt/SSD-POOL` (10Ti, `ssdpool-pvc`, `subPath: downloads`) —
  defined in `../shared-pvcs.yaml`, mounted at `/downloads`
- **Mount options** (NFS only): NFSv3, hard, intr
- **Behavior**: if the NAS is offline, the pod waits patiently and resumes when storage returns

> The pool directory `/mnt/SSD-POOL/downloads/config` is **not** Transmission's config. It is a
> frozen pre-migration snapshot from 2026-02-11 (16 stale `.torrent` + resume files) left behind
> when config moved to local-path PVCs. Reading it gives a wrong answer about what is seeding.
> See [docs/servarr.md](../../../docs/servarr.md#retired-pre-migration-config-directories).

### 3. Domain & DNS (✅ Complete)
Configured domain: `transmission.home.bstjohn.net`
- A record points to k3s node: 192.168.0.251 (via `*.home.bstjohn.net` wildcard)
- Shared wildcard certificate (`wildcard-home-tls`)

### 4. Web UI Authentication (✅ Complete)
Transmission has no local RPC auth. The web UI is protected by Authentik ForwardAuth on the
ingress (`default-authentik-auth@kubernetescrd`) and by `networkpolicy.yaml` on the ClusterIP.
`rpc-authentication-required: false` is pinned by the `set-seed-limits` init container (#921).

## Deployment

### Quick Deploy
```bash
# From repo root
kubectl apply -k servarr/transmission
```

### Step-by-Step Deploy
```bash
# 1. Create the secret
kubectl apply -f servarr/transmission/secret-wireguard.yaml

# 2. Create PVCs
kubectl apply -f servarr/transmission/pvc.yaml

# 3. Create deployment
kubectl apply -f servarr/transmission/deployment.yaml

# 4. Create service
kubectl apply -f servarr/transmission/service.yaml

# 5. Create ingress
kubectl apply -f servarr/transmission/ingress.yaml

# 6. Create network policy
kubectl apply -f servarr/transmission/networkpolicy.yaml
```

### Via Flux GitOps
If using Flux, commit and push the changes:
```bash
git add .
git commit -m "Add Transmission with WireGuard VPN"
git push
```

Flux will automatically apply the changes.

## Verification

### 1. Check Pod Status
```bash
kubectl get pods -l app=transmission
kubectl logs -l app=transmission -c wireguard
kubectl logs -l app=transmission -c transmission
```

### 2. Verify Kill Switch
```bash
# Check iptables rules
kubectl exec -it deployment/transmission -c wireguard -- iptables -L -n -v
```

### 3. Test IP Leak Protection
```bash
# Should show a Mullvad exit IP (ie-dub: 146.70.189.x) — never your home IP
kubectl exec -it deployment/transmission -c transmission -- curl -s ifconfig.me

# Test DNS
kubectl exec -it deployment/transmission -c transmission -- nslookup google.com

# Test that local network is blocked (should fail)
kubectl exec -it deployment/transmission -c transmission -- ping -c 3 192.168.1.1
```

### 4. Check WireGuard Tunnel
```bash
# From within the pod
kubectl exec -it deployment/transmission -c wireguard -- wg show
```

### 5. Access Web UI
Navigate to: https://transmission.home.bstjohn.net

Log in with your Authentik account; there is no separate Transmission password.

## Configuration

### Transmission Settings
Transmission config is stored in the `transmission-config-pvc` volume at `/config`.

Key settings to configure:
- **Download location**: `/downloads/complete`
- **Incomplete download location**: `/downloads/incomplete`
- **Watch directory**: `/watch` (drop .torrent files here)
- **Peer port**: `51413` (must match iptables and PEERPORT env var)
- **RPC whitelist**: Add your LAN subnet if needed
- **Seeding**: disabled — `ratio-limit: 0.0` with `ratio-limit-enabled: true`, pinned by the
  `set-seed-limits` init container, stops every torrent at 100% (#1078)

### Port Forwarding
Mullvad removed port forwarding in 2023, so inbound peer connections via 51413 are not available.
Transmission will still connect outbound to peers — throughput is usually unaffected for popular torrents.

## Troubleshooting

### Pod Won't Start
```bash
# Check pod events
kubectl describe pod -l app=transmission

# Check WireGuard logs (includes kill switch setup)
kubectl logs -l app=transmission -c wireguard -f

# Check Transmission logs
kubectl logs -l app=transmission -c transmission -f
```

### No Internet in Pod
```bash
# Check WireGuard status
kubectl exec -it deployment/transmission -c wireguard -- wg show

# Check routes
kubectl exec -it deployment/transmission -c wireguard -- ip route

# Test DNS (via Mullvad DNS through the tunnel)
kubectl exec -it deployment/transmission -c transmission -- nslookup google.com
```

### IP Leak Detected
```bash
# Verify public IP is a Mullvad exit (should NOT match your home IP)
kubectl exec -it deployment/transmission -c transmission -- curl -s ifconfig.me

# If it shows your home IP, check:
# 1. WireGuard is running: kubectl logs -l app=transmission -c wireguard
# 2. Kill switch is active: kubectl exec -it deployment/transmission -c wireguard -- iptables -L -n -v
# 3. Mullvad account is still active / key hasn't been revoked
```

### Cannot Access Web UI
```bash
# Check service
kubectl get svc transmission

# Check ingress
kubectl get ingress transmission
kubectl describe ingress transmission

# Check pod is ready
kubectl get pods -l app=transmission

# Test from within cluster
kubectl run -it --rm debug --image=alpine --restart=Never -- sh
# apk add curl
# curl http://transmission:9091/transmission/web/
```

### Storage Issues
```bash
# Check PVC status
kubectl get pvc | grep transmission

# Check PV
kubectl get pv

# If using NFS, check mount on node
ssh <k3s-node>
mount | grep nfs
```

### WireGuard Key Rotation
If the Mullvad key is revoked or a new exit server is needed:

```bash
# 1. Download a fresh config from mullvad.net (Linux / WireGuard)
# 2. Apply the kill-switch PostUp/PostDown block from the existing wg0.conf
# 3. Update the secret (replace <path> with the new wg0.conf)
kubectl delete secret transmission-wireguard
kubectl create secret generic transmission-wireguard \
  --from-file=wg0.conf=<path>

# 4. Restart pod
kubectl rollout restart deployment/transmission
```

## Monitoring

### Pod Resource Usage
```bash
kubectl top pod -l app=transmission
```

### WireGuard Bandwidth
```bash
kubectl exec -it deployment/transmission -c wireguard -- wg show wg0 transfer
```

### Transmission Stats
Access web UI and check:
- Download/upload rates
- Active torrents
- Peer connections
- Port status (should show as open)

## Maintenance

### Update Transmission
```bash
# Update image tag in deployment.yaml
# Then apply
kubectl apply -f servarr/transmission/deployment.yaml

# Or force pull latest
kubectl rollout restart deployment/transmission
```

### Update WireGuard
```bash
# Update image tag in deployment.yaml
# Then apply
kubectl apply -f servarr/transmission/deployment.yaml
```

### Backup Configuration
```bash
# Backup Transmission settings
kubectl exec deployment/transmission -c transmission -- \
  tar czf - /config | tar xzf - -C ./backup/
```

## Security Recommendations

1. **Restrict web UI access** to your LAN subnet only
2. **Access control** — Authentik ForwardAuth at the ingress plus NetworkPolicy on the ClusterIP;
   Transmission itself runs with RPC auth disabled (#921)
3. **Keep WireGuard keys secure** (stored only in the `transmission-wireguard` secret)
4. **Regular updates** of container images
5. **Monitor bandwidth** for anomalies
6. **Audit NetworkPolicy** regularly

## References

- Todo & Plans: `../TODO.md`
- WireGuard config source: Mullvad account page → Linux / WireGuard (ie-dub)
- Secrets: `transmission-wireguard` (created imperatively via kubectl)
