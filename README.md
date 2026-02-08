# Secure Egress Proxy Nodes on GCP

This repository provisions production-ready egress proxy nodes on Google Cloud Platform using Terraform. Each node runs:
- Squid proxy
- Suricata in inline NFQUEUE mode
- ipset-based blocking of threat intel IPs pulled from a public HTTP endpoint
- Squid seed lists for bad URLs, bad ports, and good URLs pulled from HTTP endpoints

The build is fully bootstrapped by a startup script (no manual SSH), idempotent, and supports multi-region deployments.

## Architecture

Components:
- VPC with per-region subnets
- Compute Engine instances running Squid + Suricata + ipset
- Firewall rules scoped to instance tags
- Least-privilege service account for logging/metrics
- GCS backend for Terraform state

Traffic flow (simplified):
1. Clients in approved CIDRs connect to Squid on the node’s internal IP and port 3128.
2. iptables checks the threat intel ipset and drops requests to known bad destinations.
3. Suricata inspects proxy traffic via NFQUEUE and can drop packets inline.
4. Squid enforces seed lists (bad URLs, bad ports, good URLs) and forwards allowed traffic to the public internet using the node’s external IP.
5. Squid logs to `/var/log/squid/access.log`, Suricata logs to `/var/log/suricata/eve.json`.

Trade-offs:
- NFQUEUE rules are scoped to proxy traffic on port 3128 to reduce impact on OS traffic. You can extend to full egress inspection if required.
- Suricata is configured with `queue-bypass` for availability; in a Suricata outage, traffic continues instead of failing closed.
- Seed lists are applied via `url_regex` and port ACLs. If you require strict domain-only matching, swap to `dstdomain` and adjust seed list formats.

## Repository Structure

- `terraform/`
  - `modules/egress_node/` — Compute Engine module
  - `envs/dev/` — Example environment
- `scripts/`
  - `bootstrap.sh` — Node bootstrap (Squid, Suricata, ipset, iptables)
  - `update-threat-intel.sh` — Threat intel updater (installed by bootstrap)
- `.github/workflows/` — CI/CD workflows

## Prerequisites

- GCP project created and billing enabled
- APIs enabled: Compute Engine, IAM
- GCS bucket for Terraform state
- Terraform >= 1.5

## Deployment (Local)

1. Configure backend and variables:
   - Update `terraform/envs/dev/terraform.tfvars` with your project ID, regions, and threat intel URL.
   - Provide seed list URLs (`seed_bad_urls_url`, `seed_bad_ports_url`, `seed_good_urls_url`) or leave empty to disable a list.
   - Initialize Terraform with the GCS backend:

```bash
cd terraform/envs/dev
terraform init \
  -backend-config="bucket=YOUR_TF_STATE_BUCKET" \
  -backend-config="prefix=terraform/state/dev"
```

2. Plan and apply:

```bash
terraform plan
terraform apply
```

## CI/CD (GitHub Actions)

Workflows:
- `terraform-plan.yml` runs `fmt`, `validate`, and `plan` on pull requests
- `terraform-apply.yml` runs on `main` with environment protection for manual approval

Required GitHub secrets:
- `GCP_WORKLOAD_IDENTITY_PROVIDER` — Workload Identity Provider resource name
- `GCP_SERVICE_ACCOUNT` — Service account email for GitHub Actions
- `TF_STATE_BUCKET` — GCS bucket name for Terraform state

Recommended: protect the `production` environment in GitHub with required reviewers to enforce manual approvals.

## Operations

- Threat intel updates run every 15 minutes via `systemd` timer.
- Squid seed lists refresh every 30 minutes via `systemd` timer and reload Squid.
- ipset rules are saved via `netfilter-persistent`.
- Suricata rules are updated on boot with `suricata-update` (best-effort).

## Security Notes

- No hardcoded secrets in code or workflows.
- Instance service account is limited to logging and metrics write roles.
- Project-wide SSH keys are blocked on instances by default.
- Firewall rules are tag-scoped and CIDR-restricted.
