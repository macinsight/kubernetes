
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Pinned versions; update deliberately when upgrading.
ARGOCD_VERSION="v3.5.6"
CERT_MANAGER_VERSION="v1.21.3"

ARGOCD_HOST="argocd.macinsight.net"
ACME_ISSUER="letsencrypt-cloudflare"
ACME_EMAIL="${ACME_EMAIL:-}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run this script as root: sudo $0" >&2
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl is not installed. Install k3s first." >&2
  exit 1
fi

kubectl get nodes >/dev/null

if ! kubectl get ingressclass traefik >/dev/null 2>&1; then
  echo "Traefik IngressClass not found. This script expects k3s's bundled Traefik." >&2
  exit 1
fi

if [[ -z "$ACME_EMAIL" ]]; then
  read -r -p "Email address for Let's Encrypt: " ACME_EMAIL
fi

if [[ -z "$ACME_EMAIL" ]]; then
  echo "An email address is required." >&2
  exit 1
fi

read -r -s -p "Cloudflare API token: " CLOUDFLARE_API_TOKEN
echo

if [[ -z "$CLOUDFLARE_API_TOKEN" ]]; then
  echo "A Cloudflare API token is required." >&2
  exit 1
fi

cleanup() {
  unset CLOUDFLARE_API_TOKEN
}
trap cleanup EXIT

echo "==> Installing cert-manager ${CERT_MANAGER_VERSION}"

kubectl apply -f \
  "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

kubectl rollout status deployment/cert-manager \
  -n cert-manager --timeout=300s

kubectl rollout status deployment/cert-manager-cainjector \
  -n cert-manager --timeout=300s

kubectl rollout status deployment/cert-manager-webhook \
  -n cert-manager --timeout=300s

echo "==> Creating Cloudflare credential"

# The token is sent through stdin and is not written to a local file.
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloudflare-api-token
  namespace: cert-manager
type: Opaque
stringData:
  api-token: "${CLOUDFLARE_API_TOKEN}"
EOF

unset CLOUDFLARE_API_TOKEN

echo "==> Creating Let's Encrypt ClusterIssuer"

kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${ACME_ISSUER}
spec:
  acme:
    email: "${ACME_EMAIL}"
    server: https://acme-v02.api.letsencrypt.org/directory
    privateKeySecretRef:
      name: letsencrypt-cloudflare-account
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token
              key: api-token
EOF

echo "==> Installing Argo CD ${ARGOCD_VERSION}"

kubectl create namespace argocd \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply --server-side --force-conflicts \
  -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

kubectl rollout status deployment/argocd-server \
  -n argocd --timeout=600s

echo "==> Configuring Argo CD behind Traefik HTTPS termination"

kubectl patch configmap argocd-cmd-params-cm \
  -n argocd \
  --type merge \
  -p '{"data":{"server.insecure":"true"}}'

kubectl rollout restart deployment/argocd-server -n argocd

kubectl rollout status deployment/argocd-server \
  -n argocd --timeout=300s

echo "==> Registering public Git repository"

GIT_REPO_URL="https://github.com/USERNAME/REPOSITORY.git"

kubectl create secret generic git-repository \
  --namespace argocd \
  --from-literal=type=git \
  --from-literal=url="$GIT_REPO_URL" \
  --dry-run=client -o yaml |
  kubectl apply -f -

kubectl label secret git-repository \
  --namespace argocd \
  argocd.argoproj.io/secret-type=repository \
  --overwrite

echo "==> Public Git repository registered: ${GIT_REPO_URL}"

echo "==> Creating public HTTPS Ingress"

kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: ${ACME_ISSUER}
spec:
  ingressClassName: traefik
  tls:
    - hosts:
        - ${ARGOCD_HOST}
      secretName: argocd-server-tls
  rules:
    - host: ${ARGOCD_HOST}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF

echo "==> Waiting for the TLS certificate"

kubectl wait \
  --for=condition=Ready \
  certificate/argocd-server-tls \
  -n argocd \
  --timeout=600s

echo
echo "==> Deployment complete"
echo "URL: https://${ARGOCD_HOST}"
echo
echo "Initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
echo
echo
echo "Username: admin"
echo "Change the initial password after logging in."
