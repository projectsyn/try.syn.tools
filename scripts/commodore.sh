#!/usr/bin/env bash

export LIEUTENANT_CONTEXT=k3d-lieutenant
export STEWARD_CONTEXT=k3d-steward
export LIEUTENANT_PORT=35777

export LIEUTENANT_URL
LIEUTENANT_URL=http://host.k3d.internal:$LIEUTENANT_PORT

export LIEUTENANT_TOKEN
LIEUTENANT_TOKEN=$(kubectl --context $LIEUTENANT_CONTEXT -n lieutenant get secret api-access-synkickstart-secret -o go-template='{{.data.token | base64decode}}')

export CLUSTER_ID
CLUSTER_ID=$(kubectl --context $LIEUTENANT_CONTEXT get clusters -n lieutenant -o jsonpath="{.items[0].metadata.name}")

commodore() {
    echo "===> Commodore will compile and push the settings of the $STEWARD_CONTEXT cluster"
    echo "===> IMPORTANT: When prompted with 'If you don't see a command prompt, try pressing enter' enter your SSH key password instead."
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
    -- /usr/local/bin/entrypoint.sh bash -c "ssh-keyscan $GITLAB_ENDPOINT >> /app/.ssh/known_hosts; commodore $*"

    echo ""
    echo "===> COMMODORE READY FOR $STEWARD_CONTEXT"
}
