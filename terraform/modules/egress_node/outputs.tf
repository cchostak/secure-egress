output "instance_names" {
  value       = google_compute_instance.egress[*].name
  description = "Names of egress instances."
}

output "internal_ips" {
  value       = google_compute_instance.egress[*].network_interface[0].network_ip
  description = "Internal IPs of egress instances."
}

output "external_ips" {
  value       = [for i in google_compute_instance.egress : try(i.network_interface[0].access_config[0].nat_ip, null)]
  description = "External IPs of egress instances (if assigned)."
}

output "self_links" {
  value       = google_compute_instance.egress[*].self_link
  description = "Self links of egress instances."
}
