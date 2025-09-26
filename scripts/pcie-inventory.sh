#!/usr/bin/env bash
set -euo pipefail

have() { command -v "$1" &>/dev/null; }

SEP=$'\t'
declare -a ROWS=()
add_row() { ROWS+=("${1}${SEP}${2}${SEP}${3}${SEP}${4}${SEP}${5}"); }

pci_short() {
  local full="${1:-}"
  [[ "$full" =~ ([0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-9]) ]] && echo "${BASH_REMATCH[1]}" || echo "$full"
}
trim() { awk '{$1=$1;print}' <<< "${1:-}"; }

normalize_bdf() {
  local full="${1:-}"
  echo "${full/#00000000:/0000:}"
}

gpu_subsys_vendor() {
  local full; full="$(normalize_bdf "${1:-}")"
  have lspci || { echo ""; return; }
  local subs
  subs="$(lspci -s "$full" -vvvv 2>/dev/null | awk -F': ' '/^[[:space:]]*Subsystem:/{print $2; exit}')"
  [[ -z "$subs" ]] && { echo ""; return; }
  subs="${subs%% Device*}"
  echo "$(trim "$subs")"
}
pci_device_serial() {
  local full; full="$(normalize_bdf "${1:-}")"
  have lspci || { echo ""; return; }
  local dsn
  dsn="$(lspci -s "$full" -vvvv 2>/dev/null | awk -F'Device Serial Number ' '/Device Serial Number/{print $2; exit}')"
  echo "$(trim "${dsn:-}")"
}

# ---------------- GPUs ----------------
if have nvidia-smi; then
  while IFS=',' read -r idx bus_full name serial uuid; do
    bus_full=$(trim "$bus_full")
    bus_short=$(pci_short "$bus_full")
    name=$(trim "$name")
    serial=$(trim "${serial:-}")
    uuid=$(trim "${uuid:-}")

    subs_vendor="$(gpu_subsys_vendor "$bus_full")"
    [[ -n "$subs_vendor" ]] && name="${name} — ${subs_vendor}"

    if [[ -z "$serial" || "$serial" == "N/A" || "$serial" == "0" ]]; then
      dsn="$(pci_device_serial "$bus_full")"
      if [[ -n "$dsn" ]]; then
        serial="$dsn"
      else
        serial="$uuid"
      fi
    fi

    add_row "GPU" "$bus_short" "$name" "$serial" ""
  done < <(nvidia-smi --query-gpu=index,pci.bus_id,name,serial,uuid --format=csv,noheader 2>/dev/null || true)
fi

# ---------------- NICs ----------------
if have lspci; then
  declare -A PCI_DESC=()
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    pci_addr="${line%% *}"
    desc="$(sed 's/^[0-9a-fA-F:. \t-]*//' <<<"$line")"
    desc="$(sed 's/^[^:]*:[[:space:]]*//' <<<"$desc")"
    PCI_DESC["$pci_addr"]="$desc"
  done < <(lspci -Dnn | grep -iE 'Ethernet controller|Network controller' || true)

  for pci in "${!PCI_DESC[@]}"; do
    short=$(pci_short "$pci")
    nets_path="/sys/bus/pci/devices/$pci/net"
    if [[ -d "$nets_path" ]]; then
      for iface_path in "$nets_path"/*; do
        [[ -e "$iface_path" ]] || continue
        ifname="$(basename "$iface_path")"
        mac="$(cat "/sys/class/net/$ifname/address" 2>/dev/null || true)"
        if have ethtool; then
          perm="$(ethtool -P "$ifname" 2>/dev/null | awk '{print $3}' || true)"
          [[ -n "${perm:-}" ]] && mac="$perm"
        fi
        ip4="$(ip -o -4 addr show "$ifname" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1 || true)"
        extra="$ifname"
        [[ -n "$ip4" ]] && extra+=" ($ip4)"
        add_row "NIC" "$short" "${PCI_DESC[$pci]}" "$mac" "$extra"
      done
    else
      add_row "NIC" "$short" "${PCI_DESC[$pci]}" "" ""
    fi
  done
fi

# ---------------- NVMe ----------------
if have nvme; then
  shopt -s nullglob
  for ctrl in /dev/nvme[0-9]; do
    base="$(basename "$ctrl")"
    pci_path="$(realpath "/sys/class/nvme/$base/device" 2>/dev/null || true)"
    pci="$(basename "${pci_path:-}")"
    short="$(pci_short "$pci")"

    serial=""; model=""
    if out=$(nvme id-ctrl "$ctrl" 2>/dev/null); then
      model="$(sed -n 's/ *mn *: *//p' <<<"$out" | head -n1 | sed 's/[[:space:]]*$//')"
      serial="$(sed -n 's/ *sn *: *//p' <<<"$out" | head -n1 | sed 's/[[:space:]]*$//')"
    fi
    if [[ -z "$serial" || "$serial" == "-" ]]; then
      if line=$(nvme list 2>/dev/null | awk -v d="$ctrl" '$1==d{print}'); then
        lsn="$(awk '{print $2}' <<<"$line")"
        [[ -n "$lsn" ]] && serial="$lsn"
        [[ -z "$model" ]] && model="$(awk '{for(i=3;i<=NF;i++) printf (i==NF?$i:$i" ");}' <<<"$line")"
      fi
    fi
    if [[ -z "$serial" || "$serial" == "-" ]]; then
      dsn="$(pci_device_serial "$pci")"
      [[ -n "$dsn" ]] && serial="$dsn"
    fi

    add_row "NVMe" "$short" "$base" "$serial" "$model"
  done
  shopt -u nullglob
fi

# ---------------- Output ----------------
HEADER=("TYPE" "PCIe" "NAME" "SERIAL/MAC" "EXTRA")
declare -a W=( ${#HEADER[0]} ${#HEADER[1]} ${#HEADER[2]} ${#HEADER[3]} ${#HEADER[4]} )

for r in "${ROWS[@]}"; do
  IFS=$'\t' read -r c1 c2 c3 c4 c5 <<< "$r"
  (( ${#c1} > W[0] )) && W[0]=${#c1}
  (( ${#c2} > W[1] )) && W[1]=${#c2}
  (( ${#c3} > W[2] )) && W[2]=${#c3}
  (( ${#c4} > W[3] )) && W[3]=${#c4}
  (( ${#c5} > W[4] )) && W[4]=${#c5}
done

FMT="%-${W[0]}s  %-${W[1]}s  %-${W[2]}s  %-${W[3]}s  %-${W[4]}s\n"

# Header
printf "$FMT" "${HEADER[@]}"

# Underline
mkbar() { local n="$1"; local s; printf -v s "%*s" "$n" ""; echo "${s// /-}"; }
printf "$FMT" "$(mkbar "${W[0]}")" "$(mkbar "${W[1]}")" "$(mkbar "${W[2]}")" "$(mkbar "${W[3]}")" "$(mkbar "${W[4]}")"

# Rows
printf '%s\n' "${ROWS[@]}" \
  | LC_ALL=C sort -t"$SEP" -k1,1 -k2,2 \
  | while IFS=$'\t' read -r c1 c2 c3 c4 c5; do
      printf "$FMT" "$c1" "$c2" "$c3" "$c4" "$c5"
    done