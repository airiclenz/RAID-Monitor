#!/bin/zsh
# install.sh — RAID Integrity Monitor installation script
# Run from the IntegrityMonitor/ project directory: ./install.sh
#
# Usage:
#   ./install.sh              install or re-install
#   ./install.sh --uninstall  remove all installed files

set -uo pipefail

# ---------------------------------------------------------------------------
# Colour helpers (only when stdout is a terminal)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_OK='\033[0;32m'; C_WARN='\033[1;33m'; C_ERR='\033[0;31m'; C_RST='\033[0m'
else
    C_OK=''; C_WARN=''; C_ERR=''; C_RST=''
fi

ok()   { printf "${C_OK}[OK]${C_RST}    %s\n" "$*"; }
info() { printf "${C_WARN}[INFO]${C_RST}  %s\n" "$*"; }
err()  { printf "${C_ERR}[ERROR]${C_RST} %s\n" "$*" >&2; }
step() { printf '\n==> %s\n' "$*"; }
die()  { err "$*"; exit 1; }
# Replace $HOME prefix with ~ for display
short() { echo "${1/#$HOME/~}"; }

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="${0:A:h}"       # absolute path to directory containing install.sh
USERNAME=$(id -un)

SRC_NOTIFY_PLIST="${SCRIPT_DIR}/NotifyHelper/Info.plist"
SRC_CONFIG="${SCRIPT_DIR}/config.json.template"
SRC_PLIST="${SCRIPT_DIR}/com.airic-lenz.raid-integrity-monitor.plist.template"
SRC_VERSION="${SCRIPT_DIR}/../VERSION"

# Destination paths
INSTALL_BIN="${HOME}/bin"
DEST_BINARY="${INSTALL_BIN}/raid-integrity-monitor"
DEST_NOTIFY_APP="${INSTALL_BIN}/raid-integrity-monitor-notify.app"
DEST_NOTIFY_MACOS="${DEST_NOTIFY_APP}/Contents/MacOS"
DEST_NOTIFY="${DEST_NOTIFY_MACOS}/raid-integrity-monitor-notify"
DEST_NOTIFY_INFOPLIST="${DEST_NOTIFY_APP}/Contents/Info.plist"
DEST_CONFIG_DIR="${HOME}/.config/raid-integrity-monitor"
DEST_CONFIG="${DEST_CONFIG_DIR}/config.json"
DEST_DATA_DIR="${HOME}/.local/share/raid-integrity-monitor"
DEST_PLIST_DIR="${HOME}/Library/LaunchAgents"
DEST_PLIST="${DEST_PLIST_DIR}/com.airic-lenz.raid-integrity-monitor.plist"
PLIST_LABEL="com.airic-lenz.raid-integrity-monitor"

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    step "Uninstalling RAID Integrity Monitor"

    if launchctl list "$PLIST_LABEL" &>/dev/null; then
        launchctl unload "$DEST_PLIST" 2>/dev/null \
            && ok "LaunchAgent unloaded" \
            || info "LaunchAgent already unloaded"
    fi

    for f in "$DEST_PLIST" "$DEST_BINARY"; do
        if [[ -f "$f" ]]; then
            rm "$f" && ok "Removed: $f"
        fi
    done
    if [[ -d "$DEST_NOTIFY_APP" ]]; then
        rm -rf "$DEST_NOTIFY_APP" && ok "Removed: $(short "$DEST_NOTIFY_APP")"
    fi
    if [[ -d "$DEST_CONFIG_DIR" ]]; then
        rm -rf "$DEST_CONFIG_DIR" && ok "Removed: $(short "$DEST_CONFIG_DIR")"
    fi

    if [[ -d "$DEST_DATA_DIR" ]]; then
        printf '\nRemove data directory (logs and database)? [y/N] '
        local reply
        read -r reply
        if [[ "$reply" =~ ^[Yy]$ ]]; then
            rm -rf "$DEST_DATA_DIR" && ok "Removed: $(short "$DEST_DATA_DIR")"
        else
            info "Kept: $(short "$DEST_DATA_DIR")"
        fi
    fi

    printf '\nRAID Integrity Monitor has been uninstalled.\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
step "Pre-flight checks"

missing=false
for src in "$SRC_NOTIFY_PLIST" "$SRC_CONFIG" "$SRC_PLIST"; do
    if [[ ! -f "$src" ]]; then
        err "Required source file not found: ${src}"
        missing=true
    fi
done
[[ "$missing" == "true" ]] && die "Run install.sh from the IntegrityMonitor/ project directory."
ok "All source files present"

APP_VERSION="1.0.0"
if [[ -f "$SRC_VERSION" ]]; then
    APP_VERSION=$(<"$SRC_VERSION")
    APP_VERSION="${APP_VERSION// /}"
fi
ok "Version: ${APP_VERSION}"

# swift must be available (either Command Line Tools or Xcode)
if ! command -v swift &>/dev/null; then
    die "swift not found. Install Xcode or Command Line Tools: xcode-select --install"
fi
SWIFT_VER=$(swift --version 2>&1 | head -1)
ok "Swift: ${SWIFT_VER}"

command -v codesign &>/dev/null || die "codesign not found — is Xcode Command Line Tools installed?"
ok "codesign found"

# ---------------------------------------------------------------------------
# Step 0: Remove previous installation
# ---------------------------------------------------------------------------
step "Removing previous installation (if any)"

for old_plist in "${DEST_PLIST_DIR}"/*.raid-integrity-monitor.plist(N); do
    old_label=$(defaults read "$old_plist" Label 2>/dev/null || true)
    if [[ -n "$old_label" ]] && launchctl list "$old_label" &>/dev/null; then
        launchctl unload "$old_plist" 2>/dev/null || true
        ok "Unloaded LaunchAgent: ${old_label}"
    fi
    rm -f "$old_plist"
    ok "Removed plist: ${old_plist}"
done

if [[ -d "$DEST_NOTIFY_APP" ]]; then
    rm -rf "$DEST_NOTIFY_APP"
    ok "Removed previous app bundle: $(short "$DEST_NOTIFY_APP")"
fi
if [[ -f "$DEST_BINARY" ]]; then
    rm -f "$DEST_BINARY"
    ok "Removed previous binary: $(short "$DEST_BINARY")"
fi

# ---------------------------------------------------------------------------
# Step 1: Create directories
# ---------------------------------------------------------------------------
step "Creating directories"
mkdir -p "$INSTALL_BIN" "$DEST_NOTIFY_MACOS" "$DEST_CONFIG_DIR" "$DEST_DATA_DIR" "$DEST_PLIST_DIR"
ok "Directories ready"

# ---------------------------------------------------------------------------
# Step 2: Build
# ---------------------------------------------------------------------------
step "Building IntegrityMonitor (swift build -c release)"

# Use Xcode's Swift if available (needed for XCTest and framework linking)
if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
    export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
    ok "Using Xcode toolchain"
fi

(cd "$SCRIPT_DIR" && swift build -c release 2>&1) || die "swift build failed."
ok "Build complete"

BUILD_DIR="${SCRIPT_DIR}/.build/release"
[[ -f "${BUILD_DIR}/raid-integrity-monitor" ]] || die "raid-integrity-monitor binary not found in ${BUILD_DIR}"
[[ -f "${BUILD_DIR}/NotifyHelper" ]] || die "NotifyHelper binary not found in ${BUILD_DIR}"
ok "Binaries found in ${BUILD_DIR}"

# ---------------------------------------------------------------------------
# Step 3: Install main binary
# ---------------------------------------------------------------------------
step "Installing raid-integrity-monitor binary"
cp "${BUILD_DIR}/raid-integrity-monitor" "$DEST_BINARY" \
    || die "Failed to copy binary to ${DEST_BINARY}"
chmod +x "$DEST_BINARY"
ok "Installed: $(short "$DEST_BINARY")"

# ---------------------------------------------------------------------------
# Step 4: Build notification helper app bundle
# ---------------------------------------------------------------------------
step "Installing raid-integrity-monitor-notify.app"

cp "${BUILD_DIR}/NotifyHelper" "$DEST_NOTIFY" \
    || die "Failed to copy NotifyHelper binary"
chmod +x "$DEST_NOTIFY"
ok "Copied binary: $(short "$DEST_NOTIFY")"

# Install Info.plist with token substitution
sed -e "s|APP_VERSION|${APP_VERSION}|g" "$SRC_NOTIFY_PLIST" > "$DEST_NOTIFY_INFOPLIST" \
    || die "Failed to write ${DEST_NOTIFY_INFOPLIST}"
ok "Info.plist: $(short "$DEST_NOTIFY_INFOPLIST")"

# App icon (optional — place AppIcon.png in the project root directory)
SRC_ICON_PNG="${SCRIPT_DIR}/../AppIcon.png"
DEST_RESOURCES="${DEST_NOTIFY_APP}/Contents/Resources"
DEST_ICNS="${DEST_RESOURCES}/AppIcon.icns"

if [[ -f "$SRC_ICON_PNG" ]]; then
    step "Converting AppIcon.png → AppIcon.icns"
    mkdir -p "$DEST_RESOURCES"

    tmp_dir=$(mktemp -d)
    iconset="${tmp_dir}/AppIcon.iconset"
    mkdir "$iconset"

    sips -z 16   16   "$SRC_ICON_PNG" --out "${iconset}/icon_16x16.png"      > /dev/null
    sips -z 32   32   "$SRC_ICON_PNG" --out "${iconset}/icon_16x16@2x.png"   > /dev/null
    sips -z 32   32   "$SRC_ICON_PNG" --out "${iconset}/icon_32x32.png"      > /dev/null
    sips -z 64   64   "$SRC_ICON_PNG" --out "${iconset}/icon_32x32@2x.png"   > /dev/null
    sips -z 128  128  "$SRC_ICON_PNG" --out "${iconset}/icon_128x128.png"    > /dev/null
    sips -z 256  256  "$SRC_ICON_PNG" --out "${iconset}/icon_128x128@2x.png" > /dev/null
    sips -z 256  256  "$SRC_ICON_PNG" --out "${iconset}/icon_256x256.png"    > /dev/null
    sips -z 512  512  "$SRC_ICON_PNG" --out "${iconset}/icon_256x256@2x.png" > /dev/null
    sips -z 512  512  "$SRC_ICON_PNG" --out "${iconset}/icon_512x512.png"    > /dev/null
    sips -z 1024 1024 "$SRC_ICON_PNG" --out "${iconset}/icon_512x512@2x.png" > /dev/null

    iconutil -c icns "$iconset" -o "$DEST_ICNS" || die "iconutil failed"
    rm -rf "$tmp_dir"
    ok "Icon installed: $(short "$DEST_ICNS")"
else
    info "No AppIcon.png found — skipping icon"
fi

# Sign and register the app bundle
step "Signing notification helper app bundle (ad-hoc)"
codesign --sign - --force --deep "$DEST_NOTIFY_APP" || die "codesign failed."
ok "Signed: $(short "$DEST_NOTIFY_APP")"

step "Registering app bundle with Launch Services"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DEST_NOTIFY_APP" \
    && ok "Registered: $(short "$DEST_NOTIFY_APP")" \
    || info "lsregister failed — corner icon in notifications may appear as a white square"

# ---------------------------------------------------------------------------
# Step 5: Install config
# Fresh install: copy template. Reinstall: add new top-level keys only.
# ---------------------------------------------------------------------------
step "Installing config"

if [[ ! -f "$DEST_CONFIG" ]]; then
    cp "$SRC_CONFIG" "$DEST_CONFIG"
    ok "Config installed: $(short "$DEST_CONFIG")"
    info "Edit the config to set watchPaths and other settings before first use."
else
    # Add any top-level keys present in template but absent in existing config.
    # Requires python3 for JSON merging (built into macOS).
    if command -v python3 &>/dev/null; then
        new_keys=$(python3 - "$SRC_CONFIG" "$DEST_CONFIG" <<'PYEOF'
import json, sys
template = json.load(open(sys.argv[1]))
existing = json.load(open(sys.argv[2]))
added = []
for k, v in template.items():
    if k not in existing:
        existing[k] = v
        added.append(k)
if added:
    json.dump(existing, open(sys.argv[2], 'w'), indent=2)
    print(' '.join(added))
PYEOF
        )
        if [[ -n "$new_keys" ]]; then
            ok "New config keys added: ${new_keys}"
        else
            ok "Config up to date — no new settings: $(short "$DEST_CONFIG")"
        fi
    else
        info "python3 not found — skipping config merge. New keys may be missing."
        info "Compare $(short "$SRC_CONFIG") with $(short "$DEST_CONFIG") manually if needed."
    fi
fi

# ---------------------------------------------------------------------------
# Step 6: Install LaunchAgent plist
# ---------------------------------------------------------------------------
step "Installing LaunchAgent plist"

# Read RAID check interval from config (default: 5 min = 300 sec)
RAID_INTERVAL_MIN=5
if [[ -f "$DEST_CONFIG" ]] && command -v python3 &>/dev/null; then
    RAID_INTERVAL_MIN=$(python3 -c "
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
    print(cfg.get('schedule', {}).get('raidCheckIntervalMinutes', 5))
except: print(5)
" "$DEST_CONFIG")
fi
RAID_CHECK_INTERVAL=$((RAID_INTERVAL_MIN * 60))
ok "RAID check interval: every ${RAID_INTERVAL_MIN} minute(s) (${RAID_CHECK_INTERVAL}s)"

sed \
    -e "s|INSTALL_PATH|${INSTALL_BIN}|g" \
    -e "s|USERNAME|${USERNAME}|g" \
    -e "s|RAID_CHECK_INTERVAL|${RAID_CHECK_INTERVAL}|g" \
    "$SRC_PLIST" > "$DEST_PLIST" \
    || die "Failed to write plist to ${DEST_PLIST}"
ok "Plist installed: $(short "$DEST_PLIST")"

if grep -q 'INSTALL_PATH\|USERNAME\|RAID_CHECK_INTERVAL' "$DEST_PLIST" 2>/dev/null; then
    err "Plist still contains unreplaced tokens — check sed substitution"
    die "Plist installation failed."
fi
ok "Plist tokens substituted correctly"

# ---------------------------------------------------------------------------
# Step 7: Load the LaunchAgent
# ---------------------------------------------------------------------------
step "Loading LaunchAgent"
launchctl load "$DEST_PLIST" || die "launchctl load failed. Check ${DEST_PLIST} for errors."
ok "LaunchAgent loaded"

sleep 1
if launchctl list "$PLIST_LABEL" &>/dev/null; then
    ok "LaunchAgent confirmed active (label: ${PLIST_LABEL})"
else
    info "LaunchAgent not visible in launchctl list yet — check Console.app if issues arise"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
printf '\n'
ok "Installation complete."
printf '\n'
printf '  *** IMPORTANT — REQUIRED SETUP STEPS ***\n'
printf '\n'
printf '  1. Grant Full Disk Access (required for file scanning):\n'
printf '     System Settings → Privacy & Security → Full Disk Access\n'
printf '     Add: %s\n' "${DEST_BINARY/#$HOME/\~}"
printf '\n'
printf '  2. Build the baseline manifest (first run only):\n'
printf '     %s --mode init\n' "${DEST_BINARY/#$HOME/\~}"
printf '\n'
printf '  3. Verify the setup:\n'
printf '     %s --mode test\n' "${DEST_BINARY/#$HOME/\~}"
printf '\n'
printf '  4. On first test run, macOS will show a one-time system prompt:\n'
printf '     "RAID Integrity Monitor" would like to send notifications\n'
printf '     Click  Allow  to enable alerts.\n'
printf '\n'
printf '  5. Configure notifications (one-time):\n'
printf '     System Settings → Notifications → RAID Integrity Monitor\n'
printf '       Alert style  →  Alerts  (persistent pop-up, not Banners/None)\n'
printf '       Show on Lock Screen  →  On\n'
printf '\n'
printf '  The LaunchAgent runs every %s minute(s) for RAID checks.\n' "$RAID_INTERVAL_MIN"
printf '  File integrity scans run automatically every %s hours.\n' "$(python3 -c "
import json
try:
    cfg = json.load(open('$DEST_CONFIG'))
    print(cfg.get('schedule', {}).get('fileScanIntervalHours', 24))
except: print(24)
" 2>/dev/null || echo 24)"
printf '  To run a full scan immediately:\n'
printf '     %s --mode scan\n' "${DEST_BINARY/#$HOME/\~}"
printf '\n'
printf '  To uninstall: %s/install.sh --uninstall\n' "${SCRIPT_DIR/#$HOME/\~}"
printf '\n'
