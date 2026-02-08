variable "project_id" {
  type        = string
  description = "GCP project ID."
}

variable "name_prefix" {
  type        = string
  description = "Prefix for instance names."
}

variable "zone" {
  type        = string
  description = "GCP zone for instances."
}

variable "machine_type" {
  type        = string
  description = "Compute Engine machine type."
}

variable "node_count" {
  type        = number
  description = "Number of egress nodes to deploy in the zone."
  default     = 1
}

variable "subnet_self_link" {
  type        = string
  description = "Self link of the subnet to attach."
}

variable "tags" {
  type        = list(string)
  description = "Network tags to apply to instances."
  default     = []
}

variable "service_account_email" {
  type        = string
  description = "Service account email for instances."
}

variable "startup_script" {
  type        = string
  description = "Startup script to bootstrap the node."
}

variable "image_family" {
  type        = string
  description = "Image family for the boot disk."
  default     = "ubuntu-2204-lts"
}

variable "image_project" {
  type        = string
  description = "Image project for the boot disk."
  default     = "ubuntu-os-cloud"
}

variable "boot_disk_size_gb" {
  type        = number
  description = "Boot disk size in GB."
  default     = 20
}

variable "assign_public_ip" {
  type        = bool
  description = "Whether to assign an external IP for outbound access."
  default     = true
}
