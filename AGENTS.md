# HyperFleet Infrastructure — Agent Guide

IaC repo for HyperFleet dev environments. Terraform provisions GCP resources (GKE, Pub/Sub, VPC). Helm deploys components to Kubernetes. No application code.

```
Terraform → GKE cluster + Pub/Sub
    ↓
scripts/tf-helm-values.sh → generates broker config YAML
    ↓
Helm charts (via helm-git plugin) → deploy to Kubernetes
    ├── API
    ├── Sentinels (clusters, nodepools)
    ├── Adapters (1, 2, 3)
    └── Maestro (server + agent, separate namespace)
```

## Verification

Run `make help` for all targets. Use these for validation:

| Target | What it does | Needs cluster? |
|--------|-------------|----------------|
| `make validate-terraform` | `terraform init -backend=false`, `fmt -check`, `validate` | No |
| `make lint-helm` | `helm lint` all charts | No |
| `make lint-shellcheck` | shellcheck all `.sh` files (requires `shellcheck`; skips silently outside CI if missing) | No |
| `make ci-validate` | All three above combined | No |
| `make validate-helm-charts` | `helm template` render all charts (current `BROKER_TYPE` only) | No |
| `make ci-dry-run` | `ci-validate` + `validate-helm-charts` for both broker types | No |
| `make install-api DRY_RUN=true` | Helm dry-run a single component against live cluster | Yes |

**IMPORTANT:** Do NOT use `make install-all DRY_RUN=true` for validation — it runs Terraform first and fails without backend access. Use `make ci-dry-run` for offline validation.

**Pre-commit order:**

```bash
cd terraform && terraform fmt -recursive     # auto-fix terraform formatting
make ci-dry-run                             # full offline validation
```

## Source of Truth

| Topic | File |
|-------|------|
| All make targets and variables | `Makefile` (run `make help`) |
| Terraform variables and defaults | `terraform/variables.tf` |
| Terraform architecture and setup | `terraform/README.md` |
| Development setup and workflow | `CONTRIBUTING.md` |
| Commit message format | `CONTRIBUTING.md` → "Commit Standards" |
| Helm values generation logic | `scripts/tf-helm-values.sh` |
| Chart dependencies and sources | `helm/*/Chart.yaml` |
| Terraform version pin | `.tool-versions` |
| Repo structure and quick start | `README.md` |

## Two Deployment Paths

1. **GCP + Google Pub/Sub** (default): `make install-all` — runs Terraform, configures kubectl, generates Pub/Sub broker config, deploys everything.
2. **RabbitMQ** (any Kubernetes): `make install-all-rabbitmq` — no Terraform, deploys RabbitMQ manifest, generates RabbitMQ broker config, deploys everything.

## Key Makefile Defaults

Most commonly overridden variables with actual defaults. Run `make help` for the complete list:

| Variable | Default |
|----------|---------|
| `NAMESPACE` | `hyperfleet` |
| `MAESTRO_NS` | `maestro` |
| `BROKER_TYPE` | `googlepubsub` |
| `REGISTRY` | `registry.ci.openshift.org` |
| `*_IMAGE_TAG` | `latest` |
| `*_CHART_REF` | `main` (API, Sentinel, Adapter only — Maestro has no `CHART_REF` variable) |
| `CHART_ORG` | `openshift-hyperfleet` |
| `GCP_PROJECT_ID` | `hcm-hyperfleet` |
| `TF_ENV` | `dev` |

To pin Maestro's chart version, edit `helm/maestro/Chart.yaml` directly.

## Conventions

### Makefile
- Prerequisite checks use `check-*` naming prefix

### Helm Charts
- Charts are umbrella charts — actual chart source lives in component repos, pulled via helm-git plugin
- `set-chart-ref` macro in Makefile rewrites `Chart.yaml` repository URL and `?ref=` during install and validation targets — do not manually edit the `?ref=` parameter in api, sentinel, or adapter charts
- Maestro chart ref is NOT managed by `set-chart-ref` or `CHART_ORG` — its chart source is hardcoded to `openshift-online/maestro`
- `CHART_ORG` and `*_CHART_REF` control which GitHub org/ref api/sentinel/adapter charts are pulled from

### Terraform
- All variables need `description` in `variables.tf`
- All outputs need `description` in `outputs.tf`
- Backend config files: `dev-*.tfvars`, `dev-*.tfbackend`, `dev.tfvars`, and `dev.tfbackend` in `terraform/envs/gke/` are gitignored. Exception: `dev-prow.*` files are committed (shared CI cluster config)
- Copy from `.example` files for personal configs

## Boundaries

**IMPORTANT: Do NOT**
- Edit files in `generated-values-from-terraform/` — they are created by `scripts/tf-helm-values.sh` and overwritten on each run
- Commit personal `dev-*.tfvars` or `dev-*.tfbackend` files (gitignored, but `dev-prow.*` is an exception)
- Hardcode GCP project IDs — use `GCP_PROJECT_ID` variable
- Add Makefile targets without `## Description` comment (powers `make help`) and `.PHONY` declaration
- Add external tool dependencies without a matching `check-*` prerequisite target
- Use `make install-all` for offline validation (use `make ci-dry-run`)

## Gotchas

1. **helm-git plugin required**: Helm charts pull from GitHub repos via `git+https://` URLs. Without the helm-git plugin, `helm dependency update` fails silently or with cryptic errors. Check with `make check-helm`.

2. **`set-chart-ref` modifies Chart.yaml in-place**: The Makefile's `set-chart-ref` macro rewrites the `?ref=` parameter and org in `helm/{api,sentinel-*,adapter*}/Chart.yaml` during install and validation targets (`install-*`, `validate-helm-charts`, `ci-dry-run`). These changes show up as dirty in `git status`. This is by design — chart refs are pinned at runtime, not at commit time. Maestro charts are not affected.

3. **Maestro uses a separate namespace**: Maestro deploys to `$(MAESTRO_NS)` (default: `maestro`), not `$(NAMESPACE)`. Both namespaces are created automatically by `check-namespace`/`check-maestro-namespace`.

4. **`DRY_RUN` only affects Helm**: The `DRY_RUN=true` flag adds `--dry-run` to Helm commands only. Terraform targets (`install-terraform`, `get-credentials`) ignore it. Aggregate targets like `install-all` still run Terraform even with `DRY_RUN=true`.

5. **Adapter config files are `--set-file` not `--values`**: Adapter install targets use `--set-file` for `adapter-config.yaml` and `adapter-task-config.yaml`. These are loaded as string values, not merged as Helm values.

6. **Generated values are conditional**: Install targets only pass `--values $(GENERATED_DIR)/file.yaml` if the file exists (`$(wildcard ...)`). If you skip `tf-helm-values`, components install without broker config.
