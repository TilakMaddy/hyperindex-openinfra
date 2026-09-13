#!/usr/bin/env bash
set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=lib.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

# Everything printed here is read from the vault, so this deliberately does not
# use resolve_target: that insists on a kubeconfig, and there is no reason to
# have fetched one just to look up a URL and a password.
target="$(pick_target "${1-}" show-details)"
env_name="${target%%/*}"
entrypoint="$entrypoints_dir/$target"

# The op:// references are read back out of the entrypoint rather than repeated
# here, so a renamed vault item only has to change in one place.
op_ref() {
    local key="$1" ref
    ref="$(awk -v k="  $1: " 'index($0, k) == 1 {print $2}' \
        "$entrypoint"/bootstrap.yaml "$entrypoint"/main.yaml 2>/dev/null | head -1)"
    if [[ -z "$ref" ]]; then
        printf 'error: %s not found in %s/{bootstrap,main}.yaml\n' "$key" "$entrypoint" >&2
        return 1
    fi
    printf 'op://%s/%s' "$vault" "$ref"
}

vault="$(awk '/^  OP_VAULT: /{print $2}' "$entrypoint"/bootstrap.yaml)"
if [[ -z "$vault" ]]; then
    printf 'error: no OP_VAULT in %s/bootstrap.yaml\n' "$entrypoint" >&2
    exit 1
fi

zone="$(op read "$(op_ref OP_VAULT_CLUSTER_ZONE)")"
grafana_user="$(op read "$(op_ref OP_VAULT_GRAFANA_ADMIN_USER)")"
grafana_pass="$(op read "$(op_ref OP_VAULT_GRAFANA_ADMIN_PASSWORD)")"
hasura_secret="$(op read "$(op_ref OP_VAULT_CHAIN_INDEXER_HASURA_ADMIN_SECRET)")"
pg_pass="$(op read "$(op_ref OP_VAULT_CHAIN_INDEXER_PG_SUPERUSER_PASSWORD)")"

pg_pass_enc="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$pg_pass")"

# Only the staging ACME endpoint issues from a root nothing trusts. Production
# chains to the public Let's Encrypt root, so pinning a CA there is wrong: every
# client already trusts it, and the staging root would reject the certificate.
acme_env="$(awk '/^  ACME_ENV: /{print $2}' "$entrypoint"/bootstrap.yaml)"
if [[ "$acme_env" == "staging" ]]; then
    ca="$repo_root/clusters/tests/stg-root-x1.pem"
else
    # Not empty: libpq reads ~/.postgresql/root.crt when sslrootcert is unset,
    # which exists on almost no machine. "system" is the explicit opt-in to the
    # trust store the public Let's Encrypt root already lives in.
    ca=system
fi

db_name="$(yaml_var APP_CHAIN_INDEXER_DB_NAME "$chain_indexer_config")"
hasura_hostname="$(yaml_var APP_CHAIN_INDEXER_HASURA_HOSTNAME "$chain_indexer_config")"
pg_hostname="$(yaml_var APP_CHAIN_INDEXER_PG_HOSTNAME "$chain_indexer_config")"

printf '%s (%s)\n\n' "$target" "$zone"

printf 'PLATFORM (shared by every app on this cluster)\n\n'

printf '  GRAFANA\n'
printf '    url:      https://grafana.%s\n' "$zone"
printf '    username: %s\n' "$grafana_user"
printf '    password: %s\n\n' "$grafana_pass"

printf 'APP: chain-indexer\n\n'

printf '  HASURA\n'
printf '    console:  https://%s.%s/console\n' "$hasura_hostname" "$zone"
printf '    graphql:  https://%s.%s/v1/graphql\n' "$hasura_hostname" "$zone"
printf '    password: %s   (admin secret -- hasura has no usernames)\n\n' "$hasura_secret"

pg_endpoint() {
    local label="$1" host="$2.$zone"
    local url="postgresql://postgres:$pg_pass_enc@$host:5432/$db_name?sslmode=verify-full"

    printf '    %s\n' "$label"
    printf '      host:     %s\n' "$host"
    printf '      import:   %s\n' "$url"
    printf '      shell:    psql "%s&sslrootcert=%s"\n\n' "$url" "$ca"
}

printf '  POSTGRES\n'
printf '    port:     5432\n'
printf '    database: %s\n' "$db_name"
printf '    username: postgres  (SUPERUSER -- unrestricted on every database)\n'
printf '    password: %s\n' "$pg_pass"
printf '    ssl mode: verify-full\n'
if [[ "$ca" == system ]]; then
    printf '    ssl ca:   system trust store (sslrootcert=system)\n\n'
else
    printf '    ssl ca:   %s\n\n' "$ca"
fi

pg_endpoint 'READ-WRITE (primary)' "$pg_hostname-rw"
pg_endpoint 'READ-ONLY (replicas -- writes are rejected)' "$pg_hostname-ro"

if [[ "$ca" != system ]]; then
    printf 'note:       certificates chain to the Let'"'"'s Encrypt STAGING root, so browsers\n'
    printf '            warn and curl/psql need the CA above.\n'
fi

if [[ "$env_name" == "local" ]]; then
    printf 'note:       kind publishes LoadBalancer ports on 127.0.0.1, so these hostnames\n'
    printf '            are not reachable from off this machine.\n'
fi
