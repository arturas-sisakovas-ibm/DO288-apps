#!/usr/bin/env bash

set -euo pipefail

#
# Usage:
#   checkpoint-pod.sh <namespace> <pod> [container]
#
# Examples:
#   checkpoint-pod.sh myns mypod
#       -> checkpoints every container in the pod
#
#   checkpoint-pod.sh myns mypod nginx
#       -> checkpoints only the nginx container
#

if [[ $# -lt 2 || $# -gt 3 ]]; then
    echo "Usage: $0 <namespace> <pod> [container]"
    exit 1
fi

NS="$1"
POD="$2"
CONTAINER="${3:-}"

TMPPOD="checkpoint-copy-$(date +%s)"

cleanup() {
    echo
    echo "Cleaning up helper pod..."
    oc delete pod "$TMPPOD" -n default --ignore-not-found >/dev/null 2>&1 || true
}

trap cleanup EXIT

echo "Locating pod..."

NODE=$(oc get pod "$POD" -n "$NS" -o jsonpath='{.spec.nodeName}')

if [[ -z "$NODE" ]]; then
    echo "Unable to determine node for pod."
    exit 1
fi

echo "Pod runs on node: $NODE"

echo
echo "Creating privileged helper pod..."

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${TMPPOD}
  namespace: default
spec:
  nodeName: ${NODE}
  hostPID: true
  hostNetwork: true
  restartPolicy: Never
  containers:
  - name: helper
    image: repo.com/rhel9/support-tools:9.4-8.1719560852
    command:
      - sleep
      - infinity
    securityContext:
      privileged: true
    volumeMounts:
    - name: host
      mountPath: /host
  volumes:
  - name: host
    hostPath:
      path: /
EOF

echo
echo "Waiting for helper pod..."

oc wait \
    --for=condition=Ready \
    pod/"$TMPPOD" \
    -n default \
    --timeout=120s

#
# Determine containers
#
if [[ -n "$CONTAINER" ]]; then
    CONTAINERS=("$CONTAINER")
else
    mapfile -t CONTAINERS < <(
        oc get pod "$POD" -n "$NS" \
            -o jsonpath='{range .status.containerStatuses[*]}{.name}{"\n"}{end}'
    )
fi

if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
    echo "No containers found."
    exit 1
fi

SUCCESS=()
FAILED=()

echo
echo "Containers to checkpoint:"
printf '  %s\n' "${CONTAINERS[@]}"
echo

for C in "${CONTAINERS[@]}"; do

    echo "===================================================="
    echo "Container: $C"

    CID=$(oc get pod "$POD" -n "$NS" \
        -o jsonpath="{.status.containerStatuses[?(@.name=='${C}')].containerID}")

    CID="${CID#cri-o://}"

    if [[ -z "$CID" ]]; then
        echo "Unable to determine container ID."
        FAILED+=("$C")
        continue
    fi

    OUTFILE="/var/lib/kubelet/checkpoints/${POD}-${C}.tar"

    echo "Creating checkpoint..."

    if ! oc exec -n default "$TMPPOD" -- \
        chroot /host \
        crictl checkpoint \
        --export="$OUTFILE" \
        "$CID"
    then
        echo "Checkpoint failed."
        FAILED+=("$C")
        continue
    fi

    echo "Checkpoint created."

    echo "Verifying archive..."

    if ! oc exec -n default "$TMPPOD" -- \
        test -f "/host${OUTFILE}"
    then
        echo "Checkpoint archive not found."
        FAILED+=("$C")
        continue
    fi

    echo "Copying archive..."

    if oc cp \
        "default/${TMPPOD}:/host${OUTFILE}" \
        "./${POD}-${C}.tar"
    then
        echo "Downloaded: ${POD}-${C}.tar"
        SUCCESS+=("$C")
    else
        echo "Failed to copy archive."
        FAILED+=("$C")
    fi

done

echo
echo "================ Summary ================"

echo
echo "Successful (${#SUCCESS[@]}):"

if [[ ${#SUCCESS[@]} -eq 0 ]]; then
    echo "  none"
else
    printf '  %s\n' "${SUCCESS[@]}"
fi

echo
echo "Failed (${#FAILED[@]}):"

if [[ ${#FAILED[@]} -eq 0 ]]; then
    echo "  none"
else
    printf '  %s\n' "${FAILED[@]}"
fi

echo

if [[ ${#FAILED[@]} -gt 0 ]]; then
    exit 1
fi

exit 0
