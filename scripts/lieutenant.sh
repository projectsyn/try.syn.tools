#!/usr/bin/env bash

LIEUTENANT_CONTEXT=k3d-lieutenant
LIEUTENANT_PORT=35777

check_kubernetes_context() {
    CONTEXT_AVAILABLE=$(kubectl --context "$1" get nodes | grep "$1")
    if [ -z "$CONTEXT_AVAILABLE" ]; then
        echo "===> ERROR: Kubernetes context $1 is not available"
        echo "===> $2"
        exit 1
    fi
    echo "===> Kubernetes context $1 available"
}

check_variable () {
    if [ -z "${!1}" ]; then
        echo "===> ERROR: variable $1 not set."
        echo "===> $2"
        exit 1
    fi
    echo "===> OK: variable $1 set to ${!1}"
}

wait_for_lieutenant() {
    echo "===> Waiting for Lieutenant API: $1"
    EXPECTED="ok"
    CURL=$(which curl)
    COMMAND="$CURL --silent $1"
    RESULT=$($COMMAND)
    while [ "$RESULT" != "$EXPECTED" ]
    do
        echo "===> Not yet OK, waiting 10 seconds"
        sleep 10s
        RESULT=$($COMMAND)
    done
    echo "===> OK"
}

# Verify that environment variables are present
check_variable "GITLAB_TOKEN" "Create a token with 'API' scope at https://gitlab.com/-/profile/personal_access_tokens and export it as an environment variable with this name."
check_variable "GITLAB_ENDPOINT" "If you are using a private GitLab instance, use its URL; otherwise, use 'export GITLAB_ENDPOINT=gitlab.com' instead."
check_variable "GITLAB_USERNAME" "Create a variable with your GitLab instance (or gitlab.com) username."

# Cluster must be running
check_kubernetes_context $LIEUTENANT_CONTEXT "Start K3s with 'k3d cluster create lieutenant --port \"35777:8080@loadbalancer\" --image=rancher/k3s:v1.23.8-k3s1'"

echo "===> Creating 'lieutenant' namespace"
kubectl --context $LIEUTENANT_CONTEXT create namespace lieutenant

echo "===> Install CRDs (global scope)"
kubectl --context $LIEUTENANT_CONTEXT apply -k "github.com/projectsyn/lieutenant-operator/config/crd?ref=v1.3.0"

echo "===> Lieutenant operator deployment"
kubectl --context $LIEUTENANT_CONTEXT -n lieutenant apply -k "github.com/projectsyn/lieutenant-operator/config/samples/deployment?ref=v1.3.0"

echo "===> Lieutenant operator configuration"
kubectl --context $LIEUTENANT_CONTEXT -n lieutenant set env deployment/lieutenant-operator -c lieutenant-operator \
    DEFAULT_DELETION_POLICY=Delete \
    DEFAULT_GLOBAL_GIT_REPO_URL=https://github.com/projectsyn/getting-started-commodore-defaults \
    LIEUTENANT_DELETE_PROTECTION=false \
    SKIP_VAULT_SETUP=true

echo "===> Lieutenant API deployment"
kubectl --context $LIEUTENANT_CONTEXT -n lieutenant apply -k "github.com/projectsyn/lieutenant-api/deploy?ref=v0.9.1"

echo "===> Lieutenant API configuration"
kubectl --context $LIEUTENANT_CONTEXT -n lieutenant set env deployment/lieutenant-api -c lieutenant-api \
  DEFAULT_API_SECRET_REF_NAME=gitlab-com

echo "===> Replace the Lieutenant service"
kubectl --context $LIEUTENANT_CONTEXT -n lieutenant delete svc lieutenant-api
kubectl --context $LIEUTENANT_CONTEXT -n lieutenant expose deployment lieutenant-api --type=LoadBalancer --port=8080

echo "===> Expose the Lieutenant service"
kubectl --context $LIEUTENANT_CONTEXT -n lieutenant apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  namespace: lieutenant
  name: lieutenant-ingress
  annotations:
    ingress.kubernetes.io/ssl-redirect: "false"
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: lieutenant-api
            port:
              number: 8080
EOF

LIEUTENANT_URL=http://host.k3d.internal:$LIEUTENANT_PORT
echo "===> Lieutenant API: $LIEUTENANT_URL"

wait_for_lieutenant "$LIEUTENANT_URL/healthz"

echo "===> Prepare Lieutenant Operator access to GitLab"
kubectl --context $LIEUTENANT_CONTEXT -n lieutenant create secret generic gitlab-com \
  --from-literal=endpoint="https://${GITLAB_ENDPOINT}" \
  --from-literal=hostKeys="$(ssh-keyscan $GITLAB_ENDPOINT)" \
  --from-literal=token="$GITLAB_TOKEN"

echo "===> Prepare Lieutenant API Authentication and Authorization"
kubectl --context $LIEUTENANT_CONTEXT -n lieutenant apply -f - <<EOF
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
LIEUTENANT_TOKEN=$(kubectl --context $LIEUTENANT_CONTEXT -n lieutenant get secret api-access-synkickstart-secret -o go-template='{{.data.token | base64decode}}')
LIEUTENANT_AUTH="Authorization: Bearer ${LIEUTENANT_TOKEN}"

echo "===> Create a tenant object via the API"
TENANT_ID=$(curl -s -H "$LIEUTENANT_AUTH" -H "Content-Type: application/json" -X POST --data "{\"displayName\":\"Project Syn Tenant\",\"gitRepo\":{\"url\":\"ssh://git@${GITLAB_ENDPOINT}/${GITLAB_USERNAME}/project-syn-tenant.git\"},\"globalGitRepoRevision\":\"v1\"}" "${LIEUTENANT_URL}/tenants" | jq -r ".id")
echo "Tenant ID: $TENANT_ID"

echo "===> Patch the tenant object to add a cluster template"
kubectl --context $LIEUTENANT_CONTEXT -n lieutenant patch tenant "$TENANT_ID" --type="merge" -p \
"{\"spec\":{\"clusterTemplate\": {
    \"gitRepoTemplate\": {
      \"apiSecretRef\":{\"name\":\"gitlab-com\"},
      \"path\":\"${GITLAB_USERNAME}\",
      \"repoName\":\"{{ .Name }}\"
    },
    \"tenantRef\":{}
}}}"

echo "===> Retrieve the registered tenants via API and directly on the cluster"
curl --silent -H "$LIEUTENANT_AUTH" "${LIEUTENANT_URL}/tenants" | jq
kubectl --context $LIEUTENANT_CONTEXT -n lieutenant get tenants

echo ""
echo "===> Open the https://$GITLAB_ENDPOINT/$GITLAB_USERNAME/project-syn-tenant project in GitLab"
echo "===> and see the Git repository of your tenant."

echo ""
echo "===> LIEUTENANT READY ON $LIEUTENANT_CONTEXT"
