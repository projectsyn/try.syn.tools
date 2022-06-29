#!/usr/bin/env bash

COMMODORE_VERSION="v1.3.2"

commodore() {
  docker run \
    --interactive=true \
    --tty \
    --rm \
    --user="$(id -u)" \
    --env COMMODORE_API_URL="http://host.docker.internal:$LIEUTENANT_PORT" \
    --env COMMODORE_API_TOKEN="$LIEUTENANT_TOKEN" \
    --env SSH_AUTH_SOCK=/tmp/ssh_agent.sock \
    --volume "${SSH_AUTH_SOCK}:/tmp/ssh_agent.sock" \
    --volume "${HOME}/.ssh/config:/app/.ssh/config:ro" \
    --volume "${HOME}/.ssh/known_hosts:/app/.ssh/known_hosts:ro" \
    --volume "${HOME}/.gitconfig:/app/.gitconfig:ro" \
    --volume "${PWD}:/app/data" \
    --workdir /app/data \
    projectsyn/commodore:${COMMODORE_VERSION:=latest} \
    $*
}

check_rancher_desktop() {
    RANCHER_DESKTOP_RUNNING=$(kubectl --context rancher-desktop get nodes | grep rancher-desktop)
    if [ -z "$RANCHER_DESKTOP_RUNNING" ]; then
        echo "===> ERROR: Rancher Desktop Kubernetes is not running"
        exit 1
    fi
    echo "===> Rancher Desktop Kubernetes running"
}

check_variable () {
    if [ -z "${!1}" ]; then
        echo "===> ERROR: variable $1 not set."
        echo "===> $2"
        exit 1
    fi
    echo "===> OK: variable $1 set"
}

wait_for_token () {
    echo "===> Waiting for valid bootstrap token"
    EXPECTED="true"
    COMMAND="kubectl --context docker-desktop -n lieutenant get cluster $1 -o jsonpath={.status.bootstrapToken.tokenValid}"
    RESULT=$($COMMAND)
    while [ "$RESULT" != "$EXPECTED" ]
    do
        echo "===> Not yet OK"
        sleep 10s
        RESULT=$($COMMAND)
    done
    echo "===> Bootstrap token OK"
}

# Rancher Desktop Kubernetes must be running
check_rancher_desktop

# Use proper context
kubectl config use-context docker-desktop

LIEUTENANT_PORT=$(kubectl get svc lieutenant-api -n lieutenant -o go-template='{{(index .spec.ports 0).nodePort}}')
check_variable "LIEUTENANT_PORT" "The Lieutenant API should be running in the Kubernetes service provided by Docker Desktop."

TENANT_ID=$(kubectl --namespace lieutenant get tenant | grep t- | awk 'NR==1{print $1}')
check_variable "TENANT_ID" "The Lieutenant API should be running in the Kubernetes service provided by Docker Desktop, and a Tenant ID should exist."

LIEUTENANT_TOKEN=$(kubectl -n lieutenant get secret api-access-synkickstart-secret -o go-template='{{.data.token | base64decode}}')
check_variable "LIEUTENANT_TOKEN" "The Lieutenant API should be running in the Kubernetes service provided by Docker Desktop, and a Lieutenant token should exist."

LIEUTENANT_AUTH="Authorization: Bearer $LIEUTENANT_TOKEN"

echo "===> Register this cluster via the API"
CLUSTER_ID=$(curl -s -H "$LIEUTENANT_AUTH" -H "Content-Type: application/json" -X POST --data "{ \"tenant\": \"${TENANT_ID}\", \"displayName\": \"K3s cluster\", \"facts\": { \"cloud\": \"local\", \"distribution\": \"k3s\", \"region\": \"local\" }, \"gitRepo\": { \"url\": \"ssh://git@${GITLAB_ENDPOINT}/${GITLAB_USERNAME}/tutorial-cluster-k3s.git\" } }" http://localhost:"${LIEUTENANT_PORT}/clusters" | jq -r ".id")
check_variable "CLUSTER_ID" "A new cluster ID could not be registered."

echo "===> Kickstart Commodore"
echo "===> IMPORTANT: When prompted enter your SSH key password"
commodore catalog compile "$CLUSTER_ID" --push

echo "===> COMMODORE DONE"

echo "===> Check the validity of the bootstrap token"
wait_for_token "$CLUSTER_ID"

echo "===> Retrieve the Steward install URL"
STEWARD_INSTALL=$(curl --header "$LIEUTENANT_AUTH" --silent http://localhost:"${LIEUTENANT_PORT}/clusters/${CLUSTER_ID}" | jq -r ".installURL")
echo "===> Steward install URL: $STEWARD_INSTALL"

# Change context
kubectl config use-context rancher-desktop

echo "===> Install Steward in the local k3s cluster"
kubectl apply -f "$STEWARD_INSTALL"

echo "===> Check that Steward is running and that Argo CD Pods are appearing"
kubectl -n syn get pod

echo ""
echo "===> STEWARD READY ON RANCHER DESKTOP"
