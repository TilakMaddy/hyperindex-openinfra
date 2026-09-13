#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Releases every cloud resource the cluster created outside Terraform -- the NLB
# behind the gateway and the EBS volumes behind each PVC -- so terraform destroy
# can take the rest. It does not unwind the Flux stages one by one: waiting on each
# inventory to be garbage-collected is what used to hang, and none of it matters
# once the nodes are gone.

# Namespaces the platform and its apps create. kube-system and flux-system are
# left alone: the first runs aws-cloud-controller-manager and ebs-csi-controller,
# which are what release the NLB and the volumes.
namespaces=(platform-system chain-indexer alloy-system cert-manager-system cnpg-system envoy-gateway-system external-dns-system external-secrets-system grafana-system keel-system kyverno-system loki-system prometheus-system reloader-system tempo-system)

existing_namespaces() {
    local ns
    for ns in "${namespaces[@]}"; do
        kc get namespace "$ns" >/dev/null 2>&1 && printf '%s\n' "$ns"
    done
}

# Suspending Kustomizations does not stop helm-controller correcting drift in
# the HelmReleases they applied, so both are suspended.
halt_reconciliation() {
    local ns

    fx suspend source git flux-system || true
    fx suspend kustomization --all -n flux-system || true

    for ns in $(kc get helmreleases -A --no-headers -o custom-columns=NS:.metadata.namespace 2>/dev/null | sort -u); do
        fx suspend helmrelease --all -n "$ns" || true
    done
}

# With every operator and controller at zero replicas, nothing is left to
# recreate a workload, a PVC or the gateway's Service once they are deleted.
# Operators such as CNPG create bare pods, so those are deleted outright.
stop_workloads() {
    local ns targets

    # Scale every controller down first, across all namespaces, before deleting
    # any pod. Doing both per-namespace in one loop let an operator in a
    # not-yet-processed namespace (CNPG, grafana) recreate a pod that then pins
    # its PVC open with pvc-protection -- the PV never releases and the wait loop
    # hangs until it times out. `scale --replicas=0 <names>` (not `--all`) avoids
    # the "no objects passed to scale" abort in a namespace with only a DaemonSet.
    for ns in $(existing_namespaces); do
        targets="$(kc get deployment,statefulset -n "$ns" -o name 2>/dev/null)"
        [[ -n "$targets" ]] && kc scale --replicas=0 -n "$ns" $targets >/dev/null
    done

    # Nothing is left to recreate them now, so deleted pods stay gone -- including
    # the bare pods operators like CNPG create.
    for ns in $(existing_namespaces); do
        log "  $ns"
        kc delete pod --all -n "$ns" --grace-period=5 --wait=false >/dev/null
    done
}

# The operators are down, so a failurePolicy: Fail webhook pointing at one of
# them would reject every delete that follows.
remove_platform_webhooks() {
    local ns_json kind name

    ns_json="$(printf '%s\n' "${namespaces[@]}" | jq -R . | jq -sc .)"

    for kind in validatingwebhookconfigurations mutatingwebhookconfigurations; do
        kc get "$kind" -o json \
            | jq -r --argjson ns "$ns_json" \
                '.items[] | select(any(.webhooks[]?; .clientConfig.service.namespace as $n | $ns | index($n))) | .metadata.name' \
            | while read -r name; do
                log "  $kind/$name"
                kc delete "$kind" "$name" --wait=false >/dev/null
            done
    done
}

# envoy-gateway is scaled down, so deleting its Service is no longer a race it
# wins by rebuilding it; the cloud controller manager releases the NLB.
delete_cloud_resources() {
    local ns name

    kc get svc --all-namespaces \
        -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
        | while read -r ns name; do
            [[ -n "${name:-}" ]] || continue
            log "  LoadBalancer $ns/$name"
            kc delete svc "$name" -n "$ns" --wait=false >/dev/null
        done

    kc delete pvc --all --all-namespaces --wait=false
}

# terraform destroy removes the nodes running ebs-csi-controller and
# aws-cloud-controller-manager. Once they are gone nothing is left to release the
# EBS volumes or the ELB, so refuse to hand back until the cluster shows none.
assert_cloud_resources_released() {
    local deadline pvs lbs

    deadline=$(( $(date +%s) + 900 ))

    while :; do
        if ! pvs="$(kc get pv -o name --request-timeout=60s | grep -c . || true)"; then
            printf 'error: unable to list PersistentVolumes\n' >&2
            return 1
        fi
        if ! lbs="$(kc get svc --all-namespaces --request-timeout=60s \
            -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}{"\n"}{end}' \
            | grep -c . || true)"; then
            printf 'error: unable to list Services\n' >&2
            return 1
        fi

        if [[ "$pvs" == "0" && "$lbs" == "0" ]]; then
            log "  no PersistentVolumes, no LoadBalancer Services"
            return 0
        fi

        if (( $(date +%s) > deadline )); then
            printf 'error: cloud resources still present after 15m: %s PersistentVolume(s), %s LoadBalancer Service(s)\n' \
                "$pvs" "$lbs" >&2
            printf 'error: NOT safe for terraform destroy -- EBS volumes or an ELB would be orphaned\n' >&2
            kc get pv,pvc -A 2>&1 >&2 || true
            return 1
        fi

        log "  waiting: $pvs PersistentVolume(s), $lbs LoadBalancer Service(s) remaining"
        sleep 10
    done
}

main() {
    local start_epoch end_epoch elapsed

    resolve_target "${1:-}" destroy

    if ! kc version --request-timeout=30s >/dev/null 2>&1; then
        printf 'error: cannot reach the cluster at %s\n' "$cluster_kubeconfig" >&2
        exit 1
    fi

    start_epoch=$(date +%s)
    log "Target:     $env_name/$cluster"
    log "Kubeconfig: $cluster_kubeconfig"

    log "Suspending flux -- the git source, every Kustomization and every HelmRelease"
    halt_reconciliation

    log "Scaling platform workloads to zero"
    stop_workloads

    log "Removing admission webhooks served by the stopped operators"
    remove_platform_webhooks

    log "Deleting LoadBalancer Services and PVCs"
    delete_cloud_resources

    log "Waiting for the NLB and EBS volumes to be released"
    assert_cloud_resources_released

    end_epoch=$(date +%s)
    elapsed=$(( end_epoch - start_epoch ))
    log "Elapsed:    $((elapsed / 60))m $((elapsed % 60))s"
    log "Cloud resources released. Safe to run terraform destroy"
}

main "$@"
