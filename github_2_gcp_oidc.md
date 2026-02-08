# GitHub → GCP OIDC Setup Manual

**(Workload Identity Federation for Terraform CI/CD)**

This document describes how to configure **GitHub Actions** to authenticate to **Google Cloud Platform (GCP)** using **OIDC / Workload Identity Federation**, without using long-lived service account keys.

---

## Architecture Overview

Authentication flow:

```
GitHub Actions
  → OIDC token
    → GCP Workload Identity Pool
      → GCP Service Account
        → Terraform manages infrastructure
```

Key properties:

* No JSON service account keys
* Short-lived credentials only
* Repo-scoped access
* Auditable and revocable

---

## Prerequisites

* GCP project: we are using `networking-486816`
* GitHub repository: we are using `cchostak/secure-egress`
* `gcloud` CLI authenticated with sufficient IAM permissions
* Terraform will be executed from GitHub Actions. Using Cloud shell.
* APIs enabled in the project:
  * IAM Service Account Credentials API (`iamcredentials.googleapis.com`)
  * Identity and Access Management API (`iam.googleapis.com`)
  * Compute Engine API (`compute.googleapis.com`)
* Billing account enabled and linked to the project (required for GCS + Compute)

---

## Step 1: Create a GCP Service Account for CI

Enable required APIs (one-time):

```bash
gcloud services enable \
  iamcredentials.googleapis.com \
  iam.googleapis.com \
  compute.googleapis.com \
  --project networking-486816
```

Create the service account that GitHub Actions will impersonate:

```bash
gcloud iam service-accounts create github-terraform \
  --display-name="GitHub Terraform CI"
```

Grant initial permissions (tighten later):

```bash
gcloud projects add-iam-policy-binding networking-486816 \
  --member="serviceAccount:github-terraform@networking-486816.iam.gserviceaccount.com" \
  --role="roles/editor"
```

> Note: In production, replace `roles/editor` with least-privilege roles such as:
>
> * `roles/compute.admin`
> * `roles/iam.serviceAccountUser`
> * `roles/storage.admin` (for Terraform state)

---

## Step 2: Create a Workload Identity Pool

Create a Workload Identity Pool for GitHub Actions:

```bash
gcloud iam workload-identity-pools create github-pool \
  --project=networking-486816 \
  --location=global \
  --display-name="GitHub Actions Pool"
```

---

## Step 3: Create an OIDC Provider for GitHub

Create an OIDC provider inside the pool:

```bash
gcloud iam workload-identity-pools providers create-oidc github \
  --project=networking-486816 \
  --location=global \
  --workload-identity-pool=github-pool \
  --display-name="GitHub OIDC" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="attribute.repository == 'cchostak/secure-egress'"
```

This restricts authentication to **only** the specified GitHub repository.

---

## Step 4: Allow the Repo to Impersonate the Service Account

### 4.1 Get the GCP project number

```bash
gcloud projects describe networking-486816 \
  --format="value(projectNumber)"
```

Example output:

```
28661575811
```

### 4.2 Bind the Workload Identity Pool to the service account

```bash
gcloud iam service-accounts add-iam-policy-binding \
  github-terraform@networking-486816.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/28661575811/locations/global/workloadIdentityPools/github-pool/attribute.repository/cchostak/secure-egress"
```

Result:

* Only `cchostak/secure-egress` can impersonate this service account
* Forks and other repos are denied by default

### 4.3 If you see `iam.serviceAccounts.getAccessToken` errors

Some org policies require explicit token creation permission. If `terraform init` fails with:

```
Permission 'iam.serviceAccounts.getAccessToken' denied
```

grant token creator to the same principal:

```bash
gcloud iam service-accounts add-iam-policy-binding \
  github-terraform@networking-486816.iam.gserviceaccount.com \
  --role="roles/iam.serviceAccountTokenCreator" \
  --member="principalSet://iam.googleapis.com/projects/28661575811/locations/global/workloadIdentityPools/github-pool/attribute.repository/cchostak/secure-egress"
```

---

## Step 5: Configure GitHub Actions Workflow

Create `.github/workflows/terraform-apply.yml`:

```yaml
name: terraform-apply

on:
  push:
    branches: [ "main" ]

permissions:
  id-token: write
  contents: read

jobs:
  terraform:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Authenticate to GCP
        uses: google-github-actions/auth@v2
        with:
          workload_identity_provider: "projects/28661575811/locations/global/workloadIdentityPools/github-pool/providers/github"
          service_account: "github-terraform@networking-486816.iam.gserviceaccount.com"

      - uses: hashicorp/setup-terraform@v3

      - name: Terraform Init
        run: terraform init
        working-directory: terraform/envs/dev

      - name: Terraform Apply
        run: terraform apply -auto-approve
        working-directory: terraform/envs/dev
```

Notes:

* No secrets are stored in GitHub
* OIDC token is issued dynamically per workflow run
* Authentication fails automatically if repo name does not match

---

## Step 6: Configure Terraform Remote State (GCS)

Create a GCS bucket once:

```bash
gsutil mb -p networking-486816 -l us-central1 gs://egress-forge-tf-state
```

Note: bucket creation requires an active billing account on the project. If you see:

`AccessDeniedException: 403 The billing account for the owning project is disabled`,

enable billing on the project and retry.

Grant the CI service account access to the state bucket (bucket-level, least privilege):

```bash
gsutil iam ch \
  serviceAccount:github-terraform@networking-486816.iam.gserviceaccount.com:objectAdmin \
  gs://egress-forge-tf-state
```

If `terraform init` fails with:

`storage.objects.get` denied on the state object, the bucket IAM above is missing or not applied to the correct bucket.

Bucket privacy:
* Buckets are **private by default**. No public access is granted unless you explicitly add it.
* Recommended hardening:

```bash
gsutil uniformbucketlevelaccess set on gs://egress-forge-tf-state
gsutil pap set enforced gs://egress-forge-tf-state
```

In `terraform/envs/dev/main.tf`:

```hcl
terraform {
  backend "gcs" {
    bucket = "egress-forge-tf-state"
    prefix = "dev"
  }
}
```

---

## Validation & Troubleshooting

### Verify Workload Identity Pool

```bash
gcloud iam workload-identity-pools describe github-pool \
  --project=networking-486816 \
  --location=global
```

### Verify Provider

```bash
gcloud iam workload-identity-pools providers describe github \
  --project=networking-486816 \
  --location=global \
  --workload-identity-pool=github-pool
```

### Common Failure Causes

* Repository name mismatch (case-sensitive)
* Using project ID instead of project **number**
* Missing `id-token: write` permission in GitHub Actions
* Attempting to run from a fork
* Missing `roles/iam.workloadIdentityUser` (or `roles/iam.serviceAccountTokenCreator`) on the service account
* Missing bucket IAM on the Terraform state bucket
* IAM Service Account Credentials API is disabled
* IAM API is disabled (service account create fails)
* Compute Engine API is disabled (VPC/instance create fails)
* Billing account not enabled on the project (bucket creation fails)
* Wrong principal format in SA policy (must use `/attribute.repository/OWNER/REPO`, not `=`)
* `storage.objects.get` denied when reading state (missing `objectAdmin`/`objectViewer` on the state bucket)

---

## Outcome

This setup provides:

* ✅ Keyless authentication
* ✅ Repo-scoped access
* ✅ Short-lived credentials
* ✅ Strong auditability
* ✅ CI/CD ready for production use
