# Layout

| | |
|---|---|
| [`infra/`](infra/staging/README.md) | Terraform per environment — the VPC, the Talos cluster, the backup bucket and its cross-region replica. Nodes are described in `config.json`; that README covers sizing, dedicating a node to a workload, upgrades and backups. |
| [`clusters/entrypoints/`](clusters/entrypoints/README.md) | One `<env>/<cluster>` per Flux bootstrap target, and the variables each cluster sets. |
| [`clusters/packages/layer-zero/`](clusters/packages/layer-zero/README.md) | The platform package — secrets, gateway, CNPG, observability — and its `platform-vars` contract. |
| [`clusters/apps/`](clusters/apps/README.md) | The chain-indexer itself: Postgres, Hasura, the indexer, routes, dashboards, alerts. |
