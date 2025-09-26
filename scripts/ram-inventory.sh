#!/usr/bin/env bash
set -euo pipefail

have() { command -v "$1" &>/dev/null; }
trim() { awk '{$1=$1;print}' <<< "${1:-}"; }

if ! have dmidecode && ! have lshw; then
  echo "Need dmidecode (preferred) or lshw. Install dmidecode and run with sudo."
  exit 1
fi

SEP=$'\t'
declare -a ROWS=()
add_row() { ROWS+=("${1}${SEP}${2}${SEP}${3}${SEP}${4}${SEP}${5}${SEP}${6}"); }

# ---- Parse dmidecode Type 17 (Memory Device) ----
parse_dmidecode() {
  local out
  out="$(dmidecode -t 17 2>/dev/null || true)"
  [[ -z "$out" ]] && out="$(dmidecode -t memory 2>/dev/null || true)"
  [[ -z "$out" ]] && return 0

  awk -v RS= -v OFS='\t' '
    BEGIN { IGNORECASE=1 }
    {
      if ($0 !~ /\n[ \t]*Memory Device[ \t]*\n/ && $0 !~ /DMI type[ \t]*17/) next;

      size=""; mfr=""; serial=""; part=""; loc=""; bank=""; speed=""; cspeed="";
      split($0, lines, "\n");
      for (i=1; i<=length(lines); i++) {
        line=lines[i]; sub(/^[[:space:]]+/, "", line);
        if (line ~ /^Size:/)                          { sub(/^[^:]*: */, "", line); size=line }
        else if (line ~ /^Manufacturer:/)             { sub(/^[^:]*: */, "", line); mfr=line }
        else if (line ~ /^Serial Number:/)            { sub(/^[^:]*: */, "", line); serial=line }
        else if (line ~ /^Part Number:/)              { sub(/^[^:]*: */, "", line); part=line }
        else if (line ~ /^Locator:/)                  { sub(/^[^:]*: */, "", line); loc=line }
        else if (line ~ /^Bank Locator:/)             { sub(/^[^:]*: */, "", line); bank=line }
        else if (line ~ /^Configured Memory Speed:/)  { sub(/^[^:]*: */, "", line); cspeed=line }
        else if (line ~ /^Speed:/)                    { sub(/^[^:]*: */, "", line); speed=line }
      }

      # Skip unpopulated / unknown
      if (size ~ /No Module Installed|Unknown|^$|^0[[:space:]]*(MB|MiB|B)?$/) next

      # Normalize whitespace
      gsub(/[[:space:]]+$/, "", mfr); gsub(/[[:space:]]+$/, "", serial); gsub(/[[:space:]]+$/, "", part);
      gsub(/[[:space:]]+$/, "", loc); gsub(/[[:space:]]+$/, "", bank); gsub(/[[:space:]]+$/, "", size);
      gsub(/[[:space:]]+$/, "", speed); gsub(/[[:space:]]+$/, "", cspeed);

      # Prefer configured speed when valid
      final_speed = (cspeed != "" && cspeed !~ /Unknown|Unsupported|N\/A/) ? cspeed : speed;

      # Clean placeholders
      if (mfr ~ /Unknown|Not Specified|NO DIMM|N\/A/) mfr="";
      if (part ~ /Unknown|Not Specified|NO DIMM|N\/A/) part="";
      if (serial ~ /Unknown|Not Specified|NO DIMM|N\/A/) serial="";
      if (final_speed ~ /Unknown|Not Specified|N\/A/) final_speed="";

      # Build SLOT: prefer Bank Locator; append Locator only if it adds info and isn’t just "DIMM 0"
      slot = bank;
      lowloc = tolower(loc);
      if (loc != "" && lowloc !~ /^dimm 0$/ && loc != bank) {
        slot = (bank != "" ? bank " / " loc : loc);
      }
      if (slot == "") slot = (loc != "" ? loc : bank);

      print slot, mfr, part, serial, size, final_speed;
    }
  ' <<< "$out"
}

# ---- Fallback: lshw (for systems with locked SMBIOS) ----
parse_lshw() {
  have lshw || return 0
  local out
  out="$(lshw -C memory 2>/dev/null || true)"
  [[ -z "$out" ]] && return 0

  awk -v RS="\n\\*-|^\\*-memory" -v OFS='\t' '
    BEGIN { IGNORECASE=1 }
    /bank/ {
      slot=""; mfr=""; model=""; serial=""; size=""; speed="";
      gsub(/\r/, "", $0);
      if (match($0, /slot: *([^\n]+)/, m))   slot=m[1];
      if (match($0, /vendor: *([^\n]+)/, m)) mfr=m[1];
      if (match($0, /product: *([^\n]+)/, m)) model=m[1];
      if (match($0, /serial: *([^\n]+)/, m)) serial=m[1];
      if (match($0, /size: *([^\n]+)/, m))  size=m[1];
      if (match($0, /clock: *([^\n]+)/, m)) speed=m[1];
      if (size == "" || size ~ /No Module Installed|unknown/) next;
      print slot, mfr, model, serial, size, speed;
    }
  ' <<< "$out"
}

# ---- Collect rows ----
if have dmidecode; then
  while IFS=$'\t' read -r SLOT MFR MODEL SERIAL SIZE SPEED; do
    [[ -z "${SLOT}${MFR}${MODEL}${SERIAL}${SIZE}${SPEED}" ]] && continue
    add_row "$(trim "$SLOT")" "$(trim "$MFR")" "$(trim "$MODEL")" "$(trim "$SERIAL")" "$(trim "$SIZE")" "$(trim "$SPEED")"
  done < <(parse_dmidecode)
fi

if ((${#ROWS[@]} == 0)); then
  while IFS=$'\t' read -r SLOT MFR MODEL SERIAL SIZE SPEED; do
    [[ -z "${SLOT}${MFR}${MODEL}${SERIAL}${SIZE}${SPEED}" ]] && continue
    add_row "$(trim "$SLOT")" "$(trim "$MFR")" "$(trim "$MODEL")" "$(trim "$SERIAL")" "$(trim "$SIZE")" "$(trim "$SPEED")"
  done < <(parse_lshw)
fi

# ---- Output (auto-size columns) ----
HEADER=("SLOT" "MANUFACTURER" "MODEL" "SERIAL" "SIZE" "SPEED")
declare -a W=( ${#HEADER[0]} ${#HEADER[1]} ${#HEADER[2]} ${#HEADER[3]} ${#HEADER[4]} ${#HEADER[5]} )

for r in "${ROWS[@]}"; do
  IFS=$'\t' read -r c1 c2 c3 c4 c5 c6 <<< "$r"
  (( ${#c1} > W[0] )) && W[0]=${#c1}
  (( ${#c2} > W[1] )) && W[1]=${#c2}
  (( ${#c3} > W[2] )) && W[2]=${#c3}
  (( ${#c4} > W[3] )) && W[3]=${#c4}
  (( ${#c5} > W[4] )) && W[4]=${#c5}
  (( ${#c6} > W[5] )) && W[5]=${#c6}
done

FMT="%-${W[0]}s  %-${W[1]}s  %-${W[2]}s  %-${W[3]}s  %-${W[4]}s  %-${W[5]}s\n"

mkbar() { local n="$1"; local s; printf -v s "%*s" "$n" ""; echo "${s// /-}"; }

printf "$FMT" "${HEADER[@]}"
printf "$FMT" "$(mkbar "${W[0]}")" "$(mkbar "${W[1]}")" "$(mkbar "${W[2]}")" "$(mkbar "${W[3]}")" "$(mkbar "${W[4]}")" "$(mkbar "${W[5]}")"

if ((${#ROWS[@]})); then
  printf '%s\n' "${ROWS[@]}" \
    | LC_ALL=C sort -t"$SEP" -k1,1 \
    | while IFS=$'\t' read -r c1 c2 c3 c4 c5 c6; do
        printf "$FMT" "$c1" "$c2" "$c3" "$c4" "$c5" "$c6"
      done
else
  echo "No populated DIMMs found. On some VMs/hosts SMBIOS is hidden; try: sudo dmidecode -t 17"
fi
