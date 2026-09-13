FluxCD entrypoints for various clusters.

Each `<env>/<cluster>` holds two files:

| file | |
|---|---|
| `bootstrap.yaml` | `platform-vars` — the vault name, vault paths and platform wiring, plus the layer-zero source and Kustomization |
| `main.yaml` | `cluster-vars` — vault paths and tunables, plus the common and apps Kustomizations |

Everything an owner picks lives in 1Password, not here: the zone, the external-dns
owner id, the indexer image, the emails and SMTP settings, the Postgres backup
destination. `just seed-vault` creates the fields; External Secrets pulls them
into `platform-secret-vars` and `cluster-secret-vars`, and flux substitutes from
those Secrets.

The vault name is the exception, because it cannot come from the vault — it is
what tells External Secrets which vault to open. It lives as `OP_VAULT` in
`bootstrap.yaml`, and `scripts/seed-vault.sh` reads it back from there rather than
keeping a copy.

`OP_VAULT_*` values are addresses inside that vault. Their field names are fixed
by `scripts/seed-vault.sh`; only the `<env>/` prefix is yours to pick.

`chain-indexer-vars` and the `cluster-secret-vars` ExternalSecret live in
`clusters/common`.

Run it with:

    cd infra/<env> && just apply
    just seed-vault <env>/<cluster>   # then fill the REPLACE_ME fields in 1Password
    just bootstrap <env>/<cluster>

Omit the target from either and you get an fzf picker over the entrypoints that exist.

`just seed-vault` is idempotent — rerun it after `terraform apply` to refresh the
backup destination and region, which it reads from `terraform output`.
