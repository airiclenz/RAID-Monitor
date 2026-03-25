#!/bin/zsh
# install.sh — RAID Monitor installation script
# Run from the project directory: ./install.sh
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

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="${0:A:h}"       # absolute path to the directory containing install.sh
USERNAME=$(id -un)

# Source files (must be in the project directory alongside install.sh)
SRC_MONITOR="${SCRIPT_DIR}/raid-monitor.sh"
SRC_SWIFT="${SCRIPT_DIR}/notify-helper.swift"
SRC_NOTIFY_PLIST="${SCRIPT_DIR}/notify-helper-Info.plist"
SRC_CONFIG="${SCRIPT_DIR}/config.sh.template"
SRC_PLIST="${SCRIPT_DIR}/com.airic-lenz.raid-monitor.plist"
SRC_VERSION="${SCRIPT_DIR}/VERSION"

# Destination paths
INSTALL_BIN="${HOME}/bin"
DEST_MONITOR="${INSTALL_BIN}/raid-monitor.sh"
# Notification helper lives inside an app bundle so UNUserNotificationCenter
# can find CFBundleIdentifier in Contents/Info.plist at startup.
DEST_NOTIFY_APP="${INSTALL_BIN}/raid-monitor-notify.app"
DEST_NOTIFY_MACOS="${DEST_NOTIFY_APP}/Contents/MacOS"
DEST_NOTIFY="${DEST_NOTIFY_MACOS}/raid-monitor-notify"
DEST_NOTIFY_INFOPLIST="${DEST_NOTIFY_APP}/Contents/Info.plist"
DEST_CONFIG_DIR="${HOME}/.config/raid-monitor"
DEST_CONFIG="${DEST_CONFIG_DIR}/config.sh"
DEST_DATA_DIR="${HOME}/.local/share/raid-monitor"
DEST_PLIST_DIR="${HOME}/Library/LaunchAgents"
DEST_PLIST="${DEST_PLIST_DIR}/com.airic-lenz.raid-monitor.plist"
PLIST_LABEL="com.airic-lenz.raid-monitor"

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    step "Uninstalling RAID Monitor"

    # Unload agent if running
    if launchctl list "$PLIST_LABEL" &>/dev/null; then
        launchctl unload "$DEST_PLIST" 2>/dev/null \
            && ok "LaunchAgent unloaded" \
            || info "LaunchAgent already unloaded"
    fi

    # Remove files and app bundle
    local f
    for f in "$DEST_PLIST" "$DEST_MONITOR"; do
        if [[ -f "$f" ]]; then
            rm "$f" && ok "Removed: $f"
        fi
    done
    if [[ -d "$DEST_NOTIFY_APP" ]]; then
        rm -rf "$DEST_NOTIFY_APP" && ok "Removed: ${DEST_NOTIFY_APP}"
    fi

    # Remove directories (ask before removing data dir which contains logs/state)
    if [[ -d "$DEST_CONFIG_DIR" ]]; then
        rm -rf "$DEST_CONFIG_DIR" && ok "Removed: ${DEST_CONFIG_DIR}"
    fi

    if [[ -d "$DEST_DATA_DIR" ]]; then
        printf '\nRemove data directory (logs and state)? [y/N] '
        local reply
        read -r reply
        if [[ "$reply" =~ ^[Yy]$ ]]; then
            rm -rf "$DEST_DATA_DIR" && ok "Removed: ${DEST_DATA_DIR}"
        else
            info "Kept: ${DEST_DATA_DIR}"
        fi
    fi

    printf '\nRAID Monitor has been uninstalled.\n'
    exit 0
fi

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
step "Pre-flight checks"

# Verify source files are present
local missing=false
local src
for src in "$SRC_MONITOR" "$SRC_SWIFT" "$SRC_NOTIFY_PLIST" "$SRC_CONFIG" "$SRC_PLIST" "$SRC_VERSION"; do
    if [[ ! -f "$src" ]]; then
        err "Required source file not found: ${src}"
        missing=true
    fi
done
$missing && die "Run install.sh from the RAID Monitor project directory."
ok "All source files present"

APP_VERSION=$(<"$SRC_VERSION")
APP_VERSION="${APP_VERSION// /}"   # strip any accidental whitespace
ok "Version: ${APP_VERSION}"

# Check for swiftc (required to compile notify-helper.swift)
if ! command -v swiftc &>/dev/null; then
    err "swiftc not found. Xcode Command Line Tools are required."
    err "Install them with:  xcode-select --install"
    err "Then re-run this installer."
    exit 1
fi
local swiftc_ver
swiftc_ver=$(swiftc --version 2>&1 | head -1)
ok "swiftc: ${swiftc_ver}"

# Check for codesign
command -v codesign &>/dev/null || die "codesign not found — is Xcode Command Line Tools installed?"
ok "codesign found"

# ---------------------------------------------------------------------------
# Step 0: Remove any previous installation
#
# Catches both the current label and any old namespace (e.g. com.user.*) by
# scanning ~/Library/LaunchAgents for plists whose filename ends in
# "raid-monitor.plist".
# ---------------------------------------------------------------------------
step "Removing previous installation (if any)"

local old_plist
for old_plist in "${DEST_PLIST_DIR}"/*.raid-monitor.plist(N); do
    local old_label
    old_label=$(defaults read "$old_plist" Label 2>/dev/null || true)
    if [[ -n "$old_label" ]] && launchctl list "$old_label" &>/dev/null; then
        launchctl unload "$old_plist" 2>/dev/null || true
        ok "Unloaded LaunchAgent: ${old_label}"
    fi
    rm -f "$old_plist"
    ok "Removed plist: ${old_plist}"
done

# Remove previous app bundle and main script
if [[ -d "$DEST_NOTIFY_APP" ]]; then
    rm -rf "$DEST_NOTIFY_APP"
    ok "Removed previous app bundle: ${DEST_NOTIFY_APP}"
fi
if [[ -f "$DEST_MONITOR" ]]; then
    rm -f "$DEST_MONITOR"
    ok "Removed previous script: ${DEST_MONITOR}"
fi

# ---------------------------------------------------------------------------
# Step 1: Create directories
# ---------------------------------------------------------------------------
step "Creating directories"
mkdir -p "$INSTALL_BIN" "$DEST_NOTIFY_MACOS" "$DEST_CONFIG_DIR" "$DEST_DATA_DIR" "$DEST_PLIST_DIR"
ok "Directories ready"

# ---------------------------------------------------------------------------
# Step 2: Install main script
# ---------------------------------------------------------------------------
step "Installing raid-monitor.sh"
sed -e "s|APP_VERSION|${APP_VERSION}|g" "$SRC_MONITOR" > "$DEST_MONITOR" \
    || die "Failed to write ${DEST_MONITOR}"
chmod +x "$DEST_MONITOR"
ok "Installed: ${DEST_MONITOR} (v${APP_VERSION})"

# ---------------------------------------------------------------------------
# Step 3: Build notification helper app bundle
#
# UNUserNotificationCenter requires the calling process to have a bundle
# identity (CFBundleIdentifier in Info.plist). A bare CLI binary has none,
# causing a SIGABRT crash. Placing the binary inside an .app bundle with
# an Info.plist fixes this — macOS reads the bundle when the binary starts.
# ---------------------------------------------------------------------------
step "Compiling notify-helper.swift → raid-monitor-notify.app"
swiftc "$SRC_SWIFT" -o "$DEST_NOTIFY" 2>&1 || die "Swift compilation failed. Check swiftc output above."
ok "Compiled binary: ${DEST_NOTIFY}"

step "Installing app bundle Info.plist"
sed -e "s|APP_VERSION|${APP_VERSION}|g" "$SRC_NOTIFY_PLIST" > "$DEST_NOTIFY_INFOPLIST" \
    || die "Failed to write ${DEST_NOTIFY_INFOPLIST}"
ok "Info.plist: ${DEST_NOTIFY_INFOPLIST}"

# ---------------------------------------------------------------------------
# Step 3a: Build app icon from AppIcon.png (optional)
#
# Place a 1024×1024 AppIcon.png in the project directory to get a custom
# icon in notifications and System Settings → Notifications.
#
# The PNG is converted to .icns using sips + iconutil (both built into macOS).
# The iconset directory MUST end with ".iconset" — so we create it as a named
# subdirectory inside a plain temp dir, not via mktemp's own naming.
# ---------------------------------------------------------------------------
local SRC_ICON_PNG="${SCRIPT_DIR}/AppIcon.png"
local DEST_RESOURCES="${DEST_NOTIFY_APP}/Contents/Resources"
local DEST_ICNS="${DEST_RESOURCES}/AppIcon.icns"
local DEST_NOTIF_PNG="${DEST_RESOURCES}/notification-icon.png"

if [[ -f "$SRC_ICON_PNG" ]]; then
    step "Converting AppIcon.png → AppIcon.icns"
    mkdir -p "$DEST_RESOURCES"

    local tmp_dir iconset
    tmp_dir=$(mktemp -d)
    iconset="${tmp_dir}/AppIcon.iconset"   # must end in .iconset for iconutil
    mkdir "$iconset"

    # All ten required iconset files — no other filenames are accepted by iconutil
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

    iconutil -c icns "$iconset" -o "$DEST_ICNS" || die "iconutil failed — check that AppIcon.png is a valid PNG"
    rm -rf "$tmp_dir"
    ok "Icon installed: ${DEST_ICNS}"

    # Also copy the source PNG as the notification attachment thumbnail.
    # This is embedded directly in each notification banner, bypassing the
    # corner-icon rendering path that can show a white square for ad-hoc signed bundles.
    cp "$SRC_ICON_PNG" "$DEST_NOTIF_PNG"
    ok "Notification attachment icon: ${DEST_NOTIF_PNG}"
else
    info "No AppIcon.png in project directory — skipping icon (generic icon will be used)"
fi

step "Signing notification helper app bundle (ad-hoc)"
# Sign the whole bundle with --deep so both binary and bundle are covered.
codesign --sign - --force --deep "$DEST_NOTIFY_APP" \
    || die "codesign failed."
ok "Signed: ${DEST_NOTIFY_APP}"

# Verify
codesign --verify "$DEST_NOTIFY_APP" 2>/dev/null && ok "Signature verified" || info "Signature verification skipped"

# Register with Launch Services so macOS can resolve the app icon in
# notification banners. Without this, the corner icon shows as a white square.
step "Registering app bundle with Launch Services"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DEST_NOTIFY_APP" \
    && ok "Registered: ${DEST_NOTIFY_APP}" \
    || info "lsregister failed — corner icon in notifications may appear as a white square"

# ---------------------------------------------------------------------------
# Step 4: Install config (never overwrite an existing config)
# ---------------------------------------------------------------------------
step "Installing config"
if [[ -f "$DEST_CONFIG" ]]; then
    info "Config already exists — leaving unchanged: ${DEST_CONFIG}"
else
    cp "$SRC_CONFIG" "$DEST_CONFIG"
    ok "Config installed: ${DEST_CONFIG}"
    info "Edit the config to customise settings before your first use."
fi

# ---------------------------------------------------------------------------
# Step 5: Install LaunchAgent plist with token substitution
# ---------------------------------------------------------------------------
step "Installing LaunchAgent plist"

# Replace INSTALL_PATH and USERNAME tokens.
# Using | as sed delimiter to safely handle / in paths.
sed \
    -e "s|INSTALL_PATH|${INSTALL_BIN}|g" \
    -e "s|USERNAME|${USERNAME}|g" \
    "$SRC_PLIST" > "$DEST_PLIST" \
    || die "Failed to write plist to ${DEST_PLIST}"

ok "Plist installed: ${DEST_PLIST}"

# Sanity check: no literal tokens left
if grep -q 'INSTALL_PATH\|USERNAME' "$DEST_PLIST" 2>/dev/null; then
    err "Plist still contains unreplaced tokens — check sed substitution"
    err "Content of ${DEST_PLIST}:"
    cat "$DEST_PLIST" >&2
    die "Plist installation failed."
fi
ok "Plist tokens substituted correctly"

# ---------------------------------------------------------------------------
# Step 6: Load the LaunchAgent
# ---------------------------------------------------------------------------
step "Loading LaunchAgent"

launchctl load "$DEST_PLIST" || die "launchctl load failed. Check ${DEST_PLIST} for errors."
ok "LaunchAgent loaded"

# Give launchd a moment, then confirm
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
printf '  Next step — run the installation test:\n'
printf '\n'
printf '    %s --test\n' "$DEST_MONITOR"
printf '\n'
printf '  On first run, macOS will show a one-time system prompt:\n'
printf '    "RAID Monitor" would like to send notifications\n'
printf '  Click  Allow  to enable alerts.\n'
printf '\n'
printf '  After that, the LaunchAgent will monitor your RAID silently\n'
printf '  and alert you only when the array state changes.\n'
printf '\n'
printf '  To uninstall:  %s/install.sh --uninstall\n' "$SCRIPT_DIR"
printf '\n'
