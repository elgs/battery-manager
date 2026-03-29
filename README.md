# BatteryManager

A lightweight macOS menu bar app for monitoring battery status and controlling charging on Apple Silicon Macs.

<p align="center">
  <img src="screenshot.png" alt="BatteryManager Screenshot" width="280">
</p>

## Installation

### Homebrew (Recommended)

```bash
brew tap elgs/taps
brew install --cask battery-manager
```

### Manual

Download the latest `.dmg` from the [GitHub Releases](https://github.com/elgs/battery-manager/releases) page, open it, and drag **BatteryManager.app** to your Applications folder.

## Features

- **Real-time battery stats** - percentage, cycle count, health, temperature, voltage, amperage, wattage, capacity, and battery age
- **Charge control** - pause and resume charging via SMC
- **Force discharge** - actively drain the battery while connected to AC power
- **Auto charge management** - configurable upper/lower bounds to keep your battery in an optimal charge range
- **Animated menu bar icon** - battery shape with live charge level indicator
- **Pinnable popover** - pin the panel to keep it open while you work
- **Launch at login** - start automatically when you log in

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon Mac
- Admin privileges (for charge control features)

## How Charge Control Works

Pausing/resuming charging requires root access to write to the SMC. BatteryManager handles this as follows:

1. **First use** - when you enable charge control, macOS prompts for your admin password.
2. **Setup** - a compiled helper binary (`SMCWriter`) is installed at `/usr/local/bin/az-battery-manager-smc` (owned by root), along with a sudoers rule at `/etc/sudoers.d/az-battery-manager` that allows passwordless execution of the helper.
3. **Subsequent use** - charge control works without password prompts.

The helper binary is a minimal executable with no AppKit/SwiftUI dependencies. It writes two SMC keys: **CHTE** (charge inhibit) and **CHIE** (force discharge). It is root-owned and not user-writable.

## Auto Charge Management

When enabled, the app automatically manages charging between configurable bounds:

- **Below lower bound** - starts charging, continues until the upper bound is reached
- **Between bounds** - holds (charging inhibited)
- **Above upper bound** - inhibits charging; battery drains passively under system load

## Force Discharge

Force discharge causes the Mac to run on battery power while the AC adapter remains connected. This is useful for draining the battery to a target level for calibration or health management.

### SMC Keys

| Key | Type | Description |
|-----|------|-------------|
| `CHTE` | `ui32` (4 bytes) | Charge terminate / inhibit. `1` = charging paused, `0` = charging allowed. |
| `CHIE` | `hex_` (1 byte) | Charge inhibit enable / force discharge. `0x08` = discharge active, `0x00` = normal. |

Both keys are written via IOKit's `IOConnectCallStructMethod` (selector 2) to the `AppleSMCKeysEndpoint` service (falling back to `AppleSMC`). Writing requires root privileges.

### Clamshell Mode and the Black Screen Problem

Writing `CHIE = 0x08` triggers a USB-C Power Delivery (PD) renegotiation, which briefly disrupts the display signal on the Thunderbolt/USB-C port. This causes a specific problem in **clamshell mode** (lid closed with external monitors):

1. The CHIE write causes a momentary display disconnect.
2. macOS detects "no displays available" and triggers clamshell sleep.
3. External monitors go permanently black until the lid is opened.

With the lid open, the internal display keeps the system awake through the brief PD disruption, so external monitors reconnect immediately.

#### What didn't work

| Approach | Result |
|----------|--------|
| `caffeinate -dis` (power assertions) | Assertions don't prevent PD-triggered clamshell sleep |
| `IOPMAssertionCreateWithName` (from root and GUI processes) | Same — assertions insufficient for hardware-level PD events |
| `IORegistryEntrySetCFProperty` / `IOConnectSetCFProperty` on `IOPMrootDomain` | Permission denied on Apple Silicon (`kIOReturnUnsupported`) |
| Writing `CH0R` instead of `CHIE` | No blackout, but doesn't actually enable discharge |
| Signal handlers (`SIGTERM`/`SIGHUP`) for cleanup | Swift runtime is not async-signal-safe; cleanup code crashed |
| `fork()` to daemonize the watchdog | Swift/ObjC runtime is not fork-safe; child process crashed |

#### What works

**`pmset -a sleep 0 disablesleep 1`** before the CHIE write. This disables all system sleep at the OS level, preventing macOS from sleeping during the PD disruption. This is the same mechanism used by AlDente's privileged helper daemon (discovered by running `strings` on their helper binary and finding `disableSleepWhenClosedWithDisabled:withReply:`).

When discharge is stopped, sleep is restored to the user's original setting via `pmset -a sleep <original> disablesleep 0`. The original sleep value is saved to `/tmp/.battery_manager_saved_sleep` before being overridden.

**Trade-off:** While force discharge is active, the Mac cannot go to sleep (idle sleep, lid close, etc.). This is inherent to the approach — the whole point is to prevent clamshell sleep during PD disruption. Sleep is restored immediately when discharge is stopped.

### Watchdog Daemon

When force discharge is activated, the SMCWriter spawns a **watchdog daemon** via `posix_spawn`. The daemon:

1. Runs as a detached root process (independent of the app and sudo process chain).
2. Polls the app's PID every 2 seconds.
3. If the app dies (crash, `kill -9`, etc.), the watchdog cleans up within 2 seconds:
   - Clears `CHIE = 0x00` (stops discharge)
   - Restores sleep settings via `pmset`
   - Exits

This prevents the battery from draining indefinitely if the app is force-killed. The watchdog is spawned with `posix_spawn` (not `fork`) because the Swift/ObjC runtime is not fork-safe — forked children crash when using Foundation, IOKit, or Objective-C APIs.

On app launch, any orphaned watchdog processes from a previous crash are killed via `pkill`, and CHIE/sleep settings are unconditionally cleared.

### Architecture

```
BatteryManager (GUI, user)
  |
  |-- sudo SMCWriter discharge:<app-pid>    (one-shot, root)
  |     |-- pmset -a sleep 0 disablesleep 1
  |     |-- SMC write CHIE = 0x08
  |     |-- posix_spawn SMCWriter watchdog:<app-pid>
  |     \-- exit(0)
  |
  |-- SMCWriter watchdog:<app-pid>           (daemon, root, detached)
  |     |-- sleep(2) loop
  |     |-- if app PID gone: clear CHIE, restore pmset, exit
  |     \-- (self-exits when app dies)
  |
  |-- sudo SMCWriter nodischarge             (one-shot, root, on stop)
  |     |-- SMC write CHIE = 0x00
  |     |-- pmset -a sleep <original> disablesleep 0
  |     \-- exit(0)
  |
  \-- pkill watchdog                         (cleanup)
```

## Build from Source

```bash
./run.sh
```

Or manually:

```bash
swift build -c debug
.build/debug/BatteryManager
```

## Uninstall

### Remove the app

```bash
brew uninstall battery-manager
```

Or delete `BatteryManager.app` from Applications.

### Remove SMCWriter and admin access

Charge control installs two privileged files that persist after the app is deleted:

- `/usr/local/bin/az-battery-manager-smc` - the SMCWriter helper binary (runs as root to write SMC keys)
- `/etc/sudoers.d/az-battery-manager` - the sudoers rule that allows passwordless execution of the helper

**From the UI:** Click **Revoke Admin Access** in the app's popover panel. This removes both files (prompts for your admin password).

**From the command line:**

```bash
sudo rm -f /usr/local/bin/az-battery-manager-smc
sudo rm -f /etc/sudoers.d/az-battery-manager
```

## Troubleshooting

**"Pause Charging" does nothing / no password prompt appears**

The helper binary may be outdated (e.g., after rebuilding the project). Fix by revoking and re-granting access:

1. Click **Revoke Admin Access**
2. Click **Pause Charging** again - it will prompt for your password and install a fresh helper

## License

MIT
