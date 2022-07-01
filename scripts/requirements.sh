#!/usr/bin/env bash

KUBECTL_VERSION=$(kubectl version --client=true)
echo "$KUBECTL_VERSION"

MINIKUBE_VERSION=$(minikube version | grep version)
echo "$MINIKUBE_VERSION"

K3D_VERSION=$(k3d version | grep version -m 1)
echo "$K3D_VERSION"

CURL_PATH=$(which curl)
echo "curl: $CURL_PATH"

JQ_PATH=$(which jq)
echo "jq: $JQ_PATH"
