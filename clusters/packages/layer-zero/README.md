# layer-zero

A Flux platform package: secrets, an Envoy Gateway underlay with cert-manager and
CNPG, and a Grafana observability stack. A consumer points one Kustomization at
`platform/bootstrap` and the package declares everything else.

## Consuming it

Vendor the repo (submodule or subtree), then declare three things in
`flux-system`: a `GitRepository` that can read it, a `ConfigMap` named
`platform-vars`, and one `Kustomization`.

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: bootstrap
  namespace: flux-system
spec:
  path: ./path/where/you/vendored/platform/bootstrap
  prune: true
  wait: true
  sourceRef:
    kind: GitRepository
    name: platform-foundation
  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: platform-vars
```

That is the whole call. There is no `substitute:` block anywhere in this package —
`platform-vars` is the entire interface, and every Kustomization the package creates
reads it by that name.

`wait: true` matters: the package's stages are ordered, and anything you layer on
top should depend on this Kustomization rather than on a stage inside it.

### The `platform-vars` contract

The name is fixed — the package reads `ConfigMap/platform-vars` in `flux-system`
directly. Every key below is required.

Most of what an operator picks is not here at all: the zone, the external-dns
owner id, the emails and the SMTP settings are fetched from 1Password into
`platform-secret-vars`. `OP_VAULT` is the exception, and has to be, since it names
the vault everything else is read from.

| key | |
|---|---|
| `PLATFORM_SOURCE` | name of your `GitRepository` pointing at this repo |
| `PLATFORM_PATH_PREFIX` | where you vendored it, relative to the source root; `.` when the package is the source itself |
| `PLATFORM_NAMESPACE` | namespace to create and install the gateway into |
| `ACME_ENV` | `staging` or `production` |
| `ENVOY_REPLICAS`, `SHIM_REPLICAS` | quoted integers |
| `FLUX_INTERVAL`, `FLUX_RETRY_INTERVAL`, `FLUX_TIMEOUT` | applied to every Kustomization the package creates |
| `GRAFANA_ALLOWED_CIDRS` | client CIDRs allowed to reach the Grafana route, as a YAML flow sequence, e.g. `'["0.0.0.0/0"]'`; everything else is denied at the gateway |
| `GATEWAY_LB_SOURCE_RANGES` | client CIDRs allowed to open a connection to the gateway's load balancer at all, as a YAML flow sequence, e.g. `'["0.0.0.0/0"]'`; enforced by the cloud firewall on the real source address, including direct connections to node ports, so it must cover every allowlist above |
| `OP_VAULT_CLUSTER_ZONE` | DNS zone the gateway serves, e.g. `example.com` |
| `OP_VAULT_TXT_OWNER_ID` | external-dns `--txt-owner-id`; must be unique among clusters sharing a DNS zone, and changing it on a live cluster orphans the TXT records the old id owns |
| `OP_VAULT_CLOUDFLARE_TOKEN` | `<item>/[section/]<field>` — DNS-01 and external-dns |
| `OP_VAULT_GRAFANA_ADMIN_USER`, `OP_VAULT_GRAFANA_ADMIN_PASSWORD` | Grafana login |
| `OP_VAULT_RESEND_SMTP_PASSWORD` | SMTP password |
| `OP_VAULT_ACME_EMAIL` | Let's Encrypt account address |
| `OP_VAULT_ALERT_EMAIL_TO` | contact point address |
| `OP_VAULT_GRAFANA_SMTP_HOST`, `OP_VAULT_GRAFANA_SMTP_USER`, `OP_VAULT_GRAFANA_SMTP_FROM_ADDRESS` | alert delivery |

Every `OP_VAULT_*` value is an address inside the vault, written the way 1Password
writes it minus the `op://<vault>/` prefix.

### Prerequisite

Secrets come from 1Password through External Secrets. Seed the service account
token before Flux starts, since the package cannot fetch its own credential:

```sh
kubectl create namespace external-secrets-system
kubectl create secret generic onepassword-token \
  --namespace=external-secrets-system \
  --from-literal=token="$OP_SERVICE_ACCOUNT_TOKEN"
```

## What it creates

Three stages, in order, each waiting on the last.

- **`secrets`** — External Secrets Operator and Stakater Reloader, the
  `onepassword` `ClusterSecretStore`, and the Cloudflare token as a
  `ClusterExternalSecret`.
- **`underlay`** — cert-manager, CNPG, Kyverno, Keel, external-dns, Envoy Gateway;
  the `ClusterIssuer`, the CNPG barman-cloud backup plugin, the gateway and its
  certificate, and the Postgres STARTTLS shim.
- **`observability`** — kube-prometheus-stack, grafana-operator, Alloy, Loki, Tempo,
  and a Grafana instance with datasources and alerting.

Two fixed names, one in each direction: the package expects
`ConfigMap/platform-vars` from you, and produces `Secret/platform-secret-vars`
in `flux-system` — the zone, the external-dns owner id, the Grafana credentials,
the SMTP settings and the ACME address, resolved from 1Password and read back by
the package's own stages. `operators`, `base`, `core` and `observability-instances`
substitute from it; the stages that create it never can. None is
configurable, because a name the caller cannot meaningfully change is a contract,
not a parameter.

## Conventions

- One namespace per operator. The exception is `plugin-barman-cloud`, which CNPG
  discovers by Service in its own namespace and so has to install into
  `cnpg-system`.
- Workloads reading a credential from the environment carry
  `reloader.stakater.com/auto: "true"`, so a rotated Secret reaches the process.
- Namespaces opt in to gateway routing with the
  `oatlabs.oatmilk.work/gateway-access: "true"` label, and routes opt in to DNS with
  the `oatlabs.oatmilk.work/external-dns: "true"` annotation.
