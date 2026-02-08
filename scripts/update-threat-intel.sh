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
