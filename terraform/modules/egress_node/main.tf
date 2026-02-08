data "google_compute_image" "default" {
  family  = var.image_family
  project = var.image_project
}

resource "google_compute_instance" "egress" {
  count        = var.node_count
  name         = "${var.name_prefix}-${count.index}"
  project      = var.project_id
  zone         = var.zone
  machine_type = var.machine_type
  tags         = var.tags

  boot_disk {
    initialize_params {
      image = data.google_compute_image.default.self_link
      size  = var.boot_disk_size_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = var.subnet_self_link

    dynamic "access_config" {
      for_each = var.assign_public_ip ? [1] : []
      content {}
    }
  }

  metadata_startup_script = var.startup_script

  metadata = {
    block-project-ssh-keys = "true"
  }

  service_account {
    email = var.service_account_email
    scopes = [
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
    ]
  }

  scheduling {
    automatic_restart   = true
    on_host_maintenance = "MIGRATE"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  labels = {
    role = "egress"
  }
}
