#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Seeding writes; the service account is provisioned read-only so External
# Secrets can only read. Running under `openv` (op run --env-file=.env) puts its
# token in the environment and every write comes back "Couldn't update the
# item.", so drop it and authenticate as the human who owns the vault.
unset OP_SERVICE_ACCOUNT_TOKEN

# The vault name is the one owner value that cannot live in the vault, so the
# entrypoints hold it and this reads it back from them rather than keeping a
# second copy. Every entrypoint has to name the same vault.
resolve_vault() {
    local names count

    names="$(awk '/^  OP_VAULT: /{print $2}' \
        "$repo_root"/clusters/entrypoints/*/*/bootstrap.yaml 2>/dev/null | sort -u)"
    count="$(printf '%s' "$names" | grep -c . || true)"

    case "$count" in
        1) printf '%s' "$names" ;;
        0)
            printf 'error: no OP_VAULT found in %s/clusters/entrypoints/*/*/bootstrap.yaml\n' \
                "$repo_root" >&2
            printf '       set OP_VAULT to name the vault explicitly.\n' >&2
            return 1
            ;;
        *)
            printf 'error: entrypoints name %s different vaults:\n' "$count" >&2
            printf '%s\n' "$names" | sed 's/^/       /' >&2
            printf '       set OP_VAULT to pick one.\n' >&2
            return 1
            ;;
    esac
}

vault="${OP_VAULT:-$(resolve_vault)}"
op_stderr=

envs=(
    local
    staging
    production
)

fields=(
    cluster-zone
    gateway-lb-source-ranges
    txt-owner-id
    indexer-image-name
    cloudflare-api-token
    resend-smtp-password
    envio-token
    acme-email
    alert-email-to
    grafana-smtp-host
    grafana-smtp-user
    grafana-smtp-from-address
    grafana-admin-username
    grafana-admin-password
    chain-indexer-pg-password
    chain-indexer-pg-superuser-password
    chain-indexer-hasura-admin-secret
    pg-backup-destination
    pg-backup-region
)

# Read from `terraform output` in infra/<env> on every run, so the bucket can
# never drift from the one terraform created.
terraform_fields=(
    pg-backup-destination
    pg-backup-region
)

# Issued by a third party, or naming a person or a domain; only a human can
# supply them.
external_fields=(
    cluster-zone
    txt-owner-id
    indexer-image-name
    cloudflare-api-token
    resend-smtp-password
    envio-token
    acme-email
    alert-email-to
    grafana-smtp-host
    grafana-smtp-user
    grafana-smtp-from-address
)

# Same shape as lib.sh's select_target, over envs rather than <env>/<cluster>
# targets -- what gets seeded is an env's items, and every env shares a cluster.
select_env() {
    fzf --prompt="seed-vault > " --height='~40%' --no-multi <<<"$(printf '%s\n' "${envs[@]}")"
}

main() {
    local env_name matches picked field

    # One env, named or picked interactively.
    if [[ -n "${1:-}" ]]; then
        if ! printf '%s\n' "${envs[@]}" | grep -qx -- "$1"; then
            printf 'error: unknown env %s, expected one of: %s\n' "$1" "${envs[*]}" >&2
            exit 1
        fi
        envs=("$1")
    else
        picked="$(select_env)" || true
        if [[ -z "$picked" ]]; then
            printf 'usage: %s <env>   (one of: %s)\n' "$0" "${envs[*]}" >&2
            exit 1
        fi
        envs=("$picked")
    fi

    if ! op vault get "$vault" >/dev/null 2>&1; then
        printf 'error: cannot reach vault %s -- not signed in to op, or no access to it.\n' "$vault" >&2
        printf '       op must be authenticated: desktop app integration, op signin, or\n' >&2
        printf '       OP_SERVICE_ACCOUNT_TOKEN. A service account needs write access granted.\n' >&2
        exit 1
    fi

    for env_name in "${envs[@]}"; do
        resolve_terraform "$env_name"
        matches="$(count_items "$env_name")"
        case "$matches" in
            0) create "$env_name" ;;
            1) backfill "$env_name" ;;
            *)
                printf 'error: %d items titled %s in %s, refusing to guess.\n' \
                    "$matches" "$env_name" "$vault" >&2
                exit 1
                ;;
        esac
    done

    # Only the fields left on a placeholder actually need attention, so they are
    # marked rather than leaving the reader to check each one by hand.
    printf '\nfill in by hand, per item:\n'
    local placeholders=0
    for field in "${external_fields[@]}"; do
        if [[ "$(op read "op://$vault/${envs[0]}/$field" 2>/dev/null)" == REPLACE_ME-* ]]; then
            printf '    %s *\n' "$field"
            placeholders=$((placeholders + 1))
        else
            printf '    %s\n' "$field"
        fi
    done

    if [[ "$placeholders" -gt 0 ]]; then
        printf '\n* holds the REPLACE_ME placeholder (%d of %d)\n' \
            "$placeholders" "${#external_fields[@]}"
    fi
}

count_items() {
    op item list --vault "$vault" --format=json \
        | jq --arg title "$1" '[.[] | select(.title == $title)] | length'
}

create() {
    local env_name="$1" field
    local assignments=()

    for field in "${fields[@]}"; do
        assignments+=("${field}[password]=$(value_for "$env_name" "$field")")
    done

    attempt op_create "$env_name" "${assignments[@]}" \
        || fail_write "$env_name" create "${assignments[@]}"

    printf 'created  %s/%s with %d fields\n' "$vault" "$env_name" "${#fields[@]}"
}

backfill() {
    local env_name="$1" field current desired
    local assignments=()

    for field in "${fields[@]}"; do
        # Terraform-backed fields track terraform, so they are written only when
        # it disagrees with what the vault already holds -- rerunning with an
        # unchanged bucket writes nothing. When terraform could not be read an
        # existing value is kept and only a missing one is seeded, so the field
        # always exists for External Secrets.
        if is_terraform_field "$field"; then
            current="$(op read "op://$vault/$env_name/$field" 2>/dev/null || true)"
            if [[ "$tf_available" == yes ]]; then
                desired="$(value_for "$env_name" "$field")"
                [[ "$current" == "$desired" ]] && continue
                assignments+=("${field}[password]=$desired")
            elif [[ -z "$current" ]]; then
                assignments+=("${field}[password]=$(value_for "$env_name" "$field")")
            fi
            continue
        fi

        op read "op://$vault/$env_name/$field" >/dev/null 2>&1 && continue
        assignments+=("${field}[password]=$(value_for "$env_name" "$field")")
    done

    if [[ ${#assignments[@]} -eq 0 ]]; then
        printf 'ok       %s/%s, all %d fields present\n' "$vault" "$env_name" "${#fields[@]}"
        return
    fi

    attempt op_edit "$env_name" "${assignments[@]}" \
        || fail_write "$env_name" edit "${assignments[@]}"

    printf 'updated  %s/%s, wrote %d field(s)\n' "$vault" "$env_name" "${#assignments[@]}"
}

op_create() {
    local env_name="$1"
    shift
    op item create --vault "$vault" --category "Secure Note" --title "$env_name" "$@" >/dev/null
}

op_edit() {
    local env_name="$1"
    shift
    op item edit "$env_name" --vault "$vault" "$@" >/dev/null
}

# Runs one op write and parks its stderr in op_stderr instead of letting it
# stream out bare.
attempt() {
    local status=0

    op_stderr="$("$@" 2>&1)" || status=$?
    return "$status"
}

# op says only "Couldn't update the item." -- no item, no field, no reason. This
# names both, and when a multi-field write fails it replays the assignments one
# at a time to point at the field op actually rejects. The writes that do land
# stay landed, which is what a rerunnable seeder wants anyway. Values are never
# printed; only field names.
fail_write() {
    local env_name="$1" action="$2"
    shift 2
    local assignments=("$@") one names=()

    for one in "${assignments[@]}"; do
        names+=("${one%%\[*}")
    done

    printf 'error: op could not %s %s/%s\n' "$action" "$vault" "$env_name" >&2
    printf '       fields: %s\n' "${names[*]}" >&2
    [[ -n "$op_stderr" ]] && printf '%s\n' "$op_stderr" | sed 's/^/       op: /' >&2

    if [[ "$action" == edit && ${#assignments[@]} -gt 1 ]]; then
        printf '\n       retrying one field at a time:\n' >&2
        for one in "${assignments[@]}"; do
            if attempt op_edit "$env_name" "$one"; then
                printf '         wrote    %s\n' "${one%%\[*}" >&2
            else
                printf '         rejected %s\n' "${one%%\[*}" >&2
                [[ -n "$op_stderr" ]] && printf '%s\n' "$op_stderr" \
                    | sed 's/^/           op: /' >&2
            fi
        done
    fi

    printf '\n       writing as: %s\n' "$(op whoami 2>/dev/null | tr '\n' ' ' | tr -s ' ' || true)" >&2
    printf '       op vault get only proves read access, so a write can still fail on:\n' >&2
    printf '         - read-only access to %s for that account\n' "$vault" >&2
    printf '         - an expired session: op whoami, then op signin\n' >&2
    printf '         - a field label that collides with an existing one on the item\n' >&2
    printf '       inspect: op item get %s --vault %s --format=json\n' "$env_name" "$vault" >&2
    exit 1
}

is_terraform_field() {
    local field
    for field in "${terraform_fields[@]}"; do
        [[ "$1" == "$field" ]] && return 0
    done
    return 1
}

# Sets tf_available, tf_destination and tf_region for one env. Never fatal: an
# env with no terraform (local) or unreachable state leaves whatever the vault
# already holds.
resolve_terraform() {
    local env_name="$1" dir="$repo_root/infra/$1"

    tf_available=no
    tf_destination=
    tf_region=

    [[ -f "$dir/main.tf" ]] || return 0

    # `terraform output -raw` exits 0 and prints nothing when there is no state,
    # so an empty value has to count as unreadable or the vault gets "".
    tf_destination="$(terraform -chdir="$dir" output -raw pg_backups_destination 2>/dev/null)" || true
    tf_region="$(terraform -chdir="$dir" output -raw pg_backups_region 2>/dev/null)" || true

    if [[ -z "$tf_destination" || -z "$tf_region" ]]; then
        printf 'skipped  %s/%s pg-backup-*, no terraform output in infra/%s (apply it first)\n' \
            "$vault" "$env_name" "$env_name"
        return 0
    fi

    tf_available=yes
}

value_for() {
    local env_name="$1" field="$2"

    case "$field" in
        cluster-zone|txt-owner-id|indexer-image-name|cloudflare-api-token|resend-smtp-password|envio-token|acme-email|alert-email-to|grafana-smtp-host|grafana-smtp-user|grafana-smtp-from-address)
            printf 'REPLACE_ME-%s-%s' "$env_name" "$field"
            ;;
        grafana-admin-username)
            printf 'admin'
            ;;
        gateway-lb-source-ranges)
            printf '["0.0.0.0/0"]'
            ;;
        pg-backup-destination)
            if [[ "$tf_available" == yes ]]; then printf '%s' "$tf_destination"
            else printf 'REPLACE_ME-%s-%s' "$env_name" "$field"; fi
            ;;
        pg-backup-region)
            if [[ "$tf_available" == yes ]]; then printf '%s' "$tf_region"
            else printf 'REPLACE_ME-%s-%s' "$env_name" "$field"; fi
            ;;
        *)
            generate
            ;;
    esac
}

# Alphanumeric only: chain-indexer-pg-password is interpolated raw into
# HASURA_GRAPHQL_DATABASE_URL, where + / = @ : would corrupt the URI.
generate() {
    local raw
    raw="$(head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
    printf '%s' "${raw:0:32}"
}

main "$@"
