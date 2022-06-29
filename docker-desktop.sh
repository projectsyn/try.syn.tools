#!/usr/bin/env bash

check_docker_desktop() {
    DOCKER_DESKTOP_RUNNING=$(kubectl --context docker-desktop get nodes | grep docker-desktop)
    if [ -z "$DOCKER_DESKTOP_RUNNING" ]; then
        echo "===> ERROR: Docker Desktop Kubernetes is not running"
        exit 1
    fi
    echo "===> Docker Desktop Kubernetes running"
}

check_variable () {
    if [ -z "${!1}" ]; then
        echo "===> ERROR: variable $1 not set."
        echo "===> $2"
        exit 1
    fi
    echo "===> OK: variable $1 set"
}

wait_for_lieutenant() {
    echo "===> Waiting for Lieutenant API: $1"
    EXPECTED="ok"
    CURL=$(which curl)
    COMMAND="$CURL --silent $1"
    RESULT=$($COMMAND)
    while [ "$RESULT" != "$EXPECTED" ]
    do
        echo "===> Not yet OK"
        sleep 5s
        RESULT=$($COMMAND)
    done
    echo "===> OK"
}

# Verify that environment variables are present
check_variable "GITLAB_TOKEN" "Create a token with 'API' scope at https://gitlab.com/-/profile/personal_access_tokens and set it as an environment variable with this name."
check_variable "GITLAB_ENDPOINT" "If you are using a private GitLab instance, use its URL; otherwise, use 'export GITLAB_ENDPOINT=gitlab.com' instead."
check_variable "GITLAB_USERNAME" "Create a variable with your GitLab instance (or gitlab.com) username."

# Docker Desktop Kubernetes must be running
check_docker_desktop

# Use proper context
kubectl config use-context docker-desktop

echo "===> Creating 'lieutenant' namespace"
kubectl create namespace lieutenant

echo "===> Install CRDs (global scope)"
kubectl apply -k "github.com/projectsyn/lieutenant-operator/config/crd?ref=v1.3.0"

echo "===> Lieutenant operator deployment"
kubectl -n lieutenant apply -k "github.com/projectsyn/lieutenant-operator/config/samples/deployment?ref=v1.3.0"

echo "===> Lieutenant operator configuration"
kubectl -n lieutenant set env deployment/lieutenant-operator -c lieutenant-operator \
    DEFAULT_DELETION_POLICY=Delete \
    DEFAULT_GLOBAL_GIT_REPO_URL=https://github.com/projectsyn/getting-started-commodore-defaults \
    LIEUTENANT_DELETE_PROTECTION=false \
    SKIP_VAULT_SETUP=true

echo "===> Lieutenant API deployment"
kubectl -n lieutenant apply -k "github.com/projectsyn/lieutenant-api/deploy?ref=v0.9.1"

echo "===> Lieutenant API configuration"
kubectl -n lieutenant set env deployment/lieutenant-api -c lieutenant-api \
  DEFAULT_API_SECRET_REF_NAME=gitlab-com

echo "===> For Docker Desktop we must delete the default service and re-create it"
kubectl -n lieutenant delete svc lieutenant-api
kubectl -n lieutenant expose deployment lieutenant-api --type=NodePort

LIEUTENANT_URL=http://localhost:$(kubectl get svc lieutenant-api -n lieutenant -o go-template='{{(index .spec.ports 0).nodePort}}')
echo "===> Lieutenant API: $LIEUTENANT_URL"

wait_for_lieutenant "$LIEUTENANT_URL/healthz"

echo "===> Prepare Lieutenant Operator access to GitLab"
kubectl -n lieutenant create secret generic gitlab-com \
  --from-literal=endpoint="https://${GITLAB_ENDPOINT}" \
  --from-literal=hostKeys="$(ssh-keyscan $GITLAB_ENDPOINT)" \
  --from-literal=token="$GITLAB_TOKEN"

# We need to manually create a secret and assign it to the service account
# because Docker Desktop for Linux 4.9.1 (and apparently other operating systems as well)
# does not create the proper secrets / tokens for new service accounts.
# https://stackoverflow.com/questions/72231518/docker-desktop-for-mac-kubernetes-not-creating-secrets-or-token-for-serviceaccou

echo "===> Prepare Lieutenant API Authentication and Authorization"
kubectl -n lieutenant apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: api-access-synkickstart
secrets:
- name: api-access-synkickstart-secret
---
apiVersion: v1
kind: Secret
metadata:
  name: api-access-synkickstart-secret
  annotations:
    kubernetes.io/service-account.name: api-access-synkickstart
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: lieutenant-api-user
rules:
- apiGroups:
  - syn.tools
  resources:
  - clusters
  - clusters/status
  - tenants
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: lieutenant-api-user
roleRef:
  kind: Role
  name: lieutenant-api-user
  apiGroup: rbac.authorization.k8s.io
subjects:
- kind: ServiceAccount
  name: api-access-synkickstart
EOF

echo "===> Create Lieutenant objects: tenant and cluster"
LIEUTENANT_TOKEN=$(kubectl -n lieutenant get secret api-access-synkickstart-secret -o go-template='{{.data.token | base64decode}}')
LIEUTENANT_AUTH="Authorization: Bearer ${LIEUTENANT_TOKEN}"

echo "===> Create a tenant object via the API"
TENANT_ID=$(curl -s -H "$LIEUTENANT_AUTH" -H "Content-Type: application/json" -X POST --data "{\"displayName\":\"Tutorial Tenant\",\"gitRepo\":{\"url\":\"ssh://git@${GITLAB_ENDPOINT}/${GITLAB_USERNAME}/tutorial-tenant.git\"},\"globalGitRepoRevision\":\"v1\"}" "${LIEUTENANT_URL}/tenants" | jq -r ".id")
echo "Tenant ID: $TENANT_ID"

echo "===> Patch the tenant object to add a cluster template"
kubectl -n lieutenant patch tenant "$TENANT_ID" --type="merge" -p \
"{\"spec\":{\"clusterTemplate\": {
    \"gitRepoTemplate\": {
      \"apiSecretRef\":{\"name\":\"gitlab-com\"},
      \"path\":\"${GITLAB_USERNAME}\",
      \"repoName\":\"{{ .Name }}\"
    },
    \"tenantRef\":{}
}}}"

echo "===> Retrieve the registered tenants via API and directly on the cluster"
curl -H "$LIEUTENANT_AUTH" "${LIEUTENANT_URL}/tenants" | jq
kubectl -n lieutenant get tenant
kubectl -n lieutenant get gitrepo

echo "===> Register a cluster object via the API"
CLUSTER_ID=$(curl -s -H "$LIEUTENANT_AUTH" -H "Content-Type: application/json" -X POST --data "{ \"tenant\": \"${TENANT_ID}\", \"displayName\": \"Minikube cluster\", \"facts\": { \"cloud\": \"local\", \"distribution\": \"k3s\", \"region\": \"local\" }, \"gitRepo\": { \"url\": \"ssh://git@${GITLAB_ENDPOINT}/${GITLAB_USERNAME}/tutorial-cluster-minikube.git\" } }" "${LIEUTENANT_URL}/clusters" | jq -r ".id")
echo "Cluster ID: $CLUSTER_ID"

echo "===> Retrieve the registered clusters via API and directly on the cluster"
curl -H "$LIEUTENANT_AUTH" "$LIEUTENANT_URL/clusters" | jq
kubectl -n lieutenant get cluster
kubectl -n lieutenant get gitrepo

echo "===> LIEUTENANT API READY"
