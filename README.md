# BatteryManager

A macOS menu bar app for monitoring battery status and controlling charging on Apple Silicon Macs.

## Features

- Real-time battery stats: percentage, cycle count, health, temperature, voltage, amperage, wattage, capacity, and battery age
- Pause/resume charging via SMC (key `CHTE`)
- Auto charge management with configurable upper/lower bounds
- Animated menu bar icon with charge level indicator
- Pin the popover panel to keep it open
- Launch at login option

## Requirements

- macOS 14+
- Apple Silicon Mac
- Admin privileges for charge control

## Build & Run

```bash
./run.sh
```

Or manually:

```bash
swift build -c debug
.build/debug/BatteryManager
```

## How Charge Control Works

Pausing/resuming charging requires root access to write to the SMC. BatteryManager handles this as follows:

1. **First use**: When you enable charge control, macOS prompts for your admin password.
2. **Setup**: A compiled helper binary (`SMCWriter`) is installed at `/usr/local/bin/az-battery-manager-smc` (owned by root), along with a sudoers rule at `/etc/sudoers.d/az-battery-manager` that allows passwordless execution of the helper.
3. **Subsequent use**: Charge control works without password prompts.

The helper binary is a minimal executable with no AppKit/SwiftUI dependencies. It only writes the CHTE SMC key (Tahoe-era charging control). It is root-owned and not user-writable.

## Auto Charge Management

When enabled, the app automatically manages charging between configurable bounds:

- **Below lower bound**: Starts charging, continues until the upper bound is reached
- **Between bounds**: Holds (charging inhibited)
- **Above upper bound**: Inhibits charging; battery drains passively under system load

## Uninstall Admin Access

### From the UI

Click **Revoke Admin Access** in the app's popover panel. This removes the helper binary and sudoers rule (prompts for your admin password).

### From the command line

```bash
sudo rm -f /usr/local/bin/az-battery-manager-smc
sudo rm -f /etc/sudoers.d/az-battery-manager
```

## Troubleshooting

**"Pause Charging" does nothing / no password prompt appears**

The helper binary may be outdated (e.g., after rebuilding the project). Fix by revoking and re-granting access:

1. Click **Revoke Admin Access**
2. Click **Pause Charging** again — it will prompt for your password and install a fresh helper
