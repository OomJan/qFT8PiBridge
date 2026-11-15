#!/usr/bin/env bash
# qFT8 Pi Bridge — Raspberry Pi OS Trixie ARM64 installer.
# Created with AI assistance (OpenAI ChatGPT/Codex); see Readme.md.
# Copy config.example.sh to config.sh, edit it, then run:
#   sudo bash install.sh ./config.sh
# The configuration is trusted Bash code, executed as administrator.
# Read Readme.md before installing. Reruns rewrite settings/restart services.
# Comments explain the purpose of each installation step. Embedded PY/EOF
# blocks create helper programs and service files; keep end markers unindented.

set -Eeuo pipefail
# Raspberry Pi OS Trixie / Pi Zero 2 WH / qFT8 / IC-7300
# EDIT THESE VALUES

# =============================================================================
# STEP 1: YOUR SETTINGS
# Review these values before running the installer. They are reused when configuration files are written.
# =============================================================================
# Wi-Fi network name that the Pi broadcasts in hotspot mode.
AP_SSID='qFT8-Bridge'
# Password used by your phone/computer to join the Pi hotspot (8 to 63 characters).
AP_PASSWORD=''
# Name of your existing router Wi-Fi; spelling and capital letters must match.
CLIENT_SSID=''
# Password for that router Wi-Fi (this script accepts 8 to 63 characters).
CLIENT_PASSWORD=''
# Password for connecting a qFT8 client to this radio bridge (at least 7 characters).
BRIDGE_PASSWORD=''
# Name shown to qFT8 clients when they choose this bridge.
BRIDGE_NAME='IC7300-Bridge'
# Transmit audio-volume value passed to qFT8; this does not set the radio RF power.
TX_VOLUME=70
# Two-letter Wi-Fi country code used for local radio-channel rules.
COUNTRY='DE'
# Pi address on its own hotspot. The status page uses this address on port 8080.
AP_IP='192.168.50.1'
# Linux name of the wireless adapter; wlan0 is the expected adapter here.
WIFI_IF='wlan0'
OLED_I2C_BUS=1
OLED_I2C_ADDRESS=0x3C # Change to 0x3D if your module uses that address.
# Seconds without a recognized button action before dimming; 0 disables dimming.
OLED_DIM_AFTER=60
# SH1106 contrast values, from 0 to 255. These are not percentages.
OLED_CONTRAST=96
OLED_DIM_CONTRAST=8
# Resolve the latest stable ARM64 asset from the official release on every run.
QFT8_RELEASE_API='https://api.github.com/repos/lquesada/qFT8/releases/latest'
# Load the explicitly selected private configuration; never search the current
# directory automatically when running with administrator privileges.
[[ $# -eq 1 && -f "$1" ]] || { echo "Usage: sudo bash $0 ./config.sh" >&2; exit 1; }
source -- "$1"

# GPIO BCM: maintenance 17, shutdown 27; GPIO22/23/24 are unused.
# SH1106 128x64: I2C-1 SDA=GPIO2 (pin 3), SCL=GPIO3 (pin 5).
# Physical yellow band: rows 0-15; status text uses rows 16-63.
# Use 3.3 V-compatible I2C levels; check the salvaged module pin labels.
# Hardware: DS3231 at I2C-1 (SDA2/SCL3) - do not use GPIO3 wake button.


# =============================================================================
# STEP 2: CHECK THE PI AND YOUR INPUT
# Refuse an unsuitable operating system, processor type, administrator login or invalid settings before installing software.
# =============================================================================
fail() { echo "ERROR: $*" >&2; exit 1; }
# Report the failed step without printing a command that might contain a password.
trap 'echo "Installation stopped at line $LINENO. Fix the error before rerunning." >&2' ERR
for name in AP_SSID CLIENT_SSID AP_PASSWORD CLIENT_PASSWORD BRIDGE_PASSWORD; do
  [[ -n "${!name}" && "${!name}" != CHANGE_ME* ]] || fail "Set $name in your private configuration"
done
# These settings are inserted into single-line configuration files.
for value in "$AP_SSID" "$CLIENT_SSID" "$AP_PASSWORD" "$CLIENT_PASSWORD" "$AP_IP" "$WIFI_IF"; do
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || fail 'Settings must not contain line breaks'
done
[[ "$WIFI_IF" =~ ^[a-zA-Z0-9_.-]+$ ]] || fail 'Invalid wireless interface name'
[[ "$COUNTRY" =~ ^[A-Z]{2}$ ]] || fail 'COUNTRY must be two uppercase letters'
[[ "$TX_VOLUME" =~ ^[0-9]+$ ]] || fail 'TX_VOLUME must be a non-negative integer'

# Require administrator permission, supplied by sudo.
[[ $EUID -eq 0 ]] || fail 'Run with sudo'
# Remember the real user behind sudo; refuse a direct root login.
[[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]] || fail 'Run sudo from normal account'
# Read the Linux distribution information supplied by the operating system.
source /etc/os-release
# Check that the operating-system release is Trixie.
[[ "${VERSION_CODENAME:-}" == trixie ]] || fail 'Raspberry Pi OS Trixie required'
# Check both Wi-Fi password lengths before changing network settings.
[[ ${#AP_PASSWORD} -ge 8 && ${#AP_PASSWORD} -le 63 && ${#CLIENT_PASSWORD} -ge 8 && ${#CLIENT_PASSWORD} -le 63 ]] || fail 'WPA password length invalid'
# Check the minimum bridge-password length.
[[ ${#BRIDGE_PASSWORD} -ge 7 ]] || fail 'Bridge password too short'
# Require ARM64: a 32-bit operating system cannot run this downloaded program.
[[ "$(dpkg --print-architecture)" == arm64 ]] || fail '64-bit ARM Raspberry Pi OS required'
# Reject line breaks in settings that must occupy a single line in the saved file.
for value in "$BRIDGE_NAME" "$BRIDGE_PASSWORD" "$TX_VOLUME"; do
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || fail 'Bridge settings must be single-line values'
done
# Require a numeric I2C bus number.
[[ "$OLED_I2C_BUS" =~ ^[0-9]+$ ]] || fail 'Invalid OLED I2C bus'
# Accept the two OLED addresses supported by this installer.
[[ "$OLED_I2C_ADDRESS" == 0x3C || "$OLED_I2C_ADDRESS" == 0x3D ]] || fail 'OLED address must be 0x3C or 0x3D'
# Find your user name, numeric user ID, and primary group for the bridge/audio services.
# Validate brightness settings before writing configuration files.
[[ "$OLED_DIM_AFTER" =~ ^[0-9]{1,5}$ ]] || fail 'OLED_DIM_AFTER must be 0 to 99999 seconds'
for level in "$OLED_CONTRAST" "$OLED_DIM_CONTRAST"; do
  [[ "$level" =~ ^[0-9]{1,3}$ ]] || fail 'OLED contrast must be an integer from 0 to 255'
  (( 10#$level <= 255 )) || fail 'OLED contrast must be 0 to 255'
done
(( 10#$OLED_DIM_CONTRAST <= 10#$OLED_CONTRAST )) || fail 'Dim contrast must not exceed normal contrast'
RUN_USER="$SUDO_USER"
RUN_UID="$(id -u "$RUN_USER")"
RUN_GROUP="$(id -gn "$RUN_USER")"

# =============================================================================
# STEP 3: INSTALL REQUIRED LINUX SOFTWARE
# Refresh the package list, then install the networking, audio, Python, OLED and GPIO tools this setup needs.
# =============================================================================
apt-get update
# Install packages without interactive questions. Existing listed packages may also be upgraded.
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    network-manager openssh-server python3 python3-libgpiod python3-luma.oled \
    python3-pil fonts-dejavu-core raspi-utils gpiod i2c-tools \
    curl ca-certificates tar gzip alsa-utils \
    usbutils pipewire pipewire-pulse wireplumber dbus-user-session
install -d -m 755 /opt/qft8 /etc/qft8 /usr/local/lib/qft8
# Shared release resolver used by the installer and WLAN updater.

# =============================================================================
# STEP 4: CREATE THE OFFICIAL RELEASE LOOKUP HELPER
# The Python program below selects the newest stable ARM64 download and its SHA-256 checksum.
# =============================================================================
cat > /usr/local/lib/qft8/qft8_release.py <<'PY'
import json
import re
import sys
import urllib.request

# Read the download link supplied by the official release; reject links outside its repository.
def asset_url(asset):
    url = asset.get('browser_download_url', '')
    if not url.startswith('https://github.com/lquesada/qFT8/releases/download/') or any((c.isspace() for c in url)):
        raise ValueError('Invalid official release asset URL')
    return url

# Choose the newest stable ARM64 archive and its published SHA-256 fingerprint.
def select_release(release):
    if release.get('draft') or release.get('prerelease'):
        raise ValueError('Refusing a draft or prerelease')
    assets = release.get('assets', [])
    candidates = []
    # The upstream rolling "main" release contains several versions at once.
    # Compare numeric components: 3.30 is newer than 3.9; ignore beta/RC assets.
    for asset in assets:
        match = re.fullmatch('qFT8-v([0-9]+(?:\\.[0-9]+)*)-linux-arm64\\.tar\\.gz', asset.get('name', ''))
        if match:
            version = match.group(1)
            candidates.append((tuple(map(int, version.split('.'))), version, asset))
    if not candidates:
        raise ValueError('No stable Linux ARM64 qFT8 archive in the latest release')
    _, version, asset = max(candidates, key=lambda item: item[0])
    url = asset_url(asset)
    digest = asset.get('digest') or ''
    if re.fullmatch('sha256:[0-9a-fA-F]{64}', digest):
        checksum = digest.split(':', 1)[1].lower()
    else:
        # Older GitHub assets may lack a digest: use the exact published checksum file.
        sums = [a for a in assets if a.get('name') == f'qFT8-v{version}-SHA256SUMS.txt']
        if len(sums) != 1:
            raise ValueError('No published SHA-256 for the newest ARM64 archive')
        request = urllib.request.Request(asset_url(sums[0]), headers={'User-Agent': 'qft8-pi-installer'})
        with urllib.request.urlopen(request, timeout=30) as response:
            if not response.geturl().startswith('https://'):
                raise ValueError('Checksum download redirected away from HTTPS')
            text = response.read(1024 * 1024).decode('utf-8-sig')
        matches = []
        for line in text.splitlines():
            entry = re.fullmatch('([0-9a-fA-F]{64})[ \\t]+\\*?(.+)', line)
            if entry and entry.group(2) == asset['name']:
                matches.append(entry.group(1).lower())
        if len(matches) != 1:
            raise ValueError('Missing or ambiguous SHA-256 entry for the ARM64 archive')
        checksum = matches[0]
    return (version, url, checksum)

# Read the downloaded release list and print the selected version, URL and checksum for Bash.
def main():
    try:
        with open(sys.argv[1], encoding='utf-8-sig') as stream:
            selection = select_release(json.load(stream))
        print('\n'.join(selection))
    except Exception as exc:
        sys.exit(f'ERROR: Cannot resolve latest verified qFT8 release: {exc}')
if __name__ == '__main__':
    main()
PY
chmod 644 /usr/local/lib/qft8/qft8_release.py
# Verify before installing; do not execute the downloaded program as root.

# =============================================================================
# STEP 5: DOWNLOAD, VERIFY AND INSTALL qFT8
# Use a temporary folder, check the download fingerprint, and only then replace the executable. The downloaded program is not run as administrator.
# =============================================================================
QFT8_TMP=$(mktemp -d)
# Always remove only this run's temporary download files when the installer exits.
trap 'rm -f -- "$QFT8_TMP/archive.tar.gz" "$QFT8_TMP/qFT8" "$QFT8_TMP/release.json" "$QFT8_TMP/selection.txt"; rmdir -- "$QFT8_TMP"' EXIT
# Never guess versioned download URLs or silently fall back to an older release.
# Download over HTTPS; fail on server errors and retry transient failures up to three times.
curl --proto '=https' --proto-redir '=https' -fL --retry 3 --connect-timeout 15 --max-time 120 \
  -H 'Accept: application/vnd.github+json' -H 'User-Agent: qft8-pi-installer' \
  "$QFT8_RELEASE_API" -o "$QFT8_TMP/release.json"
# Run the release selector and save its three output lines: version, link, and checksum.
python3 /usr/local/lib/qft8/qft8_release.py "$QFT8_TMP/release.json" > "$QFT8_TMP/selection.txt"
mapfile -t QFT8_SELECTION < "$QFT8_TMP/selection.txt"
# Require all three release-selection values before continuing.
[[ ${#QFT8_SELECTION[@]} -eq 3 ]] || fail 'Invalid release selection'
QFT8_VERSION=${QFT8_SELECTION[0]}
QFT8_URL=${QFT8_SELECTION[1]}
QFT8_SHA256=${QFT8_SELECTION[2]}
echo "Downloading official qFT8 v$QFT8_VERSION (Linux ARM64)"
# Download over HTTPS; fail on server errors and retry transient failures up to three times.
curl --proto '=https' --proto-redir '=https' -fL --retry 3 "$QFT8_URL" -o "$QFT8_TMP/archive.tar.gz"
# Compare the downloaded file against its published SHA-256; stop on any mismatch.
printf '%s  %s\n' "$QFT8_SHA256" "$QFT8_TMP/archive.tar.gz" | sha256sum --check --status || fail 'qFT8 checksum mismatch'
# Official archive: qFT8/qFT8 is a self-extracting ARM64 executable.
# Unpack only the qFT8 executable from the compressed download into the temporary folder.
tar -xOzf "$QFT8_TMP/archive.tar.gz" qFT8/qFT8 > "$QFT8_TMP/qFT8"
# Check that the extracted executable exists and is not empty.
[[ -s "$QFT8_TMP/qFT8" ]] || fail 'qFT8 executable missing from archive'
# If a bridge service already exists, stop it before replacing its executable.
if systemctl cat qft8-bridge.service >/dev/null 2>&1; then
  systemctl stop qft8-bridge.service
fi
chown root:root /opt/qft8
chmod 755 /opt/qft8
# Copy the verified program into its permanent location, owned by root and executable.
install -o root -g root -m 755 "$QFT8_TMP/qFT8" /opt/qft8/qFT8
# Record the installed version for both OLED services; no network needed at boot.
printf '%s\n' "$QFT8_VERSION" > /opt/qft8/VERSION
chown root:root /opt/qft8/VERSION
chmod 644 /opt/qft8/VERSION
# Remove only the obsolete Java archive and old Java launcher; user settings and logs are not deleted.
rm -f /opt/qft8/qFT8.jar /opt/qft8/qFT8.jar.tmp /usr/local/lib/qft8/bridge-launch
# No system Java installation needed; leave independently used Java packages alone.

# =============================================================================
# STEP 6: ALLOW RADIO AND AUDIO ACCESS
# Keep qFT8 running as your normal account while allowing access to the radio and the background audio session.
# =============================================================================
usermod -aG dialout,audio "$RUN_USER"
# Keep your user's background services available even when you are not logged in.
loginctl enable-linger "$RUN_USER"
# Enable Wi-Fi management and SSH remote access at boot, and start them now.
systemctl enable --now NetworkManager ssh
# Start the normal user's service manager, which owns the audio session.
systemctl start "user@${RUN_UID}.service"
# Start PipeWire audio services as the normal user, using that user's session addresses.
runuser -u "$RUN_USER" -- env XDG_RUNTIME_DIR="/run/user/$RUN_UID" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$RUN_UID/bus" systemctl --user enable --now pipewire.socket pipewire-pulse.socket wireplumber.service
# Save secrets root-only; runtime daemon reads non-secret system info only.
# Quote for systemd EnvironmentFile, preserving spaces and special characters.

# =============================================================================
# STEP 7: SAVE BRIDGE SETTINGS
# Quote names/passwords for systemd and restrict the settings file to the administrator.
# =============================================================================
env_line() {
  local value="$2"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  printf '%s="%s"\n' "$1" "$value"
}
# Create the bridge settings with private permissions from the beginning.
( umask 077
  # Write one quoted bridge setting into the private file being created.
  env_line BRIDGE_NAME "$BRIDGE_NAME"
  # Write one quoted bridge setting into the private file being created.
  env_line BRIDGE_PASSWORD "$BRIDGE_PASSWORD"
  # Write one quoted bridge setting into the private file being created.
  env_line TX_VOLUME "$TX_VOLUME"
) > /etc/qft8/bridge.env
# Allow only the owner to read or edit this secret settings file.
chmod 600 /etc/qft8/bridge.env
# systemd reads the root-only file and supplies the environment to the normal user.
# Braced variable expansion in ExecStart preserves each value as one argument.

# =============================================================================
# STEP 8: CREATE THE RADIO BRIDGE SERVICE
# Run native qFT8 as the normal user, with the existing audio environment and serial-port workaround.
# =============================================================================
cat > /etc/systemd/system/qft8-bridge.service <<EOF
[Unit]
Description=qFT8 headless bridge
After=NetworkManager.service user@${RUN_UID}.service
Wants=NetworkManager.service
Requires=user@${RUN_UID}.service
[Service]
User=$RUN_USER
Group=$RUN_GROUP
# Allow access to serial radio ports and sound devices.
SupplementaryGroups=dialout audio
# Read saved bridge settings; systemd can read this administrator-only file.
EnvironmentFile=/etc/qft8/bridge.env
# Supply a home folder or audio-session address to the program.
Environment=HOME=$(getent passwd "$RUN_USER" | cut -d: -f6)
# Supply a home folder or audio-session address to the program.
Environment=XDG_RUNTIME_DIR=/run/user/$RUN_UID
# Supply a home folder or audio-session address to the program.
Environment=PULSE_SERVER=unix:/run/user/$RUN_UID/pulse/native
ExecStart=/opt/qft8/qFT8 --bridge --name \${BRIDGE_NAME} --password \${BRIDGE_PASSWORD} --tx-volume \${TX_VOLUME}
# Powerful serial-port exclusivity workaround; not a tight security sandbox.
# Grant CAP_SYS_ADMIN for the serial-port workaround. This is a very powerful privilege.
AmbientCapabilities=CAP_SYS_ADMIN
# Limit the service capability set to the listed capability; CAP_SYS_ADMIN is still broad.
CapabilityBoundingSet=CAP_SYS_ADMIN
NoNewPrivileges=yes
Restart=on-failure
RestartSec=5
# Allow this much time for a stop request before systemd forcibly terminates the task.
TimeoutStopSec=15
[Install]
WantedBy=multi-user.target
EOF
# NetworkManager has exclusive control of wlan0, AP default each boot.

# =============================================================================
# STEP 9: CONFIGURE HOTSPOT AND ROUTER WI-FI
# Create or update the two saved Wi-Fi profiles. Use a local console in case Wi-Fi disconnects.
# =============================================================================
# Turn the wireless adapter on.
nmcli radio wifi on
# Apply the Wi-Fi country setting if the Raspberry Pi configuration tool is available.
command -v raspi-config >/dev/null && raspi-config nonint do_wifi_country "$COUNTRY" || true
# Keep existing profile UUIDs and active connections during a rerun. Changes
# take full effect the next time a profile is activated (normally after reboot).
ensure_wifi_profile() {
  local profile="$1" ssid="$2"
  if ! nmcli connection show "$profile" >/dev/null 2>&1; then
    nmcli connection add type wifi ifname "$WIFI_IF" con-name "$profile" ssid "$ssid"
  fi
  nmcli connection modify "$profile" connection.interface-name "$WIFI_IF" 802-11-wireless.ssid "$ssid"
}
ensure_wifi_profile qft8-hotspot "$AP_SSID"
# Make the hotspot the preferred automatic connection, use 2.4 GHz channel 6, and share IPv4 with clients.
nmcli connection modify qft8-hotspot \
    connection.autoconnect yes \
    connection.autoconnect-priority 100 \
    802-11-wireless.mode ap \
    802-11-wireless.band bg \
    802-11-wireless.channel 6 \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk "$AP_PASSWORD" \
    ipv4.method shared \
    ipv4.addresses "$AP_IP/24" \
    ipv6.method disabled
ensure_wifi_profile qft8-maintenance "$CLIENT_SSID"
# Save router Wi-Fi credentials, obtain addresses automatically, and leave automatic connection disabled.
nmcli connection modify qft8-maintenance \
    connection.autoconnect no \
    802-11-wireless.mode infrastructure \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk "$CLIENT_PASSWORD" \
    ipv4.method auto \
    ipv6.method auto
# NetworkManager will fail over correctly, but other saved wifi client connections must not supersede AP.
# Visit other saved Wi-Fi profiles and stop them from automatically taking precedence over the hotspot.
# Look up our two UUIDs once, rather than twice for every saved profile.
AP_UUID=$(nmcli -g connection.uuid connection show qft8-hotspot)
CLIENT_UUID=$(nmcli -g connection.uuid connection show qft8-maintenance)
while IFS=: read -r uuid type; do
  [[ "$type" == '802-11-wireless' ]] || continue
  [[ "$uuid" == "$AP_UUID" || "$uuid" == "$CLIENT_UUID" ]] && continue
  # Disable automatic connection for this other saved Wi-Fi profile; do not delete it.
  nmcli connection modify "$uuid" connection.autoconnect no
done < <(nmcli -t -f UUID,TYPE connection show)
# RTC kernel overlay: preserves existing settings, under [all].

# =============================================================================
# STEP 10: CONFIGURE THE CLOCK AND OLED CONNECTION
# Add missing boot settings for the DS3231 and I2C. A reboot applies the hardware configuration.
# =============================================================================
BOOT_CFG=/boot/firmware/config.txt
# Check that the expected Raspberry Pi boot configuration file exists.
[[ -f "$BOOT_CFG" ]] || fail "Missing $BOOT_CFG"
# Check for an existing setting first, so ordinary reruns do not append the same setting again.
if ! grep -Eq '^[[:space:]]*dtoverlay=i2c-rtc,ds3231([[:space:]]|$)' "$BOOT_CFG"; then
  # Append the hardware setting under [all], where it applies to every Pi model.
  printf '\n[all]\ndtoverlay=i2c-rtc,ds3231\n' >> "$BOOT_CFG"
fi
# Expose the shared RTC/OLED I2C bus to userspace; reboot applies boot settings.
# Check for an existing setting first, so ordinary reruns do not append the same setting again.
if ! grep -Eq '^[[:space:]]*dtparam=i2c_arm=on([[:space:]]|$)' "$BOOT_CFG"; then
  # Append the hardware setting under [all], where it applies to every Pi model.
  printf '\n[all]\ndtparam=i2c_arm=on\n' >> "$BOOT_CFG"
fi
install -d -m 755 /etc/modules-load.d
# Arrange for the userspace I2C driver to load at future boots.
printf 'i2c-dev\n' > /etc/modules-load.d/qft8-i2c.conf
# Load that I2C driver now; the hardware boot settings may still need a reboot.
modprobe i2c-dev
# Keep NTP when connected: it corrects both the system time and RTC.
# No GPIO3 wake button: GPIO3 is I2C SCL and the DS3231 needs it.

# =============================================================================
# STEP 11: SAVE SHARED HARDWARE SETTINGS
# The controller, boot display and updater read this non-secret configuration file.
# =============================================================================
cat > /etc/qft8/controller.conf <<EOF
# Pi address on its own hotspot. The status page uses this address on port 8080.
AP_IP=$AP_IP
# Linux name of the wireless adapter; wlan0 is the expected adapter here.
WIFI_IF=$WIFI_IF
# Linux device representing the GPIO pins read by the button controller.
GPIO_CHIP=/dev/gpiochip0
# I2C bus number. Bus 1 uses GPIO2/SDA and GPIO3/SCL on this Pi.
OLED_I2C_BUS=$OLED_I2C_BUS
# OLED address on the shared bus; usually 0x3C, sometimes 0x3D.
OLED_I2C_ADDRESS=$OLED_I2C_ADDRESS
# Used by the display controller; the boot screen uses normal contrast.
OLED_DIM_AFTER=$OLED_DIM_AFTER
OLED_CONTRAST=$OLED_CONTRAST
OLED_DIM_CONTRAST=$OLED_DIM_CONTRAST
EOF
chmod 644 /etc/qft8/controller.conf

# =============================================================================
# STEP 12: CREATE THE AUTOMATIC UPDATER
# On client Wi-Fi, check for a newer version, display progress, verify the download and restart the bridge. Keep a previous executable for rollback.
# =============================================================================
cat > /usr/local/lib/qft8/qft8_update.py <<'PY'
#!/usr/bin/python3
"""On-demand client-WLAN update. Only the controller writes to the OLED."""
import fcntl
import hashlib
import json
import logging
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tarfile
import tempfile
import time
import urllib.request
from qft8_release import select_release
ROOT = Path('/opt/qft8')
STATE = Path('/run/qft8-update')
API = 'https://api.github.com/repos/lquesada/qFT8/releases/latest'
log = logging.getLogger('qft8-update')

# A named error for an interrupted update.
class Cancelled(Exception):
    pass

# A named error recording which old version was restored.
class RolledBack(Exception):

    # Prepare the data needed by this object before it is used.
    def __init__(self, version):
        self.version = version
        super().__init__('Previous executable restored: v' + version)

# Turn a stop request into an error the updater can handle and, if necessary, roll back.
def cancel(signum, frame):
    raise Cancelled('Update cancelled')

# Publish up to four OLED message lines. Replace the whole file so readers never see half a message.
def progress(*lines, done=False):
    STATE.mkdir(mode=0o755, parents=True, exist_ok=True)
    data = dict(lines=list(lines[:4]), time=time.monotonic(), done=done)
    temporary = STATE / 'status.tmp'
    temporary.write_text(json.dumps(data), encoding='utf-8')
    temporary.chmod(0o644)
    os.replace(temporary, STATE / 'status.json')
    if done:
        try:
            history = Path('/var/lib/qft8')
            history.mkdir(mode=0o755, parents=True, exist_ok=True)
            saved = history / 'last-update.tmp'
            with saved.open('w', encoding='utf-8') as stream:
                json.dump(dict(lines=list(lines[:4]), recorded_at=time.time()), stream)
                stream.flush()
                os.fsync(stream.fileno())
            saved.chmod(0o644)
            os.replace(saved, history / 'last-update.json')
        except OSError:
            log.exception('Could not save last update result; update outcome is unchanged')

# Run a Linux command, collect its reply, and stop waiting when its time limit is reached.
def command(*args, timeout=30, check=True):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=check)

# Check that the Pi is still connected to its saved router Wi-Fi before continuing an update.
def require_client():
    with open('/etc/qft8/controller.conf', encoding='utf-8') as stream:
        config = dict((line.strip().split('=',
            1) for line in stream if line.strip() and (not line.lstrip().startswith('#'))))
    interface = config.get('WIFI_IF', 'wlan0')
    mode = command('nmcli', '-g', 'GENERAL.CONNECTION', 'device', 'show', interface, timeout=5).stdout.strip()
    if mode != 'qft8-maintenance':
        raise RuntimeError('Client WLAN is not connected')

# Convert version text to numbers so 3.30 sorts after 3.9; treat 3.30.0 as 3.30.
def version_key(version):
    if not re.fullmatch('[0-9]+(?:\\.[0-9]+)*', version):
        raise ValueError('Installed version missing or invalid; rerun the installer')
    parts = list(map(int, version.split('.')))
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)

# Reject unencrypted download redirects.
class HTTPSOnly(urllib.request.HTTPRedirectHandler):

    # Allow a download to move to another address only if it stays encrypted with HTTPS.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith('https://'):
            raise ValueError('Refusing non-HTTPS redirect')
        return super().redirect_request(req, fp, code, msg, headers, newurl)

# Open an internet download with a 30-second network timeout.
def response(url):
    request = urllib.request.Request(url,
        headers={'User-Agent': 'qft8-pi-updater',
        'Accept': 'application/vnd.github+json'})
    return urllib.request.build_opener(HTTPSOnly()).open(request, timeout=30)

# Ask the official release server for an update; retry briefly while internet/DNS becomes ready.
def latest():
    # DHCP may precede DNS/internet readiness. Three bounded attempts, no endless loop.
    for attempt in range(3):
        require_client()
        progress('Checking for updates', f'Attempt {attempt + 1}/3', 'Bridge keeps running')
        try:
            with response(API) as stream:
                return select_release(json.load(stream))
        except (OSError, ValueError) as exc:
            if attempt == 2:
                raise
            log.warning('Release lookup failed: %s', exc)
            time.sleep(3)

# Download in small pieces, report progress, and verify the complete file fingerprint.
def download(url, target, expected, version):
    digest = hashlib.sha256()
    received = 0
    last_update = 0
    progress(f'New version: v{version}', 'Downloading: 0%', 'Bridge keeps running')
    with response(url) as stream, target.open('wb') as output:
        total = int(stream.headers.get('Content-Length', '0'))
        while True:
            block = stream.read(128 * 1024)
            if not block:
                break
            output.write(block)
            digest.update(block)
            received += len(block)
            # Limit progress-file writes to roughly twice a second.
            if time.monotonic() - last_update >= 0.5:
                percent = f'{min(100, received * 100 // total)}%' if total else f'{received // 1024} KiB'
                progress(f'New version: v{version}', f'Downloading: {percent}', 'Bridge keeps running')
                last_update = time.monotonic()
        output.flush()
        os.fsync(output.fileno())
    progress(f'New version: v{version}', 'Verifying SHA-256')
    if digest.hexdigest().lower() != expected.lower():
        raise ValueError('Downloaded archive SHA-256 mismatch')

# Read only the expected program from the compressed archive; reject links and unexpected contents.
def extract(archive, target):
    with tarfile.open(archive, 'r:gz') as bundle:
        matches = [m for m in bundle.getmembers() if m.name == 'qFT8/qFT8']
        if len(matches) != 1 or not matches[0].isfile() or matches[0].size <= 0:
            raise ValueError('Archive does not contain the expected qFT8 executable')
        # Copy this single regular file; never extract archive paths or links.
        with bundle.extractfile(matches[0]) as source, target.open('wb') as output:
            shutil.copyfileobj(source, output)
            output.flush()
            os.fsync(output.fileno())
    target.chmod(0o755)

# Save a readable version-number file and ask Linux to flush its contents to storage.
def save_version(path, version):
    with path.open('w', encoding='ascii') as stream:
        stream.write(version + '\n')
        stream.flush()
        os.fsync(stream.fileno())
    path.chmod(0o644)

# Back up the current executable, install the verified candidate, and restore the backup if startup fails.
def install(candidate, version, staging):
    # Controller USB-recovery restarts use this lock too.
    with (STATE / 'install.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        require_client()
        binary = ROOT / 'qFT8'
        metadata = ROOT / 'VERSION'
        backup = ROOT / 'qFT8.previous'
        old_version = metadata.read_text(encoding='ascii').strip()
        backup_link = staging / 'previous'
        # Same filesystem: keep the old executable intact.
        os.link(binary, backup_link)
        os.replace(backup_link, backup)
        save_version(staging / 'VERSION.previous', old_version)
        os.replace(staging / 'VERSION.previous', ROOT / 'VERSION.previous')
        new_metadata = staging / 'VERSION'
        save_version(new_metadata, version)
        stopping = replaced = False
        try:
            progress(f'Installing v{version}', 'Restarting bridge...', 'Please wait')
            stopping = True
            command('systemctl', 'stop', 'qft8-bridge.service', timeout=30)
            os.replace(candidate, binary)
            replaced = True
            os.replace(new_metadata, metadata)
            command('systemctl', 'start', 'qft8-bridge.service', timeout=30)
            # This is a service/process check, not proof of CAT/audio operation.
            invocation = command('systemctl',
                'show',
                '-p',
                'InvocationID',
                '--value',
                'qft8-bridge.service').stdout.strip()
            for _ in range(5):
                time.sleep(1)
                command('systemctl', 'is-active', '--quiet', 'qft8-bridge.service', timeout=5)
                if command('systemctl',
                    'show',
                    '-p',
                    'InvocationID',
                    '--value',
                    'qft8-bridge.service').stdout.strip() != invocation:
                    raise RuntimeError('New bridge restarted unexpectedly')
        except Exception as exc:
            # Allow rollback to finish even when systemd sends another termination signal.
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            progress('Update failed', 'Restoring old version')
            if stopping:
                command('systemctl', 'stop', 'qft8-bridge.service', timeout=25, check=False)
            if replaced:
                os.link(backup, staging / 'restore')
                os.replace(staging / 'restore', binary)
                save_version(new_metadata, old_version)
                os.replace(new_metadata, metadata)
            if stopping:
                command('systemctl', 'start', 'qft8-bridge.service', timeout=25)
            raise RolledBack(old_version) from exc
        progress(f'Installed v{version}', 'Bridge is running', done=True)

# Check for a newer version, download and verify it, then install it or report the failure.
def main():
    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    try:
        STATE.mkdir(mode=0o755, parents=True, exist_ok=True)
        current = (ROOT / 'VERSION').read_text(encoding='ascii').strip()
        version_key(current)
        version, url, checksum = latest()
        # Do nothing if the installed version is already as new or newer.
        if version_key(version) <= version_key(current):
            progress(f'Installed v{current}', 'Already up to date', done=True)
            return 0
        with tempfile.TemporaryDirectory(prefix='.update-', dir=ROOT) as directory:
            staging = Path(directory)
            archive = staging / 'archive.tar.gz'
            candidate = staging / 'qFT8'
            download(url, archive, checksum, version)
            require_client()
            progress(f'New version: v{version}', 'Preparing installation')
            extract(archive, candidate)
            install(candidate, version, staging)
        return 0
    except RolledBack as exc:
        log.exception('Update failed; previous executable restored')
        progress('Update failed', f'Restored v{exc.version}', 'Bridge restarted', done=True)
        return 1
    except Exception:
        log.exception('Automatic update did not complete')
        progress('Update failed/skipped', 'See updater journal', done=True)
        return 1
if __name__ == '__main__':
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
    raise SystemExit(main())
PY
chmod 755 /usr/local/lib/qft8/qft8_update.py
# On demand only: the controller starts this after entering client WLAN mode.

cat > /etc/systemd/system/qft8-update.service <<'EOF'
[Unit]
Description=qFT8 automatic update on client WLAN
After=NetworkManager.service
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/lib/qft8/qft8_update.py
# Create this temporary folder under /run for progress messages and the update lock.
RuntimeDirectory=qft8-update
# Allow everyone to read/traverse the folder but only its owner to change it.
RuntimeDirectoryMode=0755
# Keep the progress folder after this task exits so the OLED can show its final message.
RuntimeDirectoryPreserve=yes
# Set a maximum startup/update duration so the job cannot wait forever.
TimeoutStartSec=15min
# Allow this much time for a stop request before systemd forcibly terminates the task.
TimeoutStopSec=90
# Send the initial stop signal to the main updater so it can try to restore the old executable.
KillMode=mixed
# Give this task lower CPU priority than ordinary programs.
Nice=10
# Default file permissions: other accounts can read ordinary files but cannot edit them.
UMask=0022
NoNewPrivileges=yes
# Give the service its own view of temporary folders.
PrivateTmp=yes
EOF
# Early boot splash: runs after local filesystems/modules, before normal services.
# It leaves the pixels visible, closes I2C, and exits before the controller starts.

# =============================================================================
# STEP 13: CREATE THE EARLY BOOT DISPLAY
# Show a short message once Linux can use I2C. This cannot display the Pi firmware's earliest boot stage.
# =============================================================================
cat > /usr/local/lib/qft8/oled-boot.py <<'PY'
#!/usr/bin/python3
"""Best-effort SH1106 boot message; never require a display to boot the Pi."""
import logging
import time
from pathlib import Path
logging.basicConfig(level=logging.INFO, format='%(levelname)s %(message)s')
log = logging.getLogger('qft8-oled-boot')

# Read the installed version for the yellow OLED heading; show ? if the file cannot be read.
def bridge_heading():
    try:
        with open('/opt/qft8/VERSION', encoding='ascii') as stream:
            version = stream.read(64).strip()
        if not version or not all((part.isdecimal() for part in version.split('.'))):
            raise ValueError('Invalid installed version')
    except (OSError, UnicodeError, ValueError):
        # Keep the display usable if version metadata is missing.
        version = '?'
    return 'qFT8 BRIDGE v' + version

# Wait briefly for I2C, draw the boot message, and leave the pixels visible for the controller.
def main():
    try:
        with open('/etc/qft8/controller.conf', encoding='utf-8') as stream:
            config = dict((line.strip().split('=',
                1) for line in stream if line.strip() and (not line.lstrip().startswith('#'))))
        bus = int(config.get('OLED_I2C_BUS', '1'))
        address = int(config.get('OLED_I2C_ADDRESS', '0x3C'), 0)
        # Device nodes can appear shortly after the modules-load service completes.
        deadline = time.monotonic() + 3.0
        while not Path(f'/dev/i2c-{bus}').exists():
            if time.monotonic() >= deadline:
                log.warning('I2C bus unavailable; skipping boot splash')
                return
            time.sleep(0.1)
        from luma.core.interface.serial import i2c
        from luma.oled.device import sh1106
        from PIL import Image, ImageDraw, ImageFont
        font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf', 9)
        serial = i2c(port=bus, address=address)
        try:
            device = sh1106(serial, width=128, height=64, rotate=0)
            # Luma normally blanks the display at process exit. Keep this frame
            # until the status controller initializes the screen and replaces it.
            device.persist = True
            device.contrast(int(config.get('OLED_CONTRAST', '96')))
            image = Image.new('1', (128, 64))
            for y, height, text in ((0,
                16,
                bridge_heading()),
                (16,
                12,
                'Booting Raspberry Pi'),
                (28,
                12,
                'Please wait...')):
                band = Image.new('1', (128, height))
                ImageDraw.Draw(band).text((0, 0), text, font=font, fill=1)
                image.paste(band, (0, y))
            device.display(image)
            log.info('Boot splash displayed; handing OLED to status controller')
        finally:
            serial.cleanup()
    except Exception as exc:
        log.warning('Boot splash skipped: %s', exc)
if __name__ == '__main__':
    main()
PY
chmod 755 /usr/local/lib/qft8/oled-boot.py

cat > /etc/systemd/system/qft8-oled-boot.service <<'EOF'
[Unit]
Description=qFT8 early OLED boot message
# Disable normal startup ordering for this early-boot helper; explicit ordering is provided above.
DefaultDependencies=no
After=local-fs.target systemd-modules-load.service
Wants=systemd-modules-load.service
# Finish this startup job before the listed tasks are started.
Before=sysinit.target qft8-controller.service shutdown.target
# Stop this task when the named target is started (here, shutdown).
Conflicts=shutdown.target
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/lib/qft8/oled-boot.py
RemainAfterExit=yes
# Set a maximum startup/update duration so the job cannot wait forever.
TimeoutStartSec=5
# Allow this much time for a stop request before systemd forcibly terminates the task.
TimeoutStopSec=1
NoNewPrivileges=yes
[Install]
WantedBy=sysinit.target
EOF
# Button timing and hardware data for all three display pages.

cat > /usr/local/lib/qft8/qft8_pages.py <<'PY'
"""Button timing and five-second hardware statistics for the three OLED pages."""
from collections import deque
import json
import logging
from pathlib import Path
import queue
import re
import shutil
import subprocess
import threading
import time

# Compact time since the Pi booted, not time since the controller was restarted.
def format_uptime(seconds):
    minutes = max(0, int(float(seconds))) // 60
    days, remaining = divmod(minutes, 1440)
    hours, minutes = divmod(remaining, 60)
    return f'{days}d{hours:02}h' if days else f'{hours:02}h{minutes:02}m'

class IdleBrightness:
    """Track user inactivity; ordinary status refreshes must not reset this timer."""
    def __init__(self, delay, normal, dim, now):
        self.delay, self.normal, self.dim = delay, normal, dim
        self.last_action = now

    def level(self, now):
        return self.dim if self.delay > 0 and now - self.last_action >= self.delay else self.normal

    def touch(self, now):
        was_dimmed = self.delay > 0 and now - self.last_action >= self.delay
        self.last_action = now
        return was_dimmed

class PressGesture:
    """Require an initial release; emit one action per deliberate press."""

    # Prepare the data needed by this object before it is used.
    def __init__(self, long_seconds, short=False):
        self.long_seconds = long_seconds
        self.short = short
        self.armed = False
        self.since = None
        self.fired = False

    # Measure each press and emit either a short-release action or one long-hold action.
    def update(self, pressed, now):
        if not pressed:
            duration = None if self.since is None else round((now - self.since) * 1000, 3)
            result = None
            if not self.fired and duration is not None:
                if duration >= self.long_seconds * 1000:
                    result = 'long'
                elif self.short and 50 < duration <= 1000:
                    result = 'short'
            self.armed = True
            self.since = None
            self.fired = False
            return result
        if not self.armed:
            return None
        if self.since is None:
            self.since = now
        if not self.fired and now - self.since >= self.long_seconds:
            self.fired = True
            return 'long'
        return None

class ButtonMonitor:
    """Sample buttons every 10 ms independently of slow network/display commands."""

    # Prepare the data needed by this object before it is used.
    def __init__(self, wifi, shutdown):
        self.read_wifi, self.read_shutdown = (wifi, shutdown)
        self.events = queue.Queue()
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.worker, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *args):
        self.stop.set()
        self.thread.join()

    # Read both GPIO inputs every 10 ms and queue the requested actions.
    def worker(self):
        wifi = PressGesture(3.0, short=True)
        shutdown = PressGesture(5.0)
        while not self.stop.is_set():
            now = time.monotonic()
            try:
                w = wifi.update(self.read_wifi(), now)
                s = shutdown.update(self.read_shutdown(), now)
                if w:
                    self.events.put('page' if w == 'short' else 'wifi')
                if s:
                    self.events.put('shutdown')
            except Exception:
                logging.exception('Button input failed')
                self.events.put('input-error')
                return
            self.stop.wait(0.01)

    # Return button actions captured since the controller last checked.
    def pending(self):
        result = []
        while True:
            try:
                result.append(self.events.get_nowait())
            except queue.Empty:
                return result

def cpu_counters(text):
    result = {}
    for line in text.splitlines():
        parts = line.split()
        if parts and re.fullmatch('cpu\\d+', parts[0]):
            # Guest time is already part of user/nice; do not count it twice.
            fields = list(map(int, parts[1:9]))
            if len(fields) >= 5:
                result[int(parts[0][3:])] = (sum(fields), fields[3] + fields[4])
    if not result:
        raise ValueError('No CPU counters')
    return result

class CpuAverage:
    """Use counter differences over a rolling 300-second window, per core."""

    # Prepare the data needed by this object before it is used.
    def __init__(self):
        self.samples = deque()

    # Add CPU counters and calculate the per-core rolling utilization percentages.
    def add(self, now, counters):
        self.samples.append((now, counters))
        cutoff = now - 300
        while len(self.samples) > 2 and self.samples[1][0] <= cutoff:
            self.samples.popleft()
        if len(self.samples) < 2:
            return 'CPU%: collecting...'
        first_time, first = self.samples[0]
        # Interpolate the window boundary if it falls between five-second samples.
        if first_time < cutoff:
            next_time, following = self.samples[1]
            fraction = (cutoff - first_time) / (next_time - first_time)
            first = {core: tuple((a + (b - a) * fraction for a,
                b in zip(value,
                following[core]))) for core,
                value in first.items() if core in following}
        values = []
        for core in sorted(counters):
            if core not in first:
                values.append('?')
                continue
            total = counters[core][0] - first[core][0]
            idle = counters[core][1] - first[core][1]
            if total <= 0 or idle < 0:
                values.append('?')
                continue
            percent = min(100, max(0, 100 * (total - idle) / total))
            values.append(f'{percent:.1f}' if percent < 10 else f'{percent:.0f}')
        return 'CPU%: ' + ' '.join(values)

def memory_line(text):
    values = {line.split(':')[0]: int(line.split()[1]) for line in text.splitlines() if ':' in line}
    total, available = (values['MemTotal'], values['MemAvailable'])
    return f'RAM: {max(0, total - available) // 1024}/{total // 1024}MiB'

# Show the measured ARM clock alongside actual firmware limit flags.
# A low frequency on its own is normal power saving, not evidence of throttling.
def cpu_frequency_line(mhz, flags):
    frequency = '?' if mhz is None else f'{mhz:.0f}'
    if flags is None:
        state = 'STATUS?'
    elif flags & 4:
        state = 'THROTTLED!'
    elif flags & 8:
        state = 'TEMP LIMIT!'
    elif flags & 2:
        state = 'CAPPED!'
    elif flags & 0xE0000:
        state = 'PAST LIMIT'
    else:
        state = 'OK'
    return f'CPU: {frequency}MHz {state}'


def system_output(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True, timeout=2).stdout.strip()

class SystemPages:
    """Collect data in a worker, so slow hardware queries do not block buttons."""

    # Prepare the data needed by this object before it is used.
    def __init__(self, interface):
        self.interface = interface
        self.cpu = CpuAverage()
        self.lock = threading.Lock()
        self.pages = {1: ('CPU%: collecting...',
            'RAM: reading...',
            'Temp: reading...',
            'CPU clock: reading...'),
            2: ('SD: reading...',
            'WLAN: reading...',
            'Last update:',
            'No result recorded')}
        threading.Thread(target=self.worker, daemon=True).start()

    # Return the four cached lines for the selected hardware page.
    def lines(self, page):
        with self.lock:
            return self.pages[page]

    # Read CPU usage, RAM, temperature, CPU clock/throttling, storage, Wi-Fi and update history.
    def collect(self):
        # Each reading fails independently: a missing utility does not hide other data.
        try:
            cpu = self.cpu.add(time.monotonic(), cpu_counters(Path('/proc/stat').read_text()))
        except Exception:
            cpu = 'CPU%: unavailable'
        try:
            memory = memory_line(Path('/proc/meminfo').read_text())
        except Exception:
            memory = 'RAM: unavailable'
        try:
            temp = float(Path('/sys/class/thermal/thermal_zone0/temp').read_text()) / 1000
            temperature = f'Temp: {temp:.1f}°C'
        except Exception:
            temperature = 'Temp: unavailable'
        # Measure the actual ARM clock in Hz, then convert to MHz for the display.
        # Read clock and throttle flags independently so one missing reading does
        # not hide the other. These readings share the five-second refresh cycle.
        try:
            reply = system_output('vcgencmd', 'measure_clock', 'arm')
            match = re.fullmatch(r'frequency\([^)]+\)=(\d+)', reply)
            if match is None or int(match.group(1)) <= 0:
                raise ValueError('Invalid ARM clock reading')
            mhz = int(match.group(1)) / 1000000
        except Exception:
            mhz = None
        try:
            reply = system_output('vcgencmd', 'get_throttled')
            match = re.fullmatch(r'throttled=(0x[0-9a-fA-F]+)', reply)
            if match is None:
                raise ValueError('Invalid throttle status')
            flags = int(match.group(1), 16)
        except Exception:
            flags = None
        clock_status = cpu_frequency_line(mhz, flags)
        try:
            disk = shutil.disk_usage('/')
            # Root filesystem, normally on the SD card; show actual free space.
            storage = f'SD free:{disk.free / 2 ** 30:.1f}/{disk.total / 2 ** 30:.1f}GiB'
        except Exception:
            storage = 'SD: unavailable'
        try:
            mode = system_output('nmcli', '-g', 'GENERAL.CONNECTION', 'device', 'show', self.interface)
            if mode == 'qft8-hotspot':
                wlan = 'WiFi:AP'
            elif mode == 'qft8-maintenance':
                # Use NetworkManager's last known signal; do not force a disruptive scan.
                listing = system_output('nmcli',
                    '-t',
                    '-f',
                    'IN-USE,SIGNAL',
                    'device',
                    'wifi',
                    'list',
                    'ifname',
                    self.interface,
                    '--rescan',
                    'no')
                signals = [line.split(':')[1] for line in listing.splitlines() if line.startswith('*:')]
                wlan = f'WiFi:{int(signals[0])}%' if signals else 'WiFi:?'
            else:
                wlan = 'WiFi:off'
        except Exception:
            wlan = 'WiFi:?'
        try:
            uptime = format_uptime(Path('/proc/uptime').read_text().split()[0])
        except Exception:
            uptime = '?'
        # Share one row so both lines of the saved update result remain visible.
        wlan = wlan + ' Up:' + uptime
        try:
            result = json.loads(Path('/var/lib/qft8/last-update.json').read_text())['lines']
            update = tuple(['Last: ' + str(result[0]), str(result[1]) if len(result) > 1 else ''])
        except Exception:
            update = ('Last update:', 'No result recorded')
        with self.lock:
            self.pages = {1: (cpu, memory, temperature, clock_status), 2: (storage, wlan, *update)}

    # Refresh the two hardware-information pages every five seconds.
    def worker(self):
        while True:
            started = time.monotonic()
            self.collect()
            time.sleep(max(0.1, 5 - (time.monotonic() - started)))
PY
chmod 644 /usr/local/lib/qft8/qft8_pages.py

# =============================================================================
# STEP 14: CREATE THE BUTTON AND OLED CONTROLLER
# Watch the buttons, manage Wi-Fi recovery, monitor radio reconnection, and show either normal status or update progress.
# =============================================================================
cat > /usr/local/lib/qft8/controller.py <<'PY'
#!/usr/bin/python3
"""GPIO buttons, NM mode switching, SH1106 status, and radio USB recovery."""
import fcntl, json, logging, os, subprocess, threading, time
import gpiod
from qft8_pages import ButtonMonitor, SystemPages, IdleBrightness
from gpiod.line import Direction, Bias, Value
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
log = logging.getLogger('qft8-controller')

# Read the installed version for the yellow OLED heading; show ? if the file cannot be read.
def bridge_heading():
    try:
        with open('/opt/qft8/VERSION', encoding='ascii') as stream:
            version = stream.read(64).strip()
        if not version or not all((part.isdecimal() for part in version.split('.'))):
            raise ValueError('Invalid installed version')
    except (OSError, UnicodeError, ValueError):
        # Keep the display usable if version metadata is missing.
        version = '?'
    return 'qFT8 BRIDGE v' + version

# Read non-secret hardware and Wi-Fi settings from the file created by this installer.
def read_config():
    with open('/etc/qft8/controller.conf', encoding='utf-8') as stream:
        return dict((line.strip().split('=',
            1) for line in stream if line.strip() and (not line.lstrip().startswith('#'))))
CONFIG = read_config()
CHIP = CONFIG.get('GPIO_CHIP', '/dev/gpiochip0')
AP = 'qft8-hotspot'
CLIENT = 'qft8-maintenance'
IF = CONFIG.get('WIFI_IF', 'wlan0')
BUTTON_WIFI = 17
BUTTON_SHUT = 27

# Run a system command and return its result to this helper program.
def run(*cmd, timeout=30):
    return subprocess.run(cmd, text=True, capture_output=True, timeout=timeout)

# Ask NetworkManager to change Wi-Fi mode; report an error if it cannot finish.
def nm(*args, timeout=40):
    r = run('nmcli', '--wait', str(timeout), *args, timeout=timeout + 10)
    if r.returncode:
        raise RuntimeError(r.stderr.strip() or r.stdout.strip())
    return r.stdout.strip()

# Find the name of the Wi-Fi profile currently in use.
def active():
    return run('nmcli', '-g', 'GENERAL.CONNECTION', 'device', 'show', IF).stdout.strip()

# Read the IPv4 address assigned to the Wi-Fi interface.
def address():
    return run('nmcli', '-g', 'IP4.ADDRESS', 'device', 'show', IF).stdout.strip()

def network_status():
    """Read connection name and IPv4 addresses in one NetworkManager call."""
    result = run('nmcli', '-g', 'GENERAL.CONNECTION,IP4.ADDRESS', 'device', 'show', IF)
    lines = result.stdout.splitlines() if result.returncode == 0 else []
    return (lines[0], lines[1:]) if lines else ('', [])

# Look for a matching USB device and a serial-port device; this is not an audio or CAT test.
def usb_radio():
    # Detect a matching USB device and a serial port; USB audio is not verified here.
    devices = run('lsusb').stdout.lower()
    return ('10c4:ea60' in devices or 'icom' in devices) and any((p.startswith(('ttyUSB',
        'ttyACM')) for p in os.listdir('/dev')))

# Read recent update messages; hide finished messages after 12 seconds and stale ones after 180.
def update_progress():
    try:
        with open('/run/qft8-update/status.json', encoding='utf-8') as stream:
            state = json.load(stream)
        age = time.monotonic() - state['time']
        if 0 <= age < (12 if state.get('done') else 180):
            return state['lines']
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None

# Ask systemd to start an update in the background so the buttons do not wait for the download.
def request_update():
    try:
        result = run('systemctl', '--no-block', 'start', 'qft8-update.service', timeout=5)
        if result.returncode:
            log.warning('Cannot start update check: %s', result.stderr.strip())
        else:
            log.info('Client WLAN connected; automatic update check requested')
    except Exception:
        log.exception('Cannot request update check')

# Restart after a radio reconnect, unless the updater currently holds the installation lock.
def restart_radio_bridge():
    # Do not let USB recovery interrupt executable replacement or rollback.
    os.makedirs('/run/qft8-update', mode=0o755, exist_ok=True)
    with open('/run/qft8-update/install.lock', 'a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return False
        return run('systemctl', 'restart', 'qft8-bridge.service', timeout=20).returncode == 0

# One owner for display writes; other code only queues messages.
class OledStatus:
    """One I2C worker: display failures never block GPIO/network handling."""

    # Prepare the data needed by this object before it is used.
    def __init__(self):
        self.lock = threading.Lock()
        self.wake = threading.Event()
        self.brightness = IdleBrightness(
            int(CONFIG.get('OLED_DIM_AFTER', '60')),
            int(CONFIG.get('OLED_CONTRAST', '96')),
            int(CONFIG.get('OLED_DIM_CONTRAST', '8')), time.monotonic())
        self.frame = (bridge_heading(), ('Starting...', '', '', ''), threading.Event())
        threading.Thread(target=self.worker, name='qft8-oled', daemon=True).start()

    # Restore brightness and tell the caller whether this action woke a dimmed screen.
    def touch(self):
        with self.lock:
            was_dimmed = self.brightness.touch(time.monotonic())
        self.wake.set()
        return was_dimmed

    # Queue the next OLED frame; shutdown messages may wait at most one second for it to appear.
    def show(self, heading, *lines, wait=False):
        painted = threading.Event()
        with self.lock:
            self.frame = (heading, tuple(lines[:4]), painted)
        self.wake.set()
        if wait:
            # A missing screen must not prevent shutdown.
            painted.wait(1.0)

    # Write OLED frames in a separate thread; retry a missing display without stopping button handling.
    def worker(self):
        device = serial = None
        last_frame = None
        last_contrast = None
        retry_at = 0
        while True:
            self.wake.wait(1.0)
            self.wake.clear()
            if time.monotonic() < retry_at:
                continue
            with self.lock:
                heading, lines, painted = self.frame
                contrast = self.brightness.level(time.monotonic())
            try:
                if device is None:
                    from luma.core.interface.serial import i2c
                    from luma.oled.device import sh1106
                    from PIL import Image, ImageDraw, ImageFont
                    font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf', 9)
                    small_font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf', 8)
                    serial = i2c(port=int(CONFIG.get('OLED_I2C_BUS',
                        '1')),
                        address=int(CONFIG.get('OLED_I2C_ADDRESS',
                        '0x3C'),
                        0))
                    device = sh1106(serial, width=128, height=64, rotate=0)
                    last_contrast = None
                    last_frame = None
                    log.info('SH1106 display connected')
                # Adjust only when needed, even if no displayed text has changed.
                if contrast != last_contrast:
                    device.contrast(contrast)
                    last_contrast = contrast
                if (heading, lines) != last_frame:
                    image = Image.new('1', (128, 64))
                    draw = ImageDraw.Draw(image)
                    # Each text band is clipped so no pixels cross the color boundary.
                    for y, height, text in [(0,
                        16,
                        heading)] + [(16 + i * 12,
                        12,
                        line) for i,
                        line in enumerate(lines)]:
                        band = Image.new('1', (128, height))
                        painter = ImageDraw.Draw(band)
                        label = str(text)
                        line_font = font if painter.textlength(label, font=font) <= 128 else small_font
                        while label and painter.textlength(label, font=line_font) > 128:
                            label = label[:-1]
                        painter.text((0, 0), label, font=line_font, fill=1)
                        image.paste(band, (0, y))
                    device.display(image)
                    last_frame = (heading, lines)
                painted.set()
            except Exception as exc:
                log.warning('OLED unavailable; retrying in 30s: %s', exc)
                if serial is not None:
                    try:
                        serial.cleanup()
                    except Exception:
                        pass
                device = serial = None
                retry_at = time.monotonic() + 30

# Watch the two buttons, recover Wi-Fi/radio connections, request updates, and refresh OLED status.
def main():
    display = OledStatus()
    pages = SystemPages(IF)
    # Page 1 at startup; brief presses cycle through all three.
    current_page = 0
    with gpiod.request_lines(CHIP,
        consumer='qft8-controller',
        config={BUTTON_WIFI: gpiod.LineSettings(direction=Direction.INPUT,
        bias=Bias.PULL_UP,
        active_low=True),
        BUTTON_SHUT: gpiod.LineSettings(direction=Direction.INPUT,
        bias=Bias.PULL_UP,
        active_low=True)}) as io, ButtonMonitor(lambda: io.get_value(BUTTON_WIFI) == Value.ACTIVE,
        lambda: io.get_value(BUTTON_SHUT) == Value.ACTIVE) as buttons:
        last_update_mode = None
        radio_restart_pending = False
        maintenance = False
        switching = False
        last_radio = None
        last_poll = 0
        last_status = 0
        last_bridge_check = float("-inf")
        bridge_ok = False
        wifi_mode = ''
        wifi_fail = False
        while True:
            now = time.monotonic()
            actions = buttons.pending()
            if 'input-error' in actions:
                raise RuntimeError('Button reader stopped; restarting controller')
            # A shutdown request takes priority over pending page/WLAN actions.
            if 'shutdown' in actions:
                display.touch()
                display.show('SHUTTING DOWN', 'Shutdown requested', 'Wait for Pi to halt', wait=True)
                log.warning('Safe shutdown requested after five-second hold')
                run('systemctl', 'poweroff', timeout=10)
                return
            for action in actions:
                if action == 'page':
                    if display.touch():
                        continue  # First short press restores brightness without changing pages.
                    current_page = (current_page + 1) % 3
                    # Refresh the newly selected page promptly.
                    last_status = 0
            # More than 50 ms through 1000 ms changes a page on release. A three-second
            # hold requests WLAN once. Presses in between have no action.
            if 'wifi' in actions and (not switching):
                display.touch()
                switching = True
                display.show('WLAN SWITCH', 'Connecting client...', 'Please wait')
                try:
                    log.info('Maintenance WLAN requested')
                    nm('connection', 'down', 'id', AP, timeout=15)
                    nm('connection', 'up', 'id', CLIENT, 'ifname', IF, timeout=50)
                    if not address():
                        raise RuntimeError('No IPv4 address from DHCP')
                    maintenance = True
                    wifi_fail = False
                    log.info('Maintenance connected at %s', address())
                except Exception as e:
                    log.warning('Maintenance failed: %s; restoring AP', e)
                    wifi_fail = True
                    maintenance = False
                    display.show('WLAN RECOVERY', 'Client failed', 'Restoring access point')
                    try:
                        nm('connection', 'up', 'id', AP, 'ifname', IF, timeout=40)
                    except Exception:
                        log.exception('AP restore failed')
                finally:
                    switching = False
            # Every eight seconds, check radio presence and recover a lost client connection.
            if now - last_poll > 8:
                last_poll = now
                present = usb_radio()
                if last_radio is not None and present != last_radio:
                    log.warning('IC7300 USB change: %s', present)
                    if present:
                        radio_restart_pending = True
                last_radio = present
                if radio_restart_pending and present:
                    if restart_radio_bridge():
                        radio_restart_pending = False
                if maintenance and active() != CLIENT:
                    # Recovery on spontaneous client disconnection; manual mode persists only until reboot.
                    log.warning('Maintenance WLAN lost; returning to AP')
                    maintenance = False
                    display.show('WLAN RECOVERY', 'Client disconnected', 'Restoring access point')
                    try:
                        nm('connection', 'up', 'id', AP, 'ifname', IF, timeout=40)
                    except Exception:
                        log.exception('AP recovery failed')
            # About once per second, refresh service/network status and the OLED.
            if now - last_status > 1:
                last_status = now
                # Service state needs less frequent polling than OLED update progress.
                if now - last_bridge_check >= 5:
                    last_bridge_check = now
                    bridge_ok = run('systemctl', 'is-active', 'qft8-bridge.service').returncode == 0
                wifi_mode, ip = network_status()
                mode = 'CLIENT' if wifi_mode == CLIENT else 'AP' if wifi_mode == AP else 'OFFLINE'
                # Remember Wi-Fi transitions; check for updates once per client connection with an IP address.
                if wifi_mode != CLIENT:
                    last_update_mode = wifi_mode
                elif ip and last_update_mode != CLIENT:
                    # One check per connection, including a client connection made outside the button.
                    request_update()
                    last_update_mode = CLIENT
                ip = ip[0].split('/')[0] if ip else 'No IPv4 address'
                radio = 'detected' if last_radio else 'not detected' if last_radio is False else 'checking'
                progress_lines = update_progress()
                # Show update progress in place of ordinary status until the message expires.
                if progress_lines:
                    display.show('qFT8 UPDATE', *progress_lines)
                elif current_page != 0:
                    display.show(bridge_heading(), *pages.lines(current_page))
                else:
                    display.show(bridge_heading(),
                        'Bridge: ' + ('running' if bridge_ok else 'STOPPED'),
                        'Radio: ' + radio,
                        'WLAN: ' + mode,
                        ip)
            time.sleep(0.01)
if __name__ == '__main__':
    main()
PY
chmod 755 /usr/local/lib/qft8/controller.py

cat > /etc/systemd/system/qft8-controller.service <<'EOF'
[Unit]
Description=qFT8 buttons, OLED and network controller
Wants=qft8-oled-boot.service
After=NetworkManager.service qft8-oled-boot.service
Requires=NetworkManager.service
[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/lib/qft8/controller.py
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

# =============================================================================
# STEP 15: CREATE THE LOCAL STATUS WEB PAGE
# Serve read-only information on port 8080. The health reply only says the web handler responds, not that every device works.
# =============================================================================
cat > /usr/local/lib/qft8/status.py <<'PY'
#!/usr/bin/python3
"""Read-only status page on local networks, no remote actions or sensitive values."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import html
import subprocess
import os
import datetime
from pathlib import Path

# Use the same adapter as the controller, including non-default interface names.
CONFIG = dict(line.split('=', 1) for line in Path('/etc/qft8/controller.conf').read_text().splitlines()
              if '=' in line and not line.lstrip().startswith('#'))
WIFI_IF = CONFIG.get('WIFI_IF', 'wlan0')

# Run a system command and return its result to this helper program.
def run(*args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=2)
        return result.stdout.strip() if result.returncode == 0 else 'Unavailable'
    except Exception:
        return '?'

# Rules used to serve the read-only status web page.
class Handler(BaseHTTPRequestHandler):

    # Answer a web request with the local status page, a health reply, or a not-found response.
    def do_GET(self):
        if self.path not in ('/', '/health'):
            self.send_error(404)
            return
        if self.path == '/health':
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'OK\n')
            return
        info = {'UTC': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),
            'WLAN connection': run('nmcli',
            '-g',
            'GENERAL.CONNECTION',
            'device',
            'show',
            WIFI_IF),
            'WLAN IPv4': run('nmcli',
            '-g',
            'IP4.ADDRESS',
            'device',
            'show',
            WIFI_IF),
            'qFT8 bridge': run('systemctl',
            'is-active',
            'qft8-bridge'),
            'Controller': run('systemctl',
            'is-active',
            'qft8-controller'),
            'RTC': run('hwclock',
            '--show'),
            'Radio serial': ', '.join((x for x in os.listdir('/dev') if x.startswith(('ttyUSB',
            'ttyACM')))) or 'Not detected',
            'USB devices': run('lsusb'),
            'Uptime': run('uptime',
            '-p')}
        page = '<html><head><meta name="viewport" content="width=device-width"><meta http-equiv="refresh" content="10"><title>qFT8 status</title></head><body><h2>qFT8 Bridge Status</h2><dl>' + ''.join((f'<dt><b>{html.escape(k)}</b></dt><dd><pre>{html.escape(v)}</pre></dd>' for k,
            v in info.items())) + '</dl></body></html>'
        data = page.encode()
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    # Suppress routine web-access messages so they do not fill the journal.
    def log_message(self, format, *args):
        pass
ThreadingHTTPServer(('0.0.0.0', 8080), Handler).serve_forever()
PY

cat > /etc/systemd/system/qft8-status.service <<'EOF'
[Unit]
Description=qFT8 read-only local status dashboard
After=NetworkManager.service
[Service]
User=nobody
Group=nogroup
ExecStart=/usr/bin/python3 /usr/local/lib/qft8/status.py
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
# Make system folders read-only for this status-page service.
ProtectSystem=strict
# Prevent this service from accessing users' home folders.
ProtectHome=true
# Give the service its own view of temporary folders.
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
# Limit journal disk usage, no read-only root.
install -d /etc/systemd/journald.conf.d

# =============================================================================
# STEP 16: LIMIT LOG STORAGE
# Bound journal disk and memory usage so logs do not consume unlimited space.
# =============================================================================
cat > /etc/systemd/journald.conf.d/qft8.conf <<'EOF'
# Settings for the system activity/error log.
[Journal]
# Limit persistent journal storage to this size.
SystemMaxUse=64M
# Limit temporary journal storage to this size.
RuntimeMaxUse=16M
EOF

# =============================================================================
# STEP 17: LOAD AND START THE SERVICES
# Apply the log limit, reload service definitions, and start the bridge, buttons/OLED and status page.
# =============================================================================
# Restart the log manager to apply the storage limits.
systemctl restart systemd-journald
# Stop the old display writer before the new boot service can be pulled in.
# Tell systemd to reread the service files this installer just wrote.
systemctl daemon-reload
# Stop the previous OLED writer before starting the configured display services.
systemctl stop qft8-controller.service
# Enable the early boot message for future boots.
systemctl enable qft8-oled-boot.service
# Enable the regular services for future boots and start them now. The updater remains on-demand.
systemctl enable --now qft8-bridge.service qft8-controller.service qft8-status.service
# The messages below do not switch Wi-Fi. Profile changes above may already have interrupted a wireless connection.

# =============================================================================
# STEP 18: FINISH AND REBOOT WHEN READY
# These final messages explain how to use the completed installation. This script does not reboot the Pi itself.
# =============================================================================
echo 'Installation written. Reboot from local console; AP mode will be primary at boot.'
echo 'NOTE: ensure qft8-hotspot is selected at boot: nmcli connection up qft8-hotspot'
echo "Status URL after AP start: http://$AP_IP:8080"
echo 'After RTC is initialized and system clock is correct: sudo hwclock --systohc --utc'
echo 'OLED: SH1106 128x64 on I2C; reboot to apply I2C boot configuration.'
echo 'Early OLED boot message enabled; visible after Linux initializes I2C, before normal services.'
echo 'Automatic qFT8 updates: checked on each client WLAN connection; progress shown on OLED.'
echo 'WLAN button: >50 to 1000 ms = wake dimmed screen or next page; hold 3 seconds = client WLAN.'
echo 'Shutdown button: hold 5 seconds. Hardware statistics refresh every 5 seconds.'
