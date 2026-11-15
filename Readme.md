# qFT8 Pi Bridge with OLED

Turn a Raspberry Pi Zero 2 WH into a headless qFT8 radio bridge with a Wi-Fi hotspot, physical controls, and an SH1106 status display. This installer targets **Raspberry Pi OS Trixie, 64-bit**, with an IC-7300 connected by USB.

**This script and its supporting files were made using AI (OpenAI ChatGPT/Codex), guided by the project owner's requirements.** AI-generated code can contain mistakes. Offline checks are included; this refactored edition still needs validation on the actual Raspberry Pi, radio, and OLED.

This is an independent installation project. qFT8 is developed and distributed separately through the [official qFT8 project](https://github.com/lquesada/qFT8) and [qft8.com](https://qft8.com/).

## Features

- Native Linux ARM64 qFT8 at `/opt/qft8/qFT8`, with no Java runtime or JAR launcher installed.
- Latest stable version discovered from official release metadata, with SHA-256 verification before installation.
- Hotspot preferred at boot; a button requests connection to your saved router WLAN.
- Automatic update check when client WLAN obtains an IPv4 address, with OLED progress and rollback if the updated service fails its startup check.
- SH1106 128×64 OLED: early Linux boot message, version heading in the top 16-pixel yellow band, three status pages, and idle dimming.
- DS3231 real-time clock configuration, USB radio reconnection monitoring, user-session PipeWire audio, a read-only status page, and bounded journal storage.

## Hardware and wiring

Use a Pi Zero 2 WH with a 64-bit Trixie installation, internet access for setup, a USB radio connection, an SH1106 I²C display, and two normally open pushbuttons. The display can be a compatible four-pin module from an ATU-100 tuner. Check its actual pin labels and supply requirements; do not assume the connector order. I²C signals must be compatible with the Pi's 3.3 V logic.

| Connection | BCM GPIO | Physical header pin |
| --- | --- | --- |
| OLED and DS3231 SDA | GPIO2 | 3 |
| OLED and DS3231 SCL | GPIO3 | 5 |
| WLAN/page button | GPIO17 | 11 |
| Shutdown button | GPIO27 | 13 |
| Shared ground | GND | e.g. 6 |

Each button connects its GPIO to ground when pressed; the controller enables internal pull-ups. The OLED and DS3231 share I²C bus 1. The OLED address defaults to `0x3C`; `0x3D` is also supported. GPIO22/23/24 are unused. Do not attach a wake button to GPIO3 because it is used for I²C.

The yellow band is a physical property of the OLED, not a software color setting. The installer reserves rows 0–15 for the heading and 16–63 for information.

## Installation

Download this project's files to the Pi and open a terminal in that folder. Use a normal login account with sudo access, rather than logging in directly as root. Prefer a local keyboard/screen or a connection independent of the Pi's WLAN: network configuration can interrupt SSH.

```bash
cp config.example.sh config.sh
chmod 600 config.sh
nano config.sh
```

Enter your hotspot password, router SSID/password, bridge name/password, and country code. Both WLAN passwords must have 8–63 characters; the bridge password must have at least 7. Replace every `CHANGE_ME` value. `TX_VOLUME` controls transmit audio volume, not RF output power.

The configuration file is **Bash code executed with administrator privileges**. Use only your own trusted file. Keep values quoted; a single quote inside a single-quoted value requires Bash escaping. `config.sh` is ignored by Git, but remains your responsibility to protect when copying files or sharing archives.

```bash
sudo bash install.sh ./config.sh
sudo reboot
```

The installer checks the OS release and ARM64 architecture, installs dependencies, downloads qFT8, writes service/configuration files, sets up networking and hardware support, and starts services. The reboot applies the I²C/RTC boot settings. The installer itself does not reboot automatically.

The main script includes its Python helpers and service definitions, so it can also be copied by itself together with your private configuration. No build step is needed.

## Controls

| Button action | Result |
| --- | --- |
| WLAN held for more than 50 ms and up to 1000 ms, then released | Next OLED page; if dimmed, the first press only wakes the display |
| WLAN held for more than 1 second but less than 3 seconds | No action |
| WLAN held for at least 3 seconds | Connect to the saved client WLAN |
| Shutdown held for at least 5 seconds | Request safe system shutdown |

The WLAN hold requests client mode; it does not toggle back to the hotspot. Failure to connect restores the hotspot. The controller also attempts hotspot recovery if a button-established client connection is lost. Hotspot preference returns at reboot. Buttons are sampled approximately every 10 ms, so timing at the boundaries is approximate. Network commands can temporarily delay processing queued actions; the five-second shutdown hold is a recognition threshold, not a guaranteed shutdown completion time. Wait for shutdown to finish before removing power.

## Display pages

The heading reads `qFT8 BRIDGE v<installed version>`. Long headings are fitted to the screen. Update, recovery, and shutdown messages temporarily replace normal pages.

1. **Bridge:** service state, USB radio detection, WLAN mode, and IPv4 address. USB detection does not prove that CAT control or audio works.
2. **System:** per-core CPU usage percentages averaged over a rolling five-minute window, used/total RAM in MiB, CPU temperature, and measured ARM clock with firmware limit status. Statistics refresh every five seconds. The CPU averaging window fills after controller startup. A low clock by itself is normal power saving; warnings use firmware flags. `PAST LIMIT` means a limit was recorded earlier since boot. No supply-voltage reading is claimed.
3. **Storage/network:** free/total root filesystem space in GiB, last-known WLAN signal percentage, uptime, and the last completed update result. Signal strength uses cached NetworkManager data without forcing a scan; it is not applicable in hotspot mode. Uptime is hours/minutes for the first day, then days/hours.

Defaults are 60 seconds before dimming, normal contrast 96, and dim contrast 8. Change `OLED_DIM_AFTER`, `OLED_CONTRAST`, and `OLED_DIM_CONTRAST` in `config.sh`, then rerun the installer. A delay of 0 disables dimming. Long button actions wake the screen and still perform their action.

The boot message appears once Linux has loaded the necessary filesystems and I²C support. It cannot show the Pi firmware's first boot stage. Battery monitoring is intentionally outside this project.

## Updates and rerunning

The installer uses the official repository's [latest release API](https://api.github.com/repos/lquesada/qFT8/releases/latest). It selects the numerically highest stable `linux-arm64` archive offered by that release, using the asset URL supplied in the response. It does not construct a guessed download URL. SHA-256 comes from the asset digest or the matching published checksum file; missing or mismatched checksums stop installation.

During ordinary operation, entering the `qft8-maintenance` profile with an IPv4 address requests one update check per connection. There is no periodic polling while staying connected. The updater installs only a newer version. The bridge continues running during download; installation briefly stops and restarts it. A failed startup check attempts to restore the saved executable and version. That check verifies service startup, not successful radio contacts. Downloads/checks require working internet access; errors appear on the OLED and in the journal.

Completed results survive reboot in `/var/lib/qft8/last-update.json`. The previous executable and version are saved in `/opt/qft8/qFT8.previous` and `/opt/qft8/VERSION.previous` during automatic upgrades.

Rerunning the installer is a full reconfiguration, not just a version check. It downloads the current official release again, rewrites helper/service/settings files, reapplies package requirements, and restarts services. Existing qFT8 Wi-Fi profiles are updated in place rather than deleted; active profile changes may require reconnecting or rebooting. Automatic connection is disabled for other saved Wi-Fi profiles so they cannot take precedence over the hotspot. Existing boot overlay entries are checked before appending. Logs and persistent update results are retained. Do not run the installer concurrently with an automatic update or another installer instance. Full installation is not transactional; automatic-update rollback does not cover an interrupted full reinstall.

The obsolete qFT8 JAR and old bridge launcher are removed. Previously installed Java packages are not automatically uninstalled, because other applications may still need them.

## Services, files, and troubleshooting

| Service | Purpose |
| --- | --- |
| `qft8-bridge.service` | Native bridge under the normal sudo user's account |
| `qft8-oled-boot.service` | One-time early boot display |
| `qft8-controller.service` | Buttons, OLED, WLAN and USB radio monitoring |
| `qft8-update.service` | On-demand download, verification and installation |
| `qft8-status.service` | Read-only HTTP status page on port 8080 |

The status page is available at `http://192.168.50.1:8080/` with the default hotspot address, or at the Pi's client address. `/health` only confirms that the HTTP handler responds. Unavailable readings are shown explicitly; the restricted web service may not have permission to read the hardware clock.

```bash
systemctl status qft8-bridge qft8-controller qft8-status
sudo journalctl -u qft8-controller.service -n 50 --no-pager
sudo journalctl -u qft8-update.service -n 50 --no-pager
sudo journalctl -u qft8-oled-boot.service -b --no-pager
cat /opt/qft8/VERSION
nmcli connection show
```

If the OLED stays blank, confirm wiring, its address, and a reboot after installation; then inspect the boot/controller journal. For audio/CAT failures, check radio settings and USB connectivity as well as the bridge journal.

Settings are under `/etc/qft8`, helper programs under `/usr/local/lib/qft8`, temporary progress under `/run/qft8-update`, and service units under `/etc/systemd/system`. Journald is configured for 64 MiB persistent and 16 MiB runtime storage limits. Linux may apply its own retention constraints as well.

## Security

The bridge runs as the normal account that invoked sudo, with its audio environment and `/etc/qft8/bridge.env`. systemd's `${VARIABLE}` argument expansion preserves each bridge setting as one argument; no shell command launcher is involved. See the [systemd command-line rules](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html#Command%20lines).

The bridge retains `AmbientCapabilities=CAP_SYS_ADMIN`, `CapabilityBoundingSet=CAP_SYS_ADMIN`, and `NoNewPrivileges=yes` for the serial-port workaround. **CAP_SYS_ADMIN is a powerful, broad Linux capability.** Running as a normal user and enabling `NoNewPrivileges` does not make this a tightly isolated service. The installer, controller, and updater also perform privileged system operations.

Checksums detect changed/corrupt downloads relative to the published metadata; a checksum obtained from the same upstream is not an independent signature or protection against an upstream compromise. The project trusts the official release source.

SSH is enabled. The status page listens on all IPv4 interfaces, is unencrypted, and has no authentication; it exposes device/network status. Keep these services on trusted networks and do not forward them to the public internet. Do not commit private configuration or old installer copies containing credentials.

## Development and checks

`install.sh` is the source of truth. It contains the complete installation sequence and the helper programs written onto the Pi. Comments explain operational intent and relevant Linux concepts rather than repeating every directive.

From the project directory:

```bash
bash -n install.sh
bash -n config.example.sh
python3 -B tests/run.py
```

The runner extracts all six embedded Python files, checks their syntax, and exercises release selection, checksum rejection, update installation and rollback, button boundaries, CPU averaging, dimming/wake behavior, uptime, and update connection transitions. System commands and hardware are mocked; these checks do not execute the installer, contact release servers, or validate real GPIO/I²C/audio/systemd operation. Python 3.10 or newer is needed for the offline suite. Hardware acceptance testing is still required before relying on this revision.

The refactor preserves the established behavior while separating private settings, retaining Wi-Fi profile UUIDs, combining network status queries, polling bridge state every five seconds instead of every second, and reducing repetitive comments. Network profile edits follow the [NetworkManager nmcli interface](https://networkmanager.dev/docs/api/latest/nmcli.html).

## Publication and licensing

Publish this directory's files, not older private installers. `.gitignore` excludes the normal local configuration file but does not remove secrets already committed to Git history.

These installation scripts and supporting project files are licensed under the [MIT License](LICENSE). qFT8 itself remains subject to its own upstream license and distribution terms; its executable is downloaded during installation and is not included here.
