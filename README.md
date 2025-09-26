# Vast Resources

This repository gathers my own maintenance utilities, configuration snippets, and quality-of-life helpers for Vast hosts. Use these resources to streamline day-to-day upkeep, diagnose hardware, and keep rigs efficient.

## Scripts

### scripts/pcie-inventory.sh
- Enumerates PCIe hardware that matters to Vast workloads: GPUs, network interfaces, and NVMe controllers.
- Depends on standard tooling that may require root privileges: `nvidia-smi` (for GPUs), `lspci`, `nvme`, `ethtool`, and `ip`.
- Run from the repo root with:
  ```bash
  sudo ./scripts/pcie-inventory.sh
  ```
- Produces a fixed-width table with TYPE, PCIe address, name, serial or MAC, and extra interface details. Rows are sorted so it is easy to diff between runs.

### scripts/ram-inventory.sh
- Lists every populated DIMM slot with manufacturer, part number, serial, capacity, and speed.
- Prefers `dmidecode -t 17` (requires sudo) and falls back to `lshw -C memory` when SMBIOS data is locked down.
- Example usage:
  ```bash
  sudo ./scripts/ram-inventory.sh
  ```
- Outputs an auto-sized table; unpopulated slots are skipped, and a helpful hint is shown when SMBIOS data is unavailable.

### Running the Scripts
Make the scripts executable once after cloning if needed:
```bash
chmod +x scripts/*.sh
```

## Related Resources

- [Vast Hosts Wiki](https://vastwiki.gno.red) - central knowledge base and troubleshooting playbook
- [Vast Monitor](https://github.com/begna112/vast-monitor) - companion monitoring tools and dashboards
