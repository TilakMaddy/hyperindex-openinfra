# Setup guide

From nothing to a running indexer: a [Talos](https://www.talos.dev/) Kubernetes cluster on
EC2, with Postgres, Hasura, your indexer, TLS, DNS, dashboards and alerts on your own
domain. See the [README](README.md) for what the stack is.

Every step says what to run, what you end up with, and how to check it before moving on.

| | where | |
|---|---|---|
| Before you start | your laptop, GitHub | tools, accounts, your copy of this repo, your indexer image |
| Phase 1 | `infra/staging` | Terraform builds the cluster and the backup bucket |
| Phase 2 | `clusters` | 1Password holds the secrets, Flux converges everything else |

Use two terminals, one in `infra/staging` and one in `clusters`. Phase 2 reads Terraform's
outputs, so finish Phase 1 first.

Everything is written for the `staging` environment and the cluster that ships with it,
`us-west-2-aws-backoffice-dataplane`. Stay on the `staging` branch throughout.
[Doing it again for production](#doing-it-again-for-production) covers the second
environment.

## Before you start

### 1. Install the tools

```sh
brew install terraform awscli just jq fzf kubectl helm \
  fluxcd/tap/flux 1password-cli siderolabs/tap/talosctl
```

**Check:** `just --list` works in both `infra/staging` and `clusters`.

### 2. Get the accounts

All six, before you start. Phase 2 stalls without any one of them.

| | for |
|---|---|
| An AWS account, with a profile that can create VPC, EC2, S3 and IAM resources | Phase 1 |
| A GitHub account | your copy of this repo, which Flux pushes to |
| A 1Password account, one vault, and a service account token | every secret the cluster reads |
| A DNS zone on Cloudflare | `grafana.<zone>`, `hasura-chain-indexer.<zone>`, `postgres-chain-indexer-rw.<zone>` and `-ro` |
| A HyperSync API token from [envio.dev/app/api-tokens](https://envio.dev/app/api-tokens) | the indexer |
| An SMTP sender such as [Resend](https://resend.com) | Grafana alert email |

### 3. Make your own copy of this repo

Flux commits to the repo it bootstraps, so take a template copy rather than cloning this
one.

```sh
gh repo create <you>/<your-indexer-infra> \
  --template TilakMaddy/hyperindex-openinfra --private --clone --include-all-branches
cd <your-indexer-infra>
```

On GitHub instead: Use this template → Create a new repository, tick Include all branches.

**Result:** your own repo, cloned, with the `dev`, `staging` and `production` branches.

**Check:** `git branch -a` lists all three, and `git remote -v` shows a github.com URL.
`flux bootstrap github` needs that host, and the branch you bootstrap from has to exist on
the remote. If the copy brought only one branch:

```sh
git checkout -b staging && git push -u origin staging
git checkout -b production && git push -u origin production
```

### 4. Build your indexer image

The image is yours: your `config.yaml`, your `schema.graphql`, your handlers. This repo
does not contain one.

Start from **https://github.com/TilakMaddy/my-envio-indexer**, a stock `envio init`
scaffold plus a `Dockerfile`, a `.dockerignore`, a `justfile`, and a
`.github/workflows/release.yml` that builds amd64 and arm64 and pushes to GHCR on every
branch update. If you already have an indexer repo, copy those four files into it.

**Result:** an image ref such as `ghcr.io/<you>/my-envio-indexer:latest`. Phase 2 asks for
this exact string.

Two things the cluster requires of it. The image has to be pullable without credentials,
since no `imagePullSecret` is configured, so make the GHCR package public. And the tag has
to be one you keep pushing to, because Keel watches that tag and rolls the indexer forward
when the digest changes.

If you build an image without that template, it also has to serve `/healthz` and
`/metrics` on port 9898 and read its config from the environment. The manifest at
`clusters/apps/chain-indexer/04-indexer/indexer.yaml` supplies `ENVIO_PG_*`,
`ENVIO_HASURA`, `HASURA_GRAPHQL_ENDPOINT` / `_ROLE` / `_ADMIN_SECRET`, `ENVIO_API_TOKEN`
and `ENVIO_INDEXER_PORT`.

## Phase 1: stand up the infrastructure

Terminal A.

```sh
cd infra/staging
```

### 1.1 Point Terraform at your AWS account

```sh
cp .env.sample .env
$EDITOR .env
```

Put whichever `AWS_*` variables your setup needs in there. `.env.sample` shows the
`AWS_PROFILE` + `credential_process` pattern; a plain `AWS_PROFILE=` or static keys work
too. The justfile loads the file itself.

**Check:** `aws sts get-caller-identity` prints the account you expect.

### 1.2 Describe the cluster you want

```sh
$EDITOR main.tf config.json
```

Set three values in `main.tf`'s `locals` block:

| | |
|---|---|
| `cluster_name` | the cluster key in `config.json` |
| `region` | the cluster's region |
| `pg_backups_bucket` | change it. Bucket names are global, so `oatlabs-backoffice-pg-backups-staging` is taken. `pg_backups_replica_bucket` derives from it, so it follows |
| `replica_region` | where backups are replicated to. Anything but `region` |

Then in `config.json`: `region`, `vpc_cidr`, the subnet/AZ map, and each node's
`instance_type` and `root_volume_size`. Change the sizes freely, but keep these five
workers, because manifests select on them:

- one with `"roles": ["general"]`, for the indexer and Hasura
- three with `"roles": ["postgres"]` and the
  `node-role.kubernetes.io/postgres:NoSchedule` registration taint, for Postgres.
  `main.tf` attaches the backup-bucket IAM policy to these by the names in
  `local.postgres_nodes`
- one with `"roles": ["observability"]` and its matching taint, for Grafana, Prometheus
  and Loki

Sizing and adding nodes are covered in
[`infra/staging/README.md`](infra/staging/README.md).

**Result:** a config for your cluster. The cluster key is the name every later command
uses, so if you change it, rename
`clusters/entrypoints/staging/us-west-2-aws-backoffice-dataplane/` to match.

### 1.3 Build it

```sh
just apply
```

Takes about 10 minutes. It ends with `fetch-configs`, which writes the credentials for
every cluster in `config.json`.

**Result:** the VPC, the Talos cluster, the backup bucket and its cross-region replica,
and two files Phase 2 finds by path, so leave them where they are:

```
.kube/us-west-2-aws-backoffice-dataplane.config      # kubectl
.talos/us-west-2-aws-backoffice-dataplane.config     # talosctl
```

To fetch them again later without an apply:
`just fetch-config us-west-2-aws-backoffice-dataplane`.

### 1.4 Confirm the cluster is up

```sh
export KUBECONFIG=.kube/us-west-2-aws-backoffice-dataplane.config
kubectl get nodes
terraform output pg_backups_destination
```

**Check:** every control-plane and worker node is `Ready`, and the output is an `s3://…`
URL.

`seed-vault` reads that bucket URL out of `terraform output` in Phase 2, so this apply has
to have succeeded first, and Phase 2 has to run on this machine, since the state file is
local and gitignored.

## Phase 2: bring up the cluster

Terminal B.

```sh
cd clusters
```

### 2.1 Supply the two tokens

```sh
cp .env.sample .env
$EDITOR .env
set -a && source .env && set +a
```

| | |
|---|---|
| `GITHUB_TOKEN` | a PAT with `repo` scope on your copy of this repo |
| `OP_SERVICE_ACCOUNT_TOKEN` | a 1Password service account token with read access to your vault. External Secrets uses it to pull every other secret |

The `clusters` justfile does not load `.env`, hence the `source`. If you keep `op://`
references in it, prefix the later commands with `op run --env-file=.env --` instead.

**Check:** `echo ${GITHUB_TOKEN:+set} ${OP_SERVICE_ACCOUNT_TOKEN:+set}` prints `set set`.

### 2.2 Point the entrypoint at your vault

```sh
$EDITOR entrypoints/staging/us-west-2-aws-backoffice-dataplane/bootstrap.yaml
$EDITOR entrypoints/staging/us-west-2-aws-backoffice-dataplane/main.yaml
```

In `bootstrap.yaml`:

| | |
|---|---|
| `OP_VAULT` | your vault's name. Ships as `MyIndexer`, so name your vault that or change it here. Every entrypoint has to name the same vault |
| `ACME_ENV` | `staging` while testing, `production` for real certificates. Let's Encrypt rate-limits production issuance |
| `GRAFANA_ALLOWED_CIDRS` | who may reach Grafana. Ships as `'["0.0.0.0/0"]'` |

In `main.yaml`: `CHAIN_INDEXER_HASURA_ALLOWED_CIDRS` and
`CHAIN_INDEXER_PG_ALLOWED_PRINCIPALS`, who may reach the GraphQL and Postgres endpoints.
Both also ship wide open. The gateway denies everything not on these three lists.

**Result:** an entrypoint pointing at your vault. Its directory name has to match the
cluster key from 1.2, which is how the kubeconfig path is derived. The `OP_VAULT_*` values
are addresses inside the vault; `seed-vault` fixes the field names, and only the
`staging/` prefix is yours. See
[`clusters/entrypoints/README.md`](clusters/entrypoints/README.md).

### 2.3 Commit and push the entrypoint

```sh
cd ..
git add clusters/entrypoints/staging infra/staging/config.json infra/staging/main.tf
git commit -m "staging: point the entrypoint at my vault and cluster"
git push origin staging
cd clusters
```

Flux reconciles the repository, not your working tree, and `just bootstrap` commits only
the `flux-system` directory it generates. Skip this and the cluster comes up against the
template's defaults: the `MyIndexer` vault name and the wide-open CIDRs. Every later
config change needs a push too.

**Check:** `git status` is clean under `clusters/entrypoints/staging`.

### 2.4 Fill the vault

Sign in to `op` as yourself. Seeding writes, the service account is read-only, and the
script unsets `OP_SERVICE_ACCOUNT_TOKEN` before it runs.

```sh
op signin
just seed-vault staging
```

**Result:** a Secure Note titled `staging` in your vault with 18 fields, and a checklist of
the 11 that need you:

```
created  MyIndexer/staging with 18 fields

fill in by hand, per item:
    cluster-zone *
    txt-owner-id *
    ...
* holds the REPLACE_ME placeholder (11 of 11)
```

Open the item in 1Password and replace each `REPLACE_ME-…` value:

| field | what to put there |
|---|---|
| `cluster-zone` | the Cloudflare zone this cluster owns, for example `indexer.example.com`. It gets a wildcard certificate, so give each cluster its own zone or subdomain |
| `txt-owner-id` | any short string unique to this cluster, for example `staging-usw2`. external-dns writes it into its TXT records. Changing it later orphans the records the old id owned |
| `indexer-image-name` | the image ref from step 4, tag included |
| `cloudflare-api-token` | a token scoped to that zone with `Zone : DNS : Edit` and `Zone : Zone : Read`. See below |
| `envio-token` | your HyperSync API token |
| `acme-email` | your address on the Let's Encrypt account |
| `alert-email-to` | where Grafana sends alerts |
| `grafana-smtp-host` | `host:port`, port included, for example `smtp.resend.com:587`. StartTLS is mandatory, so use the submission port |
| `grafana-smtp-user` | the SMTP username. For Resend, `resend` |
| `grafana-smtp-from-address` | a From address on a domain your provider has verified. Unverified senders fail silently |
| `resend-smtp-password` | the SMTP password, which for Resend is an API key |

> The Cloudflare token needs write access. Make it at My Profile → API Tokens → Create
> Token, from the Edit zone DNS template, then set Zone Resources → Include → Specific
> zone → your zone. cert-manager writes a `_acme-challenge` TXT record with it and
> external-dns writes the hostname records. Without `DNS : Edit` the certificate never
> goes Ready and external-dns logs 403s; without `Zone : Read` it cannot find the zone.

Leave the other seven fields alone. `seed-vault` generated `grafana-admin-username`,
`grafana-admin-password`, `chain-indexer-pg-password`,
`chain-indexer-pg-superuser-password` and `chain-indexer-hasura-admin-secret`, and
`just show-details` reads them back when you need them. It copies `pg-backup-destination`
and `pg-backup-region` from `terraform output` on every run, so they always match the
bucket that exists.

**Check:** rerun `just seed-vault staging`. It prints
`ok       MyIndexer/staging, all 18 fields present` with no `*` lines. A
`skipped … pg-backup-*` line means it could not read Phase 1's Terraform state, so go back
to 1.4.

### 2.5 Hand the cluster to Flux

Both tokens from 2.1 have to be in this shell, and you have to be on the `staging` branch.
`bootstrap` takes the branch from your working tree, not from the target you type, and the
cluster follows that branch from then on.

```sh
git rev-parse --abbrev-ref HEAD     # must say: staging
just bootstrap staging/us-west-2-aws-backoffice-dataplane
```

Omit the target and you get an fzf picker over the entrypoints that exist.

**Result:** `OP_SERVICE_ACCOUNT_TOKEN` planted in the cluster as the `onepassword-token`
secret, Flux installed, and a `flux-system` commit pushed to your branch. Nothing else is
applied by hand from here.

### 2.6 Watch it converge

```sh
export KUBECONFIG=../infra/staging/.kube/us-west-2-aws-backoffice-dataplane.config
flux get kustomizations --watch
```

**Check:** six stages go Ready in order.

```
bootstrap → secrets → underlay → observability → common → apps
```

The first pass is slow, because it pulls every operator's chart and waits for cert-manager
to finish a DNS-01 challenge. If it sits on `underlay`, that is the certificate: check the
Cloudflare token's permissions and that `cluster-zone` is on the same Cloudflare account
as the token.

```sh
kubectl get certificate -A
flux get all -A --status-selector ready=false
```

## Verify

```sh
just show-details staging
```

Everything it prints is read live from 1Password, so it needs `op` but no kubeconfig. Pass
`<env>/<cluster>` instead if an env holds more than one cluster.

**Result:** every way into the cluster.

| | |
|---|---|
| Grafana | `https://grafana.<zone>` and the generated admin login |
| Hasura | the console and `/v1/graphql`. The admin secret is the API key, required on every request; Hasura has no usernames |
| Postgres | `-rw` and `-ro` hostnames, port 5432, database `indexer-db`, with a connection URI and a `psql` command for each |

Under `ACME_ENV: staging` the certificates chain to the Let's Encrypt staging root, so
browsers warn and `psql` needs the CA at `clusters/tests/stg-root-x1.pem`, which
`show-details` puts in the command for you. If a URL times out while the pods are healthy,
check the CIDR allowlists from 2.2.

**Check:** the indexer is advancing blocks.

```sh
kubectl -n chain-indexer get pods
kubectl -n chain-indexer logs sts/indexer -f
```

The chain-indexer folder in Grafana should be filling in. A `CrashLoopBackOff` here is
usually the image: either it is not public, or it is not listening on 9898.

## Doing it again for production

Same two phases, against `infra/production` and the `production` entrypoint, from the
`production` branch. Do it once staging is converging, since that is where you find out a
Cloudflare token is missing a permission, and Let's Encrypt rate-limits the production
endpoint.

| | staging | production |
|---|---|---|
| branch | `staging` | `production`, checked out before both phases |
| terraform | `infra/staging` | `infra/production`, its own `.env` and `config.json`, and another globally unique `pg_backups_bucket` |
| backup buckets | destroyed with the stack | both carry `prevent_destroy`, so `just destroy` fails instead of deleting them |
| vault | item `staging`, fields `staging/*` | a second item `production`, fields `production/*`, the same 11 values again |
| certificates | `ACME_ENV: staging` | `ACME_ENV: production`, already set there |
| DNS zone | its own | a different zone or subdomain. Sharing one means two external-dns instances writing the same records |
| `txt-owner-id` | its own | a different value again |
| sizing | `PG_STORAGE: 1Gi`, `PG_WAL_STORAGE: 1Gi`, retention `5d` | `PG_STORAGE: 20Gi`, `PG_WAL_STORAGE: 10Gi`, retention `30d`, already set there |
| allowlists | fine left open while you test | narrow all three to the addresses that should reach it |

```sh
git checkout production && git pull

# Phase 1 — terminal A
cd infra/production
cp .env.sample .env && $EDITOR .env        # AWS profile
$EDITOR main.tf config.json                # cluster_name, region, a unique pg_backups_bucket
just apply

# Phase 2 — terminal B, at the repo root, on the production branch
cd clusters
set -a && source .env && set +a
$EDITOR entrypoints/production/us-west-2-aws-backoffice-dataplane/bootstrap.yaml   # OP_VAULT, ACME_ENV
$EDITOR entrypoints/production/us-west-2-aws-backoffice-dataplane/main.yaml        # CIDRs, sizing

cd .. && git add -A && git commit -m "production: entrypoint" && git push origin production && cd clusters

just seed-vault production                 # then fill the eleven production/* fields
git rev-parse --abbrev-ref HEAD            # must say: production
just bootstrap production/us-west-2-aws-backoffice-dataplane
just show-details production
```

Both environments live in one vault as two items, so they share no password, zone, token
or database. The vault name is the only value the two entrypoints have to agree on.

With both up, each cluster watches its own branch, so a push is a deploy: do the work on
`dev`, merge into `staging`, watch it converge, then merge `staging` into `production`.
The indexer image is the exception, since Keel rolls that forward when you push a new
image to the tag.

## Tearing it down

Either environment. Substitute `staging` or `production`, be on that branch, and keep its
kubeconfig at `infra/<env>/.kube/<cluster>.config`.

Terraform does not know about the load balancers the gateway created, so the cluster has
to unwind first:

```sh
git checkout <env>

cd clusters
just destroy <env>/us-west-2-aws-backoffice-dataplane

cd ../infra/<env>
just destroy
```

The first deletes the Flux stages in reverse order and waits for each inventory to be
garbage-collected, which releases the NLBs. The second removes the cluster, the VPC, and
in staging both backup buckets with every backup in them, since `infra/staging/main.tf`
sets `force_destroy = true` on each. Copy anything you want to keep out of S3 first. In
production both buckets carry `prevent_destroy` instead, so the destroy fails on them
rather than wiping them.

Your 1Password item survives. Rebuilding starts from `just seed-vault <env>` with the
values already there, rerun after the new apply so `pg-backup-destination` follows the new
bucket.

## Going deeper

Day-two operations, including sizing nodes, dedicating one to a workload, Talos and
Kubernetes upgrades, and how the backup bucket and its cross-region replica are wired,
are in
[`infra/staging/README.md`](infra/staging/README.md).

`infra/local` is a kind cluster for trying the platform on your own machine with no AWS
bill. It uses the same `clusters/` half of this guide, against the `local` entrypoint.

| | |
|---|---|
| [`clusters/entrypoints/README.md`](clusters/entrypoints/README.md) | what each entrypoint file declares, and the `OP_VAULT_*` contract |
| [`clusters/packages/layer-zero/README.md`](clusters/packages/layer-zero/README.md) | the platform package: its `platform-vars` interface and the three stages it creates |
| [`clusters/apps/README.md`](clusters/apps/README.md) | the chain-indexer app, and how the Postgres backup toggle works |
| [README layout table](README.md#layout) | the rest of the tree |
