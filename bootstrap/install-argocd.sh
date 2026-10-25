#!/usr/bin/env bash
set -euo pipefail

ARGOCD_VERSION="v3.2.0"
REPO_URL="https://github.com/macinsight/kubernetes.git"

kubectl create namespace argocd \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply --server-side --force-conflicts \
  -n argocd \
  -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

kubectl rollout status deployment/argocd-server \
  -n argocd --timeout=300s

kubectl apply -f bootstrap/root-app.yaml
