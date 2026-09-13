
# Read-Only Kubectl/K9s Access

RBAC configuration for read-only cluster access, enforcing GitOps workflow.

## Purpose

Prevents direct cluster modifications via kubectl while maintaining full observability through k9s.

**Philosophy:** All changes should go through Git → PR → Review → Merge → Flux

## Permissions

**✅ Allowed:**
- View all resources (`get`, `list`, `watch`)
- View pod logs
- Port-forward to pods
- View node/pod resource metrics (`metrics.k8s.io`, powers Headlamp and `kubectl top`)
- Full k9s monitoring

**❌ Blocked:**
- Create/update/delete resources
- `kubectl apply/delete/scale`
- `kubectl exec` (shell access - disabled by default)
- Any write operations

## Setup Instructions

### After Merge

1. **Wait for Flux to deploy** (~1 min after merge)
   ```bash
   kubectl get sa readonly-user -n default
   ```

2. **Extract token**
   ```bash
   TOKEN=$(kubectl get secret readonly-user-token -n default \
     -o jsonpath='{.data.token}' | base64 -d)
   ```

3. **Get cluster info**
   ```bash
   CLUSTER=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
   SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
   ```

4. **Add readonly context**
   ```bash
   kubectl config set-credentials readonly-user --token="$TOKEN"

   kubectl config set-context readonly-context \
     --cluster="$CLUSTER" \
     --user=readonly-user \
     --namespace=default
   ```

5. **Switch to readonly**
   ```bash
   kubectl config use-context readonly-context
   ```

6. **Verify**
   ```bash
   kubectl get pods              # ✅ Should work
   kubectl delete pod test       # ❌ Should fail
   ```

## K9s Integration

K9s automatically uses the active kubectl context - no additional configuration needed!

```bash
k9s  # Launches with readonly permissions
```

Operations in k9s:
- Browse resources: ✅
- View logs: ✅
- Port-forward: ✅
- Delete (Ctrl+D): ❌ Shows "forbidden"
- Edit (E): ❌ Shows "forbidden"

## Context Switching

Create helper script at `~/.local/bin/k8s-ctx`:

```bash
#!/bin/bash
case "$1" in
  ro)    kubectl config use-context readonly-context
         echo "✅ READ-ONLY mode" ;;
  admin) kubectl config use-context default
         echo "⚠️  ADMIN mode - use GitOps!" ;;
  *)     kubectl config current-context ;;
esac
```

```bash
chmod +x ~/.local/bin/k8s-ctx

# Usage:
k8s-ctx ro      # Daily use
k8s-ctx admin   # Emergencies only
k8s-ctx         # Show current
```

## Shell Prompt

Show current context in prompt (add to `~/.bashrc` or `~/.zshrc`):

```bash
# Show context with visual indicator
export PS1='[\u@\h \W $(kubectl config current-context 2>/dev/null | \
  sed "s/readonly-context/🔒RO/;s/default/⚠️ADMIN/")]\$ '
```

## Customization

### Enable Pod Exec (Shell Access)

If you need debugging shells, edit `clusterrole.yaml`:

```yaml
# Uncomment:
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: ["create", "get"]
```

Commit, push, merge - Flux will update the role.

### Add Namespace-Specific Rules

For more granular control, create additional RoleBindings:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: readonly-user-dev
  namespace: dev
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: read-only-cluster-viewer
subjects:
  - kind: ServiceAccount
    name: readonly-user
    namespace: default
```

## Troubleshooting

### Token Expired

```bash
# Switch to admin context
kubectl config use-context default

# Delete and recreate secret
kubectl delete secret readonly-user-token -n default
kubectl apply -f clusters/my-cluster/config/rbac/secret.yaml

# Re-run setup steps 2-5
```

### Wrong Context

```bash
kubectl config current-context
# Should show: readonly-context

# If wrong:
kubectl config use-context readonly-context
```

### K9s Shows "Forbidden" for Everything

Likely in wrong context:

```bash
kubectl config use-context readonly-context
k9s
```

## Emergency Admin Access

**Option 1: Use admin context (preferred)**
```bash
kubectl config use-context default
# Do emergency work
kubectl config use-context readonly-context  # Switch back!
```

**Option 2: Temporary admin binding (not recommended)**
```bash
kubectl config use-context default
kubectl create clusterrolebinding readonly-temp-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=default:readonly-user

# After emergency:
kubectl delete clusterrolebinding readonly-temp-admin
```

## Security Notes

1. **Token Protection**: Token is in kubeconfig - protect `~/.kube/config`
2. **Token Rotation**: Tokens don't expire by default - recreate periodically
3. **Audit Logging**: Enable cluster audit logs to track access
4. **Per-User Accounts**: Create separate ServiceAccounts for each person

## Benefits

- ✅ Prevents accidental kubectl mistakes
- ✅ Forces code review on all changes
- ✅ Git audit trail for all modifications
- ✅ CI validation before deployment
- ✅ Easy rollbacks via Git
- ✅ Maintains full monitoring capability

---

**Remember:** Direct kubectl write operations bypass review, audit trails, and disaster recovery. Read-only access enforces discipline while maintaining observability.
