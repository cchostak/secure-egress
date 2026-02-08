terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }

  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.default_region
  zone    = var.default_zone
}

locals {
  startup_script = join("\n", [
    "THREAT_INTEL_URL=${jsonencode(var.threat_intel_url)}",
    "ALLOWED_SRC_CIDRS=${jsonencode(join(",", var.allowed_ingress_cidrs))}",
    "PROXY_PORT=${var.proxy_port}",
    "IPSET_NAME=${jsonencode(var.ipset_name)}",
    "NFQUEUE_NUM=${var.nfqueue_num}",
    "SEED_BAD_URLS_URL=${jsonencode(var.seed_bad_urls_url)}",
    "SEED_BAD_PORTS_URL=${jsonencode(var.seed_bad_ports_url)}",
    "SEED_GOOD_URLS_URL=${jsonencode(var.seed_good_urls_url)}",
    file("${path.root}/../../../scripts/bootstrap.sh"),
  ])
}

resource "google_compute_network" "egress" {
  name                    = "${var.name_prefix}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "egress" {
  for_each                 = var.deployments
  name                     = "${var.name_prefix}-${each.key}-subnet"
  ip_cidr_range            = var.subnet_cidrs[each.key]
  region                   = each.value.region
  network                  = google_compute_network.egress.id
  private_ip_google_access = true
}

resource "google_compute_firewall" "allow_proxy" {
  name          = "${var.name_prefix}-allow-proxy"
  network       = google_compute_network.egress.name
  direction     = "INGRESS"
  source_ranges = var.allowed_ingress_cidrs
  target_tags   = [var.instance_tag]

  allow {
    protocol = "tcp"
    ports    = [var.proxy_port]
  }
}

resource "google_service_account" "egress" {
  account_id   = "${var.name_prefix}-egress"
  display_name = "Egress proxy nodes"
}

resource "google_project_iam_member" "egress_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.egress.email}"
}

resource "google_project_iam_member" "egress_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.egress.email}"
}

module "egress_nodes" {
  for_each = var.deployments
  source   = "../../modules/egress_node"

  project_id            = var.project_id
  name_prefix           = "${var.name_prefix}-${each.key}"
  zone                  = each.value.zone
  machine_type          = var.machine_type
  node_count            = each.value.node_count
  subnet_self_link      = google_compute_subnetwork.egress[each.key].self_link
  tags                  = [var.instance_tag]
  service_account_email = google_service_account.egress.email
  startup_script        = local.startup_script
  image_family          = var.image_family
  image_project         = var.image_project
  assign_public_ip      = var.assign_public_ip
}
