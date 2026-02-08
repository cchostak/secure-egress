variable "project_id" {
  type        = string
  description = "GCP project ID."
}

variable "name_prefix" {
  type        = string
  description = "Name prefix for resources."
  default     = "egress"
}

variable "default_region" {
  type        = string
  description = "Default region for provider settings."
  default     = "us-central1"
}

variable "default_zone" {
  type        = string
  description = "Default zone for provider settings."
  default     = "us-central1-a"
}

variable "deployments" {
  type = map(object({
    region     = string
    zone       = string
    node_count = number
  }))
  description = "Map of deployment keys to region/zone/count."
}

variable "subnet_cidrs" {
  type        = map(string)
  description = "Map of deployment keys to subnet CIDR ranges."
}

variable "machine_type" {
  type        = string
  description = "Compute Engine machine type."
  default     = "e2-standard-2"
}

variable "proxy_port" {
  type        = number
  description = "Squid proxy listening port."
  default     = 3128
}

variable "threat_intel_url" {
  type        = string
  description = "HTTP endpoint providing threat intel IPs (one per line, comments allowed)."
}

variable "seed_bad_urls_url" {
  type        = string
  description = "HTTP endpoint providing bad URL patterns for Squid (one per line, regex allowed)."
  default     = ""
}

variable "seed_bad_ports_url" {
  type        = string
  description = "HTTP endpoint providing bad ports for Squid (one per line, supports ranges like 1000-2000)."
  default     = ""
}

variable "seed_good_urls_url" {
  type        = string
  description = "HTTP endpoint providing good URL patterns for Squid allowlist (one per line, regex allowed)."
  default     = ""
}

variable "allowed_ingress_cidrs" {
  type        = list(string)
  description = "CIDR ranges allowed to access the proxy port."
  default     = ["10.0.0.0/8"]
}

variable "instance_tag" {
  type        = string
  description = "Network tag applied to egress instances."
  default     = "egress-proxy"
}

variable "image_family" {
  type        = string
  description = "Image family for instances."
  default     = "ubuntu-2204-lts"
}

variable "image_project" {
  type        = string
  description = "Image project for instances."
  default     = "ubuntu-os-cloud"
}

variable "ipset_name" {
  type        = string
  description = "Name of the ipset used for threat intel blocking."
  default     = "threat_ips"
}

variable "nfqueue_num" {
  type        = number
  description = "NFQUEUE number for Suricata inline mode."
  default     = 0
}

variable "assign_public_ip" {
  type        = bool
  description = "Whether to assign external IPs to instances."
  default     = true
}
