# Cluster OIDC discovery documents

These two extensionless files are the k3s API server's OIDC discovery documents
for the issuer `https://www.bstjohn.net/k3s-oidc`. They are published to
`s3://www.bstjohn.net/k3s-oidc/` by `.github/workflows/publish-oidc-discovery.yml`
so that AWS IAM can fetch them and validate ServiceAccount tokens issued by this
cluster — that is what lets cert-manager's ACME DNS-01 Route53 solver assume its
IAM role by web identity, with no long-lived AWS credentials stored anywhere.
`openid/v1/jwks` holds the cluster's **public** ServiceAccount signing key and is
safe to publish; regenerate it verbatim from `kubectl get --raw /openid/v1/jwks`
if the cluster is rebuilt or the signing key rotates, and re-run the publish
workflow (a push to `main` touching `oidc/**` does this automatically, or trigger
it manually with `workflow_dispatch`). If the documents served from the bucket
stop matching the cluster, every DNS-01 challenge fails and certificate renewal
breaks.
