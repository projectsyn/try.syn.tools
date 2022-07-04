#!/usr/bin/env bash

LIEUTENANT_CONTEXT=k3d-lieutenant
STEWARD_CONTEXT=k3d-steward
LIEUTENANT_PORT=35777
ARGO_CD_PORT=35778

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

wait_for_steward() {
    echo "===> Waiting for Steward in context $STEWARD_CONTEXT"
    EXPECTED="True True True True True"
    COMMAND=(kubectl --context "$STEWARD_CONTEXT" -n syn get pods -o jsonpath="{.items[*].status.conditions[?(@.type=='Ready')].status}")
    RESULT=$("${COMMAND[@]}")
    while [ "$RESULT" != "$EXPECTED" ]
    do
        echo "===> Not yet OK"
        kubectl --context $STEWARD_CONTEXT -n syn get pods
        sleep 5s
        RESULT=$("${COMMAND[@]}")
    done
    echo "===> OK"
}

# Clusters must be running
check_kubernetes_context $LIEUTENANT_CONTEXT "Start K3s with 'k3d cluster create lieutenant --port \"35777:8080@loadbalancer\" --image=rancher/k3s:v1.23.8-k3s1'"
check_kubernetes_context $STEWARD_CONTEXT "Start K3s with 'k3d cluster create steward  --port \"35778:8080@loadbalancer\" --image=rancher/k3s:v1.23.8-k3s1'"

LIEUTENANT_URL=http://host.k3d.internal:$LIEUTENANT_PORT
check_variable "LIEUTENANT_URL" "The Lieutenant API should be accessible."

TENANT_ID=$(kubectl --context $LIEUTENANT_CONTEXT --namespace lieutenant get tenant | grep t- | awk 'NR==1{print $1}')
check_variable "TENANT_ID" "The Lieutenant API should be accessible, and the Tenant ID should exist."

LIEUTENANT_TOKEN=$(kubectl --context $LIEUTENANT_CONTEXT -n lieutenant get secret api-access-synkickstart-secret -o go-template='{{.data.token | base64decode}}')
check_variable "LIEUTENANT_TOKEN" "The Lieutenant API should be accessible, and the Lieutenant token should exist."

LIEUTENANT_AUTH="Authorization: Bearer $LIEUTENANT_TOKEN"

echo "===> Register this cluster via the API"
CLUSTER_ID=$(curl -s -H "$LIEUTENANT_AUTH" -H "Content-Type: application/json" -X POST --data "{ \"tenant\": \"${TENANT_ID}\", \"displayName\": \"Project Syn Cluster\", \"facts\": { \"cloud\": \"local\", \"distribution\": \"k3s\", \"region\": \"local\" }, \"gitRepo\": { \"url\": \"ssh://git@${GITLAB_ENDPOINT}/${GITLAB_USERNAME}/project-syn-cluster.git\" } }" "${LIEUTENANT_URL}/clusters" | jq -r ".id")
check_variable "CLUSTER_ID" "A new cluster ID could not be registered."

echo "===> Check the validity of the bootstrap token"
wait_for_token "$CLUSTER_ID"

echo "===> Retrieve the Steward install URL"
STEWARD_INSTALL=$(curl --header "$LIEUTENANT_AUTH" --silent "${LIEUTENANT_URL}/clusters/${CLUSTER_ID}" | jq -r ".installURL")
echo "===> Steward install URL: $STEWARD_INSTALL"

echo "===> Install Steward in the local k3s cluster"
kubectl --context $STEWARD_CONTEXT apply -f "$STEWARD_INSTALL"

echo "===> Retrieve the registered clusters via API and directly on the cluster"
curl --silent -H "$LIEUTENANT_AUTH" "$LIEUTENANT_URL/clusters" | jq
kubectl --context $LIEUTENANT_CONTEXT -n lieutenant get clusters

echo "===> Check that Steward is running and that Argo CD Pods are all 'Ready'"
wait_for_steward

echo "===> Add Ingress for the Argo CD service"
kubectl --context $STEWARD_CONTEXT -n syn apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  namespace: syn
  name: argocd-ingress
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
            name: argocd-server
            port:
              number: 8080
EOF

echo ""
echo "===> Expose the Argo CD service with this command:"
echo "===> 'kubectl --context $STEWARD_CONTEXT -n syn expose deployment argocd-server --type=LoadBalancer --port=8080'"
echo "===> Access the Argo CD service at http://localhost:$ARGO_CD_PORT"
echo "===> Use the 'admin' user and retrieve the password using:"
echo "===> kubectl --context $STEWARD_CONTEXT -n syn get secret steward -o json | jq -r .data.token | base64 --decode"

echo ""
echo "===> Open the https://$GITLAB_ENDPOINT/$GITLAB_USERNAME/project-syn-cluster project in GitLab"
echo "===> and see the full catalog of objects and settings of your cluster."

echo ""
echo "===> STEWARD READY ON $STEWARD_CONTEXT"
