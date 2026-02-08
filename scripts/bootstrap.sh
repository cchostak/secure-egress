#!/usr/bin/env bash
set -euo pipefail

log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*"
}

if [[ $EUID -ne 0 ]]; then
  echo "bootstrap.sh must run as root" >&2
  exit 1
fi

THREAT_INTEL_URL="${THREAT_INTEL_URL:-}"
ALLOWED_SRC_CIDRS="${ALLOWED_SRC_CIDRS:-10.0.0.0/8}"
PROXY_PORT="${PROXY_PORT:-3128}"
IPSET_NAME="${IPSET_NAME:-threat_ips}"
NFQUEUE_NUM="${NFQUEUE_NUM:-0}"
SEED_BAD_URLS_URL="${SEED_BAD_URLS_URL:-}"
SEED_BAD_PORTS_URL="${SEED_BAD_PORTS_URL:-}"
SEED_GOOD_URLS_URL="${SEED_GOOD_URLS_URL:-}"

if [[ -z "$THREAT_INTEL_URL" ]]; then
  echo "THREAT_INTEL_URL must be set" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
log "Installing packages"
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  ipset \
  iptables-persistent \
  netfilter-persistent \
  python3 \
  python3-yaml \
  squid \
  suricata \
  suricata-update

log "Configuring Squid"
ACL_LINES=""
IFS=',' read -r -a cidrs <<< "$ALLOWED_SRC_CIDRS"
for cidr in "${cidrs[@]}"; do
  cidr_trim=$(echo "$cidr" | xargs)
  if [[ -n "$cidr_trim" ]]; then
    ACL_LINES+="acl allowed_src src ${cidr_trim}\n"
  fi
done
if [[ -z "$ACL_LINES" ]]; then
  ACL_LINES="acl allowed_src src 10.0.0.0/8\n"
fi

mkdir -p /etc/squid
touch /etc/squid/seed_bad_urls.acl /etc/squid/seed_good_urls.acl /etc/squid/seed_bad_ports.acl

cat > /etc/squid/squid.conf <<EOF_CONF
http_port ${PROXY_PORT}
visible_hostname egress-proxy
access_log stdio:/var/log/squid/access.log
cache_log /var/log/squid/cache.log
acl localhost src 127.0.0.1/32 ::1
acl good_urls url_regex -i "/etc/squid/seed_good_urls.acl"
acl bad_urls url_regex -i "/etc/squid/seed_bad_urls.acl"
acl bad_ports port "/etc/squid/seed_bad_ports.acl"
EOF_CONF
printf "%b" "$ACL_LINES" >> /etc/squid/squid.conf
cat >> /etc/squid/squid.conf <<'EOF_CONF'
http_access deny bad_ports
http_access allow good_urls allowed_src
http_access deny bad_urls
http_access allow localhost
http_access allow allowed_src
http_access deny all
EOF_CONF

systemctl enable --now squid

log "Installing Squid seed list updater"
cat > /usr/local/sbin/update-squid-seed-lists.sh <<'EOF_SEED'
#!/usr/bin/env bash
set -euo pipefail

SEED_BAD_URLS_URL="${SEED_BAD_URLS_URL:-}"
SEED_BAD_PORTS_URL="${SEED_BAD_PORTS_URL:-}"
SEED_GOOD_URLS_URL="${SEED_GOOD_URLS_URL:-}"
LOCK_FILE="/var/lock/update-squid-seed-lists.lock"
TARGET_DIR="/etc/squid"
BAD_URLS_FILE="${TARGET_DIR}/seed_bad_urls.acl"
GOOD_URLS_FILE="${TARGET_DIR}/seed_good_urls.acl"
BAD_PORTS_FILE="${TARGET_DIR}/seed_bad_ports.acl"

mkdir -p /var/lock "$TARGET_DIR"
touch "$BAD_URLS_FILE" "$GOOD_URLS_FILE" "$BAD_PORTS_FILE"

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Seed list update already running" >&2
  exit 0
fi

fetch_urls() {
  local url="$1"
  local out="$2"
  if [[ -z "$url" ]]; then
    : > "$out"
    echo 0
    return
  fi

  local tmp
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' RETURN

  curl -fsSL --connect-timeout 10 --max-time 30 "$url" -o "$tmp"
  python3 - "$tmp" "$out" <<'PY'
import sys

src = sys.argv[1]
dst = sys.argv[2]
entries = []
with open(src, "r", encoding="utf-8", errors="ignore") as f:
    for line in f:
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if any(ch.isspace() for ch in line):
            continue
        if len(line) > 2048:
            continue
        entries.append(line)

with open(dst, "w", encoding="utf-8") as f:
    for entry in entries:
        f.write(entry + "\n")

print(len(entries))
PY
}

fetch_ports() {
  local url="$1"
  local out="$2"
  if [[ -z "$url" ]]; then
    : > "$out"
    echo 0
    return
  fi

  local tmp
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' RETURN

  curl -fsSL --connect-timeout 10 --max-time 30 "$url" -o "$tmp"
  python3 - "$tmp" "$out" <<'PY'
import re
import sys

src = sys.argv[1]
dst = sys.argv[2]
ports = set()

with open(src, "r", encoding="utf-8", errors="ignore") as f:
    for line in f:
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        for token in re.split(r"[,\s]+", line):
            if not token:
                continue
            if re.fullmatch(r"\d+", token):
                val = int(token)
                if 1 <= val <= 65535:
                    ports.add(str(val))
            elif re.fullmatch(r"\d+-\d+", token):
                start, end = token.split("-", 1)
                start_i = int(start)
                end_i = int(end)
                if 1 <= start_i <= 65535 and 1 <= end_i <= 65535 and start_i <= end_i:
                    ports.add(f"{start_i}-{end_i}")

def key_fn(item: str):
    if "-" in item:
        a, b = item.split("-", 1)
        return (int(a), int(b))
    return (int(item), int(item))

with open(dst, "w", encoding="utf-8") as f:
    for port in sorted(ports, key=key_fn):
        f.write(port + "\n")

print(len(ports))
PY
}

bad_urls_count=$(fetch_urls "$SEED_BAD_URLS_URL" "$BAD_URLS_FILE")
good_urls_count=$(fetch_urls "$SEED_GOOD_URLS_URL" "$GOOD_URLS_FILE")
bad_ports_count=$(fetch_ports "$SEED_BAD_PORTS_URL" "$BAD_PORTS_FILE")

if systemctl is-active --quiet squid; then
  systemctl reload squid || systemctl restart squid || true
fi

logger -t squid-seed "Updated squid seed lists bad_urls=$bad_urls_count good_urls=$good_urls_count bad_ports=$bad_ports_count"
EOF_SEED

chmod +x /usr/local/sbin/update-squid-seed-lists.sh

cat > /etc/systemd/system/update-squid-seed-lists.service <<EOF_SVC
[Unit]
Description=Update Squid seed lists
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=SEED_BAD_URLS_URL=${SEED_BAD_URLS_URL}
Environment=SEED_BAD_PORTS_URL=${SEED_BAD_PORTS_URL}
Environment=SEED_GOOD_URLS_URL=${SEED_GOOD_URLS_URL}
ExecStart=/usr/local/sbin/update-squid-seed-lists.sh
EOF_SVC

cat > /etc/systemd/system/update-squid-seed-lists.timer <<'EOF_TMR'
[Unit]
Description=Scheduled Squid seed list updates

[Timer]
OnBootSec=2min
OnUnitActiveSec=30min
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
EOF_TMR

systemctl daemon-reload
systemctl enable --now update-squid-seed-lists.timer
/usr/local/sbin/update-squid-seed-lists.sh || true

log "Configuring Suricata for NFQUEUE"
mkdir -p /etc/systemd/system/suricata.service.d
cat > /etc/systemd/system/suricata.service.d/override.conf <<EOF_SVC
[Service]
ExecStart=
ExecStart=/usr/bin/suricata -c /etc/suricata/suricata.yaml -q ${NFQUEUE_NUM}
EOF_SVC

python3 - <<'PY'
import os
import yaml

path = "/etc/suricata/suricata.yaml"
with open(path, "r", encoding="utf-8") as f:
    cfg = yaml.safe_load(f) or {}

# Disable AF_PACKET capture (default config targets eth0 and breaks in GCP).
cfg["af-packet"] = []

nfq = cfg.get("nfq") or {}
nfq["mode"] = "repeat"
nfq["fail-open"] = True
nfq["queue"] = int(os.environ.get("NFQUEUE_NUM", "0"))
cfg["nfq"] = nfq

outputs = cfg.get("outputs") or []
found = False
for out in outputs:
    if "eve-log" in out:
        eve = out["eve-log"]
        eve["enabled"] = True
        eve.setdefault("filetype", "regular")
        eve.setdefault("filename", "/var/log/suricata/eve.json")
        eve.setdefault("types", ["alert", "http", "dns", "flow", "drop"])
        found = True
if not found:
    outputs.append({"eve-log": {"enabled": True, "filetype": "regular", "filename": "/var/log/suricata/eve.json", "types": ["alert", "http", "dns", "flow", "drop"]}})

cfg["outputs"] = outputs

rules = cfg.get("rule-files") or []
if "local.rules" not in rules:
    rules.insert(0, "local.rules")
cfg["rule-files"] = rules

with open(path, "w", encoding="utf-8") as f:
    f.write("%YAML 1.1\n---\n")
    yaml.safe_dump(cfg, f, sort_keys=False)
PY

systemctl daemon-reload
suricata-update || true
systemctl enable --now suricata

log "Installing threat intel updater"
# Keep this in sync with scripts/update-threat-intel.sh
cat > /usr/local/sbin/update-threat-intel.sh <<'EOF_UPD'
#!/usr/bin/env bash
set -euo pipefail

IPSET_NAME="${IPSET_NAME:-threat_ips}"
THREAT_INTEL_URL="${THREAT_INTEL_URL:-}"
LOCK_FILE="/var/lock/update-threat-intel.lock"

if [[ -z "$THREAT_INTEL_URL" ]]; then
  echo "THREAT_INTEL_URL is required" >&2
  exit 1
fi

mkdir -p /var/lock
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Threat intel update already running" >&2
  exit 0
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

curl -fsSL --connect-timeout 10 --max-time 30 "$THREAT_INTEL_URL" -o "$TMP_DIR/raw"

count=$(python3 - "$TMP_DIR/raw" "$TMP_DIR/valid" <<'PY'
import ipaddress
import re
import sys

src = sys.argv[1]
dst = sys.argv[2]
pattern = re.compile(r"([0-9]{1,3}(?:\.[0-9]{1,3}){3}(?:/\d{1,2})?)")

out = set()
with open(src, "r", encoding="utf-8", errors="ignore") as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        for token in pattern.findall(line):
            try:
                net = ipaddress.ip_network(token, strict=False)
            except ValueError:
                continue
            if net.version != 4:
                continue
            out.add(str(net))

with open(dst, "w", encoding="utf-8") as f:
    for net in sorted(out, key=lambda n: (ipaddress.ip_network(n).prefixlen, n)):
        f.write(net + "\n")

print(len(out))
PY
)

ipset -exist create "$IPSET_NAME" hash:net family inet maxelem 200000
ipset flush "$IPSET_NAME"

while read -r net; do
  [[ -n "$net" ]] && ipset add "$IPSET_NAME" "$net" -exist
done < "$TMP_DIR/valid"

if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save >/dev/null 2>&1 || true
fi

logger -t threat-intel "Updated $IPSET_NAME with $count entries from $THREAT_INTEL_URL"
EOF_UPD

chmod +x /usr/local/sbin/update-threat-intel.sh

cat > /etc/systemd/system/update-threat-intel.service <<EOF_SVC
[Unit]
Description=Update threat intel ipset
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=THREAT_INTEL_URL=${THREAT_INTEL_URL}
Environment=IPSET_NAME=${IPSET_NAME}
ExecStart=/usr/local/sbin/update-threat-intel.sh
EOF_SVC

cat > /etc/systemd/system/update-threat-intel.timer <<'EOF_TMR'
[Unit]
Description=Scheduled threat intel updates

[Timer]
OnBootSec=2min
OnUnitActiveSec=15min
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
EOF_TMR

systemctl daemon-reload
systemctl enable --now update-threat-intel.timer
/usr/local/sbin/update-threat-intel.sh || true

log "Configuring iptables/ipset"
ipset -exist create "$IPSET_NAME" hash:net family inet maxelem 200000

if ! iptables -C INPUT -m set --match-set "$IPSET_NAME" src -j DROP 2>/dev/null; then
  iptables -I INPUT 1 -m set --match-set "$IPSET_NAME" src -j DROP
fi
if ! iptables -C OUTPUT -m set --match-set "$IPSET_NAME" dst -j DROP 2>/dev/null; then
  iptables -I OUTPUT 1 -m set --match-set "$IPSET_NAME" dst -j DROP
fi

# Allow proxy access only from approved CIDRs
for cidr in "${cidrs[@]}"; do
  cidr_trim=$(echo "$cidr" | xargs)
  if [[ -n "$cidr_trim" ]]; then
    if ! iptables -C INPUT -p tcp --dport "$PROXY_PORT" -s "$cidr_trim" -j ACCEPT 2>/dev/null; then
      iptables -A INPUT -p tcp --dport "$PROXY_PORT" -s "$cidr_trim" -j ACCEPT
    fi
  fi
done
if ! iptables -C INPUT -p tcp --dport "$PROXY_PORT" -j DROP 2>/dev/null; then
  iptables -A INPUT -p tcp --dport "$PROXY_PORT" -j DROP
fi

# Inline inspection for proxy traffic
if ! iptables -C INPUT -p tcp --dport "$PROXY_PORT" -j NFQUEUE --queue-num "$NFQUEUE_NUM" --queue-bypass 2>/dev/null; then
  iptables -I INPUT 2 -p tcp --dport "$PROXY_PORT" -j NFQUEUE --queue-num "$NFQUEUE_NUM" --queue-bypass
fi
if ! iptables -C OUTPUT -p tcp --sport "$PROXY_PORT" -j NFQUEUE --queue-num "$NFQUEUE_NUM" --queue-bypass 2>/dev/null; then
  iptables -I OUTPUT 2 -p tcp --sport "$PROXY_PORT" -j NFQUEUE --queue-num "$NFQUEUE_NUM" --queue-bypass
fi

netfilter-persistent save >/dev/null 2>&1 || true

log "Bootstrap complete"
