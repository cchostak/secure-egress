# Validation & Testing Guide

This guide explains how to validate and test the deployed egress proxy nodes. It assumes instances were created by Terraform and are reachable from your allowed client IP.

## Current Instances (as of 2026-02-08)

- `egress-us-central-0` (`us-central1-a`) — `10.10.0.3` / `35.188.103.176`
- `egress-us-central-1` (`us-central1-a`) — `10.10.0.2` / `136.115.50.46`
- `egress-us-east-0` (`us-east1-b`) — `10.20.0.2` / `34.26.102.87`

If you recreate infrastructure, external IPs will likely change. Replace the IPs in the commands below with current values.

## Pre-checks

1. Confirm your client IP is allowed.
   - `allowed_ingress_cidrs` in `terraform/envs/dev/terraform.tfvars` must include your current public IP as `/32`.
   - The GCP firewall rule `egress-allow-proxy` is derived from that list.

2. Verify firewall rule:

```bash
gcloud compute firewall-rules list \
  --project networking-486816 \
  --filter="name=egress-allow-proxy" \
  --format="table(name,network,sourceRanges,allowed)"
```

## Connectivity Tests (from your allowed client IP)

Replace `EXTERNAL_IP` with any of the instance external IPs.

1. Verify port is open:

```bash
nc -vz EXTERNAL_IP 3128
```

2. Verify proxy responds:

```bash
curl -x http://EXTERNAL_IP:3128 http://example.com -I
```

3. Verify HTTPS via CONNECT:

```bash
curl -x http://EXTERNAL_IP:3128 https://example.com -I
```

4. Verify egress IP (should match the proxy VM’s external IP):

```bash
curl -x http://EXTERNAL_IP:3128 https://ifconfig.me
```

## Squid Validation (on the instance)

SSH is **blocked by default** (only port 3128 is allowed). If you want SSH, add a rule for port 22 from your IP or use IAP (recommended). See **SSH Access (optional)** below.

Use `gcloud compute ssh` to inspect the node once SSH access is enabled:

```bash
gcloud compute ssh egress-us-central-0 --zone us-central1-a --project networking-486816
```

Inside the VM:

```bash
sudo systemctl status squid --no-pager
sudo squid -k parse
sudo tail -n 50 /var/log/squid/access.log
```

## SSH Access (optional)

### Option A — Allow SSH from your IP (quickest)

```bash
MY_IP="X.X.X.X/32"

gcloud compute firewall-rules create egress-allow-ssh \
  --project networking-486816 \
  --network egress-vpc \
  --direction INGRESS \
  --action ALLOW \
  --rules tcp:22 \
  --source-ranges "${MY_IP}" \
  --target-tags egress-proxy
```

To remove later:

```bash
gcloud compute firewall-rules delete egress-allow-ssh --project networking-486816
```

### Option B — IAP TCP forwarding (recommended for tighter access)

1. Enable IAP API:

```bash
gcloud services enable iap.googleapis.com --project networking-486816
```

2. Allow IAP to reach port 22:

```bash
gcloud compute firewall-rules create egress-allow-ssh-iap \
  --project networking-486816 \
  --network egress-vpc \
  --direction INGRESS \
  --action ALLOW \
  --rules tcp:22 \
  --source-ranges 35.235.240.0/20 \
  --target-tags egress-proxy
```

3. Grant yourself IAP tunnel access:

```bash
gcloud projects add-iam-policy-binding networking-486816 \
  --member="user:YOUR_EMAIL" \
  --role="roles/iap.tunnelResourceAccessor"
```

4. Connect:

```bash
gcloud compute ssh egress-us-central-0 \
  --zone us-central1-a \
  --project networking-486816 \
  --tunnel-through-iap
```

## Seed List Validation (Squid)

1. Ensure seed files exist:

```bash
sudo ls -l /etc/squid/seed_*.acl
```

If seed list URLs are not configured, these files will be empty and Squid will warn about empty ACLs. That is expected.

2. Trigger update manually:

```bash
sudo /usr/local/sbin/update-squid-seed-lists.sh
```

If you want to test with ad‑hoc URLs, pass them explicitly:

```bash
sudo SEED_BAD_URLS_URL="https://example.com/bad-urls.txt" \
  SEED_BAD_PORTS_URL="https://example.com/bad-ports.txt" \
  SEED_GOOD_URLS_URL="https://example.com/good-urls.txt" \
  /usr/local/sbin/update-squid-seed-lists.sh
sudo systemctl reload squid
```

3. Verify timer is active:

```bash
systemctl list-timers --all | grep squid
```

4. Test bad URL list (if configured):

```bash
curl -x http://EXTERNAL_IP:3128 http://bad.example.test/ -I
```

Expected: Squid denies with `403` or `TCP_DENIED` in `access.log`.

5. Test bad ports list (if configured):

```bash
curl -x http://EXTERNAL_IP:3128 http://example.com:25 -I
```

Expected: denied due to `bad_ports` ACL.

## Threat Intel ipset Validation

On the instance:

```bash
sudo ipset list threat_ips | head -n 20
sudo systemctl status update-threat-intel.timer --no-pager
sudo journalctl -u update-threat-intel.service -n 50 --no-pager
```

Trigger a manual refresh:

```bash
sudo /usr/local/sbin/update-threat-intel.sh
```

If the timer or service is missing, the startup script likely did not finish. See **Startup Script Diagnostics** below.

## Suricata (Inline NFQUEUE) Validation

On the instance:

```bash
sudo systemctl status suricata --no-pager
sudo iptables -L INPUT -n -v | grep NFQUEUE
sudo iptables -L OUTPUT -n -v | grep NFQUEUE
sudo tail -n 50 /var/log/suricata/eve.json
```

If you need a simple detection test, add a local rule and generate traffic:

```bash
echo 'alert http any any -> any any (msg:"TEST HTTP"; content:"example"; sid:1000001; rev:1;)' | sudo tee /etc/suricata/rules/local.rules
sudo systemctl restart suricata
curl -x http://EXTERNAL_IP:3128 http://example.com
sudo tail -n 5 /var/log/suricata/eve.json
```

## End-to-End Validation Checklist

- Port 3128 reachable only from your allowlisted IP.
- Squid responds to HTTP and HTTPS (CONNECT).
- Seed lists update and are enforced (if configured).
- ipset list is populated and refreshes on timer.
- Suricata is running and logs to `/var/log/suricata/eve.json`.
- Access logs show proxied requests in `/var/log/squid/access.log`.

## Troubleshooting

- **Connection refused / timeout**: check firewall rules and allowed IPs.
- **403 from Squid**: check ACL order and seed list content.
- **No Suricata logs**: verify NFQUEUE rules and `suricata` service status.
- **Suricata fails with `Invalid configuration file` or `eth0: No such device`**:
  the Suricata config may have been rewritten without the YAML header or still contains AF_PACKET capture.
  Re-run the startup script after updating it, or apply the fix below.
- **ipset empty**: check threat intel URL and `update-threat-intel` logs.

## Startup Script Diagnostics

If expected systemd units (e.g., `update-threat-intel.timer`) are missing, the startup script may have failed mid‑run.

Check startup script logs:

```bash
sudo journalctl -u google-startup-scripts.service -n 200 --no-pager
sudo journalctl -u google-guest-agent -n 200 --no-pager
sudo journalctl -u suricata -n 200 --no-pager
```

You can re-run the startup script from instance metadata:

```bash
curl -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/startup-script \
  -o /tmp/startup.sh

sudo bash /tmp/startup.sh
```

If you need to patch Suricata config manually (without re-running bootstrap), run:

```bash
sudo python3 - <<'PY'
import os
import yaml

path = "/etc/suricata/suricata.yaml"
with open(path, "r", encoding="utf-8") as f:
    cfg = yaml.safe_load(f) or {}

cfg["af-packet"] = []
nfq = cfg.get("nfq") or {}
nfq["mode"] = "repeat"
nfq["fail-open"] = True
nfq["queue"] = int(os.environ.get("NFQUEUE_NUM", "0"))
cfg["nfq"] = nfq

with open(path, "w", encoding="utf-8") as f:
    f.write("%YAML 1.1\n---\n")
    yaml.safe_dump(cfg, f, sort_keys=False)
PY

sudo systemctl restart suricata
```
