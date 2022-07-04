#!/usr/bin/env bash

LIEUTENANT_CONTEXT=k3d-lieutenant
STEWARD_CONTEXT=k3d-steward
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

# Clusters must be running
check_kubernetes_context $LIEUTENANT_CONTEXT "Start K3s with 'k3d cluster create lieutenant --image=rancher/k3s:v1.23.8-k3s1'"
check_kubernetes_context $STEWARD_CONTEXT "Start K3s with 'k3d cluster create steward --image=rancher/k3s:v1.23.8-k3s1'"

# Variables must be set
check_variable "GITLAB_ENDPOINT" "If you are using a private GitLab instance, use its URL; otherwise, use 'export GITLAB_ENDPOINT=gitlab.com' instead."
check_variable "GITLAB_USERNAME" "Create a variable with your GitLab instance (or gitlab.com) username."
check_variable "COMMODORE_SSH_PRIVATE_KEY" "Export a variable with the path to your private key: 'export COMMODORE_SSH_PRIVATE_KEY=~/.ssh/id_ed25519'"

LIEUTENANT_URL=http://host.k3d.internal:$LIEUTENANT_PORT
check_variable "LIEUTENANT_URL" "The Lieutenant API should be accessible."

LIEUTENANT_TOKEN=$(kubectl --context $LIEUTENANT_CONTEXT -n lieutenant get secret api-access-synkickstart-secret -o go-template='{{.data.token | base64decode}}')
check_variable "LIEUTENANT_TOKEN" "The Lieutenant API should be accessible, and the Lieutenant token should exist."

CLUSTER_ID=$(kubectl --context $LIEUTENANT_CONTEXT get clusters -n lieutenant -o jsonpath="{.items[0].metadata.name}")
check_variable "CLUSTER_ID" "The Cluster ID must exist."

echo "===> Commodore will compile and push the settings of the $STEWARD_CONTEXT cluster"
echo "===> IMPORTANT: When prompted with 'If you don't see a command prompt, try pressing enter'… enter your SSH key password instead."
kubectl --context $LIEUTENANT_CONTEXT -n lieutenant run commodore-shell \
  --image=docker.io/projectsyn/commodore:v1.3.2 \
  --env=COMMODORE_API_URL="$LIEUTENANT_URL" \
  --env=COMMODORE_API_TOKEN="$LIEUTENANT_TOKEN" \
  --env=SSH_PRIVATE_KEY="$(cat ${COMMODORE_SSH_PRIVATE_KEY})" \
  --env=CLUSTER_ID="$CLUSTER_ID" \
  --env=GITLAB_ENDPOINT="$GITLAB_ENDPOINT" \
  --tty --stdin --restart=Never --rm --wait \
  --image-pull-policy=Always \
  --command \
  -- /usr/local/bin/entrypoint.sh bash -c "ssh-keyscan $GITLAB_ENDPOINT >> /app/.ssh/known_hosts; commodore catalog compile $CLUSTER_ID --push"

echo ""
echo "===> Open the https://$GITLAB_ENDPOINT/$GITLAB_USERNAME/project-syn-cluster project in GitLab"
echo "===> and see the full catalog of objects and settings of your cluster."

echo ""
echo "===> COMMODORE READY ON $STEWARD_CONTEXT"
