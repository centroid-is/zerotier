#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <interface> <src-subnet> <dst-subnet>"
  echo "Example: $0 ztm5tynveb 10.104.29.0/24 10.51.40.0/24"
  exit 1
}

[[ $# -eq 3 ]] || usage
IFACE="$1"
SRC_SUBNET="$2"
DST_SUBNET="$3"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need nft
need systemctl
need awk
need grep

cidr_ok() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; }
cidr_ok "$SRC_SUBNET" || { echo "Invalid src subnet: $SRC_SUBNET"; exit 1; }
cidr_ok "$DST_SUBNET" || { echo "Invalid dst subnet: $DST_SUBNET"; exit 1; }

get_plen() { echo "$1" | awk -F/ '{print $2}'; }
SRC_PLEN="$(get_plen "$SRC_SUBNET")"
DST_PLEN="$(get_plen "$DST_SUBNET")"
[[ "$SRC_PLEN" = "$DST_PLEN" ]] || { echo "Prefix lengths must match (/$SRC_PLEN vs /$DST_PLEN)"; exit 1; }

# Heads-up (not fatal)
if [[ -r /proc/sys/net/ipv4/ip_forward ]] && [[ "$(cat /proc/sys/net/ipv4/ip_forward)" != "1" ]]; then
  echo "Note: IPv4 forwarding is disabled. Consider: sudo sysctl -w net.ipv4.ip_forward=1"
fi

# Ensure table and our own hook chains exist
nft list table ip nat >/dev/null 2>&1 || nft add table ip nat
PR_CHAIN="prefixnat_prerouting"
PO_CHAIN="prefixnat_postrouting"
nft list chain ip nat "$PR_CHAIN" >/dev/null 2>&1 || \
  nft add chain ip nat "$PR_CHAIN" '{ type nat hook prerouting priority dstnat; policy accept; }'
nft list chain ip nat "$PO_CHAIN" >/dev/null 2>&1 || \
  nft add chain ip nat "$PO_CHAIN" '{ type nat hook postrouting priority srcnat; policy accept; }'

SNAT_COMMENT="prefix-nat $SRC_SUBNET->$DST_SUBNET via $IFACE"
DNAT_COMMENT="prefix-nat $DST_SUBNET->$SRC_SUBNET via $IFACE"

# Add rules (idempotent via comment check) — use heredoc so nft sees the quotes
if ! nft list chain ip nat "$PO_CHAIN" | grep -Fq -- "$SNAT_COMMENT"; then
  nft -f - <<EOF
add rule ip nat $PO_CHAIN \
  oifname "$IFACE" ip saddr $SRC_SUBNET \
  snat ip prefix to ip saddr map { $SRC_SUBNET : $DST_SUBNET } \
  comment "$SNAT_COMMENT"
EOF
fi

if ! nft list chain ip nat "$PR_CHAIN" | grep -Fq -- "$DNAT_COMMENT"; then
  nft -f - <<EOF
add rule ip nat $PR_CHAIN \
  iifname "$IFACE" ip daddr $DST_SUBNET \
  dnat ip prefix to ip daddr map { $DST_SUBNET : $SRC_SUBNET } \
  comment "$DNAT_COMMENT"
EOF
fi

# Persist the merged ruleset
CONF="/etc/nftables.conf"
BACKUP="/etc/nftables.conf.backup.$(date -Iseconds)"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

nft list ruleset > "$TMP"
nft -c -f "$TMP"  # sanity check

[[ -f "$CONF" ]] && { echo "Backing up $CONF -> $BACKUP"; cp -a "$CONF" "$BACKUP"; }
cp -f "$TMP" "$CONF"

systemctl enable nftables >/dev/null
systemctl reload nftables 2>/dev/null || systemctl restart nftables

echo "✅ Applied 1:1 prefix NAT: $SRC_SUBNET <-> $DST_SUBNET on $IFACE"
