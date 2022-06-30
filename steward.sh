#!/usr/bin/env bash

LIEUTENANT_CONTEXT=minikube
STEWARD_CONTEXT=k3d-steward

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

wait_for_token () {
    echo "===> Waiting for valid bootstrap token"
    EXPECTED="true"
    COMMAND="kubectl --context $LIEUTENANT_CONTEXT -n lieutenant get cluster $1 -o jsonpath={.status.bootstrapToken.tokenValid}"
    RESULT=$($COMMAND)
    while [ "$RESULT" != "$EXPECTED" ]
    do
        echo "===> Not yet OK"
        sleep 10s
        RESULT=$($COMMAND)
    done
    echo "===> Bootstrap token OK"
}

# Clusters must be running
check_kubernetes_context $LIEUTENANT_CONTEXT "Start Minikube with 'minikube start --kubernetes-version=v1.23.8'"
check_kubernetes_context $STEWARD_CONTEXT "Start K3s with 'k3d cluster create steward --image=rancher/k3s:v1.23.8-k3s1'"

LIEUTENANT_URL=$(minikube service lieutenant-api -n lieutenant --url)
check_variable "LIEUTENANT_URL" "The Lieutenant API should be accessible."

TENANT_ID=$(kubectl --context $LIEUTENANT_CONTEXT --namespace lieutenant get tenant | grep t- | awk 'NR==1{print $1}')
check_variable "TENANT_ID" "The Lieutenant API should be accessible, and the Tenant ID should exist."

LIEUTENANT_TOKEN=$(kubectl --context $LIEUTENANT_CONTEXT -n lieutenant get secret api-access-synkickstart-secret -o go-template='{{.data.token | base64decode}}')
check_variable "LIEUTENANT_TOKEN" "The Lieutenant API should be accessible, and the Lieutenant token should exist."

LIEUTENANT_AUTH="Authorization: Bearer $LIEUTENANT_TOKEN"

echo "===> Register this cluster via the API"
CLUSTER_ID=$(curl -s -H "$LIEUTENANT_AUTH" -H "Content-Type: application/json" -X POST --data "{ \"tenant\": \"${TENANT_ID}\", \"displayName\": \"Project Syn Cluster\", \"facts\": { \"cloud\": \"local\", \"distribution\": \"k3s\", \"region\": \"local\" }, \"gitRepo\": { \"url\": \"ssh://git@${GITLAB_ENDPOINT}/${GITLAB_USERNAME}/project-syn-cluster.git\" } }" "${LIEUTENANT_URL}/clusters" | jq -r ".id")
check_variable "CLUSTER_ID" "A new cluster ID could not be registered."

echo "===> Retrieve the registered clusters via API and directly on the cluster"
curl --silent -H "$LIEUTENANT_AUTH" "$LIEUTENANT_URL/clusters" | jq
kubectl --context $LIEUTENANT_CONTEXT -n lieutenant get tenants
kubectl --context $LIEUTENANT_CONTEXT -n lieutenant get clusters
kubectl --context $LIEUTENANT_CONTEXT -n lieutenant get gitrepos

echo "===> Check the validity of the bootstrap token"
wait_for_token "$CLUSTER_ID"

echo "===> Retrieve the Steward install URL"
STEWARD_INSTALL=$(curl --header "$LIEUTENANT_AUTH" --silent "${LIEUTENANT_URL}/clusters/${CLUSTER_ID}" | jq -r ".installURL")
echo "===> Steward install URL: $STEWARD_INSTALL"

echo "===> Install Steward in the local k3s cluster"
kubectl --context $STEWARD_CONTEXT apply -f "$STEWARD_INSTALL"

echo "===> Check that Steward is running and that Argo CD Pods are appearing"
kubectl --context $STEWARD_CONTEXT -n syn get pod

echo ""
echo "===> STEWARD READY ON $STEWARD_CONTEXT"
