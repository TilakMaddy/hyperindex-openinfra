# shellcheck shell=bash
# Shared helpers for the scripts in this directory. Meant to be sourced, not executed.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The ConfigMap Flux substitutes APP_CHAIN_INDEXER_* from. Scripts read names out
# of it rather than repeating them, so a rename there reaches them too.
# shellcheck disable=SC2034 # used by the scripts that source this file
chain_indexer_config="$repo_root/clusters/common/chain-indexer-config.yaml"

# Prints the value of a top-level "  KEY: value" data entry, first match across
# the given files. Fails loudly when it is missing, so a renamed key is caught
# instead of silently becoming an empty string.
yaml_var() {
    local key="$1" val
    shift
    val="$(awk -v k="  $key: " 'index($0, k) == 1 {gsub(/"/, "", $2); print $2}' "$@" 2>/dev/null | head -1)"
    if [[ -z "$val" ]]; then
        printf 'error: %s not found in %s\n' "$key" "$*" >&2
        return 1
    fi
    printf '%s' "$val"
}
# Path of the flux entrypoints, both relative to the repo root -- which is what
# flux bootstrap --path wants -- and absolute, for walking it locally. Every
# entrypoint lives at <entrypoints_path>/<env>/<cluster>.
entrypoints_path="clusters/entrypoints"
entrypoints_dir="$repo_root/$entrypoints_path"

# Every clusters/entrypoints/<env>/<cluster> directory is a target, printed in
# the "<env>/<cluster>" form the scripts take as their argument. An env holding
# no cluster directory -- local/ with just a README, say -- contributes nothing.
discover_targets() {
    local env_dir cluster_dir
    for env_dir in "$entrypoints_dir"/*/; do
        [[ -d "$env_dir" ]] || continue
        for cluster_dir in "$env_dir"*/; do
            [[ -d "$cluster_dir" ]] || continue
            printf '%s/%s\n' "$(basename "$env_dir")" "$(basename "$cluster_dir")"
        done
    done
}

select_target() {
    local prompt="$1" targets
    targets="$(discover_targets)"

    if [[ -z "$targets" ]]; then
        printf 'error: no targets found under %s\n' "$entrypoints_dir" >&2
        return 1
    fi

    fzf --prompt="$prompt > " --height='~40%' --no-multi <<<"$targets"
}

# Prints the <env>/<cluster> an <env>[/<cluster>] argument names -- or an
# interactive pick when it is omitted -- for the scripts that need an entrypoint
# but no kubeconfig. An env on its own -- "staging" -- is accepted when it holds
# exactly one cluster, which is the common case; anything ambiguous has to name
# the cluster.
pick_target() {
    local target="$1" prompt="$2" matches

    if [[ -z "$target" ]]; then
        target="$(select_target "$prompt")" || true
        if [[ -z "$target" ]]; then
            printf 'usage: %s <env>[/<cluster>]\n' "$0" >&2
            return 1
        fi
    elif [[ "$target" != */* ]]; then
        matches="$(discover_targets | awk -v e="$target" -F/ '$1 == e')"
        case "$(printf '%s' "$matches" | grep -c . || true)" in
            1) target="$matches" ;;
            0)
                printf 'error: no clusters under env %q\n' "$target" >&2
                printf 'known targets:\n' >&2
                discover_targets | sed 's/^/  /' >&2
                return 1
                ;;
            *)
                printf 'error: env %q holds more than one cluster, name one:\n' "$target" >&2
                printf '%s\n' "$matches" | sed 's/^/  /' >&2
                return 1
                ;;
        esac
    fi

    if [[ ! -d "$entrypoints_dir/$target" ]]; then
        printf 'error: no entrypoint for %q at %s\n' "$target" "$entrypoints_dir/$target" >&2
        return 1
    fi

    printf '%s' "$target"
}

# Turns an <env>/<cluster> argument -- or an interactive pick when it is omitted
# -- into the env_name, cluster, cluster_path (the flux bootstrap --path) and
# cluster_kubeconfig the scripts run against. The mode -- "bootstrap" or
# "destroy" -- doubles as the picker prompt and decides whether the entrypoint
# has to exist already: destroy needs one, bootstrap creates it.
#
# The kubeconfig is derived, not configured: infra/<env>/.kube/<cluster>.config,
# or ~/.kube/config for the local env. Set KUBECONFIG_PATH_<env>_<cluster>, with
# every '-' written as '_', to override that for one target.
resolve_target() {
    local arg="$1" mode="$2" target override_var

    if [[ -n "$arg" ]]; then
        target="$arg"
    else
        target="$(select_target "$mode")" || true
        if [[ -z "$target" ]]; then
            printf 'usage: %s <env>/<cluster>\n' "$0" >&2
            exit 1
        fi
    fi

    env_name="${target%%/*}"
    cluster="${target#*/}"

    if [[ "$target" != */* || -z "$env_name" || -z "$cluster" || "$cluster" == */* ]]; then
        printf 'error: target %q is not in <env>/<cluster> form\n' "$target" >&2
        printf 'usage: %s <env>/<cluster>   (e.g. staging/us-west-2-aws-backoffice-dataplane)\n' "$0" >&2
        exit 1
    fi

    cluster_path="$entrypoints_path/$env_name/$cluster"

    # Only destroy insists on an entrypoint that is already there. Bootstrapping
    # a cluster for the first time is exactly the case where it is not, so the
    # directory gets created instead.
    if [[ "$mode" != bootstrap && ! -d "$repo_root/$cluster_path" ]]; then
        printf 'error: no entrypoint for %q at %s\n' "$target" "$repo_root/$cluster_path" >&2
        exit 1
    fi

    override_var="KUBECONFIG_PATH_${env_name//-/_}_${cluster//-/_}"
    cluster_kubeconfig="${!override_var:-}"

    if [[ -z "$cluster_kubeconfig" ]]; then
        if [[ "$env_name" == "local" ]]; then
            cluster_kubeconfig="$HOME/.kube/config"
        else
            cluster_kubeconfig="$repo_root/infra/$env_name/.kube/$cluster.config"
        fi
    fi

    if [[ ! -f "$cluster_kubeconfig" ]]; then
        printf 'error: kubeconfig for %q not found at %s\n' "$target" "$cluster_kubeconfig" >&2
        if [[ "$env_name" != "local" ]]; then
            printf 'error: fetch it with "cd %s/infra/%s && just fetch-config %s"\n' \
                "$repo_root" "$env_name" "$cluster" >&2
        fi
        printf 'error: or set %s to point somewhere else\n' "$override_var" >&2
        exit 1
    fi
}

# Prints the "<owner> <repository> <branch>" flux bootstrap pushes to: owner and
# repository off the origin remote, in either the git@github.com:owner/repo.git
# or the https://github.com/owner/repo.git form, and the branch this working
# tree is on. Read it back with:
#   read -r owner repository branch <<<"$(resolve_origin)"
resolve_origin() {
    local url path owner repository branch

    url="$(git -C "$repo_root" remote get-url origin)" || return 1

    if [[ "$url" != *github.com* ]]; then
        printf 'error: origin %q is not a github.com remote, which flux bootstrap github requires\n' "$url" >&2
        return 1
    fi

    path="${url#*github.com}"   # drop the scheme and host
    path="${path#[:/]}"         # scp-like uses ':', url form uses '/'
    path="${path%.git}"

    owner="${path%%/*}"
    repository="${path#*/}"

    if [[ -z "$owner" || -z "$repository" || "$repository" == */* || "$owner" == "$repository" ]]; then
        printf 'error: cannot read owner/repository out of origin url %q\n' "$url" >&2
        return 1
    fi

    branch="$(git -C "$repo_root" rev-parse --abbrev-ref HEAD)" || return 1

    if [[ -z "$branch" || "$branch" == HEAD ]]; then
        printf 'error: cannot determine the current branch of %s (detached HEAD?)\n' "$repo_root" >&2
        return 1
    fi

    printf '%s %s %s\n' "$owner" "$repository" "$branch"
}

log() {
    printf '==> %s\n' "$*"
}

# Both scripts talk to the cluster resolve_target picked, never to the ambient
# kubeconfig context.
kc() {
    kubectl --kubeconfig="$cluster_kubeconfig" "$@"
}

fx() {
    flux --kubeconfig="$cluster_kubeconfig" "$@"
}
