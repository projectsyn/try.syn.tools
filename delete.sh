#!/usr/bin/env bash

LIEUTENANT_CONTEXT=minikube

check_variable () {
    if [ -z "${!1}" ]; then
        echo "===> ERROR: variable $1 not set."
        echo "===> $2"
        exit 1
    fi
    echo "===> OK: variable $1 set to ${!1}"
}

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

echo "===> Waiting 20 seconds for the removal of GitLab repositories"
sleep 20s

minikube delete
k3d cluster delete steward
