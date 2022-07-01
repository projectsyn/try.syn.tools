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

# Clusters must be running
check_kubernetes_context $LIEUTENANT_CONTEXT "Start Minikube with 'minikube start --kubernetes-version=v1.23.8'"
check_kubernetes_context $STEWARD_CONTEXT "Start K3s with 'k3d cluster create steward --image=rancher/k3s:v1.23.8-k3s1'"

echo "===> Find Tenant ID"
TENANT_ID=$(kubectl --context $LIEUTENANT_CONTEXT -n lieutenant get tenant | grep t- | awk 'NR==1{print $1}')
check_variable "TENANT_ID" "The Lieutenant API should be accessible, and the Tenant ID should exist."

echo "===> Removing all clusters"
CLUSTERS=($(kubectl --context $LIEUTENANT_CONTEXT -n lieutenant get cluster -o jsonpath="{$.items[*].metadata.name}"))
for CLUSTER in "${CLUSTERS[@]}"; do
    kubectl --context $LIEUTENANT_CONTEXT -n lieutenant delete cluster "$CLUSTER"
done

echo "===> Removing tenant"
kubectl --context $LIEUTENANT_CONTEXT -n lieutenant delete tenant "$TENANT_ID"

echo "===> Wait a few seconds for the removal of GitLab repositories, and then"
echo "===> remove the Minikube cluster using the 'minikube delete' command and"
echo "===> remove the K3s cluster using the 'k3d cluster delete steward' command."
