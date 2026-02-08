project_id = "networking-486816"

deployments = {
  us-central = {
    region     = "us-central1"
    zone       = "us-central1-a"
    node_count = 2
  }
  us-east = {
    region     = "us-east1"
    zone       = "us-east1-b"
    node_count = 1
  }
}

subnet_cidrs = {
  us-central = "10.10.0.0/24"
  us-east    = "10.20.0.0/24"
}

machine_type          = "e2-standard-2"
proxy_port            = 3128
threat_intel_url      = "https://rules.emergingthreats.net/fwrules/emerging-Block-IPs.txt"
allowed_ingress_cidrs = ["145.79.198.30/32"]
seed_bad_urls_url     = ""
seed_bad_ports_url    = ""
seed_good_urls_url    = ""
