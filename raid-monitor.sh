#!/bin/zsh
# raid-monitor.sh — macOS Apple Software RAID health monitor
# Version: APP_VERSION
# See technical-design-specification.md for full design rationale.
#
# Usage:
#   raid-monitor.sh           normal poll (called by launchd)
#   raid-monitor.sh --test    verify installation, send test notification

set -uo pipefail

# ---------------------------------------------------------------------------
# Paths — always use $HOME; launchd does not expand ~
# ---------------------------------------------------------------------------
readonly VERSION="APP_VERSION"
readonly SCRIPT_PATH="${0:A}"
readonly SCRIPT_DIR="${SCRIPT_PATH:h}"
readonly NOTIFY_BIN="${SCRIPT_DIR}/raid-monitor-notify.app/Contents/MacOS/raid-monitor-notify"

readonly CONFIG_DIR="${HOME}/.config/raid-monitor"
readonly DATA_DIR="${HOME}/.local/share/raid-monitor"
readonly CONFIG_FILE="${CONFIG_DIR}/config.sh"
readonly STATE_FILE="${DATA_DIR}/state"
readonly STATE_TMP="${DATA_DIR}/state.tmp"
readonly LOG_FILE="${DATA_DIR}/raid-monitor.log"
readonly LOG_ARCHIVE="${DATA_DIR}/raid-monitor.log.1"

# ---------------------------------------------------------------------------
# Defaults — all overridable via config.sh
# ---------------------------------------------------------------------------
POLL_INTERVAL_SECONDS=300
NOTIFY_ON_ONLINE=false
EMAIL_ENABLED=false
EMAIL_TO=""
EMAIL_FROM=""
LOG_MAX_SIZE_MB=5
ARRAY_UUID_FILTER=""
TRANSIENT_RECHECK_SECONDS=30

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
_load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE" 2>/dev/null || _log WARN "Config file could not be sourced: ${CONFIG_FILE}"
    else
        _log WARN "Config file not found: ${CONFIG_FILE} — using defaults"
    fi
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
_rotate_log() {
    [[ -f "$LOG_FILE" ]] || return 0
    local size_bytes
    size_bytes=$(stat -f%z "$LOG_FILE" 2>/dev/null || printf '0')
    local max_bytes=$(( LOG_MAX_SIZE_MB * 1024 * 1024 ))
    if (( size_bytes >= max_bytes )); then
        mv "$LOG_FILE" "$LOG_ARCHIVE"
    fi
}

_log() {
    local level="$1"; shift
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local line="[${ts}] [${level}] $*"
    printf '%s\n' "$line" >> "$LOG_FILE"
    # Echo to stdout so launchd stdout log also captures it
    printf '%s\n' "$line"
}

# ---------------------------------------------------------------------------
# awk-based diskutil parser
#
# Reads 'diskutil appleRAID list' output on stdin and emits key=value lines:
#   array_count=N
#   array_0_uuid=F71DAB1B-...
#   array_0_name=G-Raid
#   array_0_status=Online
#   array_0_member_count=2
#   array_0_member_0_dev=disk8s2
#   array_0_member_0_status=Online
#   array_0_member_1_dev=disk9s2
#   array_0_member_1_status=8% (Rebuilding)
# ---------------------------------------------------------------------------
_parse_diskutil() {
    awk '
    BEGIN {
        aidx = -1
        midx = 0
        in_members = 0
    }

    # "AppleRAID sets (N found)"
    /AppleRAID sets \(/ {
        tmp = $0
        sub(/.*\(/, "", tmp)
        sub(/ .*/, "", tmp)
        print "array_count=" (tmp + 0)
        next
    }

    # ===...=== separator marks the start of a new array block
    /^={5,}/ {
        if (aidx >= 0 && in_members) {
            print "array_" aidx "_member_count=" midx
        }
        aidx++
        in_members = 0
        midx = 0
        next
    }

    # Nothing to parse until we have seen at least one === line
    aidx < 0 { next }

    # ---...--- separator marks start of member list
    /^-{5,}/ {
        in_members = 1
        midx = 0
        next
    }

    # Skip member-list header
    /^[[:space:]]*#[[:space:]]+DevNode/ { next }

    # -----------------------------------------------------------------------
    # Array-level properties (before member list)
    # -----------------------------------------------------------------------
    !in_members {
        line = $0
        sub(/^[[:space:]]+/, "", line)

        if (line ~ /^Name:/) {
            sub(/^Name:[[:space:]]+/, "", line)
            print "array_" aidx "_name=" line
        } else if (line ~ /^Unique ID:/) {
            sub(/^Unique ID:[[:space:]]+/, "", line)
            print "array_" aidx "_uuid=" line
        } else if (line ~ /^Status:/) {
            sub(/^Status:[[:space:]]+/, "", line)
            print "array_" aidx "_status=" line
        }
    }

    # -----------------------------------------------------------------------
    # Member lines: "  N  diskXsY  UUID  Status  Size"
    # Status may contain spaces, e.g. "8% (Rebuilding)"
    # -----------------------------------------------------------------------
    in_members && /^[[:space:]]*[0-9]+[[:space:]]/ {
        line = $0
        sub(/^[[:space:]]+/, "", line)      # strip leading whitespace

        sub(/^[0-9]+[[:space:]]+/, "", line) # remove member index
        sub(/^[[:space:]]+/, "", line)

        # Extract devnode (next non-space token)
        devnode = line
        sub(/[[:space:]].*/, "", devnode)
        sub(/^[^[:space:]]+[[:space:]]+/, "", line)
        sub(/^[[:space:]]+/, "", line)

        # Skip UUID (next non-space token — always in field 3)
        sub(/^[^[:space:]]+[[:space:]]+/, "", line)
        sub(/^[[:space:]]+/, "", line)

        # line is now: "Status  N.N TB (N Bytes)"  or  "8% (Rebuilding)  N.N TB ..."
        # Remove trailing size info: a number (int or decimal) followed by TB/GB/MB/KB/Bytes
        sub(/[[:space:]]+[0-9][0-9]*(\.[0-9]+)?[[:space:]]+(TB|GB|MB|KB|Bytes).*$/, "", line)
        sub(/[[:space:]]+$/, "", line)

        print "array_" aidx "_member_" midx "_dev=" devnode
        print "array_" aidx "_member_" midx "_status=" line
        midx++
    }

    END {
        # Flush member count for the last array
        if (aidx >= 0 && in_members) {
            print "array_" aidx "_member_count=" midx
        }
    }
    '
}

# Load parsed diskutil output into global associative array CURRENT
typeset -gA CURRENT
_load_current() {
    local raw_output="$1"
    CURRENT=()
    local line k v
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        k="${line%%=*}"
        v="${line#*=}"
        CURRENT[$k]="$v"
    done < <(printf '%s\n' "$raw_output" | _parse_diskutil)
}

# Load state file into global associative array PRIOR
typeset -gA PRIOR
_load_state() {
    PRIOR=()
    [[ -f "$STATE_FILE" ]] || return 1
    local line k v
    while IFS= read -r line; do
        [[ "$line" == "#"* ]] && continue
        [[ -z "$line" ]] && continue
        k="${line%%=*}"
        v="${line#*=}"
        [[ -n "$k" ]] && PRIOR[$k]="$v"
    done < "$STATE_FILE"
    return 0
}

# Write CURRENT state to STATE_FILE atomically
_write_state() {
    local count="${CURRENT[array_count]:-0}"
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    {
        printf '# raid-monitor state — do not edit manually\n'
        printf 'last_checked=%s\n' "$ts"
        printf 'array_count=%s\n' "$count"

        local i
        for (( i = 0; i < count; i++ )); do
            printf 'array_%d_uuid=%s\n'   $i "${CURRENT[array_${i}_uuid]:-}"
            printf 'array_%d_name=%s\n'   $i "${CURRENT[array_${i}_name]:-}"
            printf 'array_%d_status=%s\n' $i "${CURRENT[array_${i}_status]:-}"

            local mc="${CURRENT[array_${i}_member_count]:-0}"
            printf 'array_%d_member_count=%s\n' $i "$mc"

            local m
            for (( m = 0; m < mc; m++ )); do
                printf 'array_%d_member_%d_dev=%s\n'    $i $m "${CURRENT[array_${i}_member_${m}_dev]:-}"
                printf 'array_%d_member_%d_status=%s\n' $i $m "${CURRENT[array_${i}_member_${m}_status]:-}"
            done
        done
    } > "$STATE_TMP" || {
        _log CRIT "Failed to write state to ${STATE_TMP} — disk full or permissions problem"
        return 1
    }

    mv "$STATE_TMP" "$STATE_FILE" || {
        _log CRIT "Failed to rename ${STATE_TMP} → ${STATE_FILE}"
        return 1
    }
}

# ---------------------------------------------------------------------------
# Notification and email
# ---------------------------------------------------------------------------
_notify() {
    local title="$1" subtitle="$2" body="$3" level="${4:-warning}"

    if [[ ! -x "$NOTIFY_BIN" ]]; then
        _log CRIT "Notification helper not found or not executable: ${NOTIFY_BIN}"
        return 1
    fi

    "$NOTIFY_BIN" \
        --title    "$title"    \
        --subtitle "$subtitle" \
        --body     "$body"     \
        --level    "$level"    \
        2>>"$LOG_FILE" \
    || _log ERROR "Notification helper exited with error (code $?)"
}

_send_email() {
    local subject="$1" body_text="$2"
    [[ "${EMAIL_ENABLED:-false}" == "true" ]] || return 0
    if [[ -z "${EMAIL_TO:-}" ]]; then
        _log WARN "EMAIL_ENABLED=true but EMAIL_TO is not set — skipping email"
        return 0
    fi

    local ts
    ts=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
    local full_body
    printf -v full_body '%s\n\nTime: %s\n\n-- raid-monitor v%s' "$body_text" "$ts" "$VERSION"

    local headers
    printf -v headers 'To: %s\nSubject: %s\nContent-Type: text/plain; charset=utf-8\n' \
        "$EMAIL_TO" "$subject"
    [[ -n "${EMAIL_FROM:-}" ]] && headers="From: ${EMAIL_FROM}\n${headers}"

    if command -v msmtp &>/dev/null; then
        printf '%s\n%s\n' "$headers" "$full_body" \
            | msmtp --read-envelope-from -t 2>>"$LOG_FILE" \
            && _log INFO "Email sent via msmtp to ${EMAIL_TO}" \
            || _log ERROR "msmtp delivery failed (code $?)"
    elif command -v sendmail &>/dev/null; then
        printf '%s\n%s\n' "$headers" "$full_body" \
            | sendmail -t 2>>"$LOG_FILE" \
            && _log INFO "Email sent via sendmail to ${EMAIL_TO}" \
            || _log ERROR "sendmail delivery failed (code $?)"
    else
        _log ERROR "EMAIL_ENABLED=true but neither msmtp nor sendmail was found in PATH"
    fi
}

# Issue a notification + optional email for a state change
_alert() {
    local name="$1" uuid="$2" status="$3" level="$4" body_text="$5" prev_status="$6"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M')

    # Notification body includes timestamp
    _notify "RAID Alert — ${name}" "Status: ${status}" "${body_text}  [${ts}]" "$level" || true

    # Email includes fuller context
    if [[ "${EMAIL_ENABLED:-false}" == "true" ]]; then
        local mc="${CURRENT[array_$(find_current_idx "$uuid")_member_count]:-0}"
        local member_lines=""
        local cur_idx
        cur_idx=$(find_current_idx "$uuid")
        if [[ -n "$cur_idx" ]]; then
            local m
            for (( m = 0; m < mc; m++ )); do
                member_lines+="  #${m}  ${CURRENT[array_${cur_idx}_member_${m}_dev]:-?}"
                member_lines+="  ${CURRENT[array_${cur_idx}_member_${m}_status]:-?}"$'\n'
            done
        fi

        local email_body
        printf -v email_body \
            'Array:    %s\nUUID:     %s\nStatus:   %s\n\nMembers:\n%s\nPrevious status: %s\n\nAction required: Run: diskutil appleRAID list' \
            "$name" "$uuid" "$status" "$member_lines" "$prev_status"

        _send_email "[RAID Monitor] ${name} — Status: ${status}" "$email_body" || true
    fi
}

# Return the index in CURRENT where array_N_uuid == $1, or empty string
find_current_idx() {
    local target_uuid="$1"
    local count="${CURRENT[array_count]:-0}"
    local i
    for (( i = 0; i < count; i++ )); do
        if [[ "${CURRENT[array_${i}_uuid]:-}" == "$target_uuid" ]]; then
            printf '%s' "$i"
            return 0
        fi
    done
    return 1
}

# Return the index in PRIOR where array_N_uuid == $1, or empty string
find_prior_idx() {
    local target_uuid="$1"
    local count="${PRIOR[array_count]:-0}"
    local i
    for (( i = 0; i < count; i++ )); do
        if [[ "${PRIOR[array_${i}_uuid]:-}" == "$target_uuid" ]]; then
            printf '%s' "$i"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Transient-disappearance re-check
# Returns 0 if the array reappeared (no alert needed), 1 if still gone
# ---------------------------------------------------------------------------
_recheck_after_sleep() {
    local uuid="$1" name="$2"
    _log INFO "Array '${name}' (${uuid}) not found — waiting ${TRANSIENT_RECHECK_SECONDS}s to confirm (possible wake from sleep)"
    sleep "$TRANSIENT_RECHECK_SECONDS"

    local recheck_output
    recheck_output=$(diskutil appleRAID list 2>&1) || true

    # Quick UUID grep — if the UUID appears anywhere in the recheck output,
    # the array came back.
    if printf '%s\n' "$recheck_output" | grep -qF "$uuid"; then
        _log INFO "Array '${name}' (${uuid}) reappeared after transient absence — no alert"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Core comparison: CURRENT vs PRIOR
# ---------------------------------------------------------------------------
_compare_and_alert() {
    local current_count="${CURRENT[array_count]:-0}"
    local prior_count="${PRIOR[array_count]:-0}"

    # Check every array that was present in prior state
    local i
    for (( i = 0; i < prior_count; i++ )); do
        local uuid="${PRIOR[array_${i}_uuid]:-}"
        local p_name="${PRIOR[array_${i}_name]:-unknown}"
        local p_status="${PRIOR[array_${i}_status]:-Unknown}"

        [[ -z "$uuid" ]] && continue

        # Apply UUID filter if configured
        if [[ -n "${ARRAY_UUID_FILTER:-}" && "$uuid" != "$ARRAY_UUID_FILTER" ]]; then
            continue
        fi

        # Find this UUID in current state
        local cur_idx
        cur_idx=$(find_current_idx "$uuid") || true

        if [[ -z "$cur_idx" ]]; then
            # Array is missing from current diskutil output
            local do_alert=true

            if [[ "$p_status" == "Online" ]]; then
                # Online arrays: do transient re-check before alerting
                if _recheck_after_sleep "$uuid" "$p_name"; then
                    do_alert=false
                    # Re-load CURRENT from the recheck so state reflects reality
                    local recheck_output
                    recheck_output=$(diskutil appleRAID list 2>&1) || true
                    [[ -n "$recheck_output" ]] && _load_current "$recheck_output"
                fi
            fi
            # Degraded/Failed/Unknown arrays: alert immediately (no transient check)

            if $do_alert; then
                _log CRIT "Array '${p_name}' (${uuid}) has disappeared from diskutil output"
                _alert "$p_name" "$uuid" "Disappeared" "critical" \
                    "Array '${p_name}' is no longer visible to the system. Check enclosure power and connections." \
                    "$p_status"
            fi
            continue
        fi

        # Array is present — compare status
        local c_status="${CURRENT[array_${cur_idx}_status]:-Unknown}"
        local c_name="${CURRENT[array_${cur_idx}_name]:-$p_name}"

        if [[ "$c_status" != "$p_status" ]]; then
            _log INFO "Array '${c_name}' (${uuid}): ${p_status} → ${c_status}"
            _handle_status_change "$c_name" "$uuid" "$p_status" "$c_status" "$cur_idx"
        else
            _log INFO "Array '${c_name}' (${uuid}): unchanged (${c_status})"
        fi
    done

    # Log any newly appearing arrays (first-run or new array added)
    local j
    for (( j = 0; j < current_count; j++ )); do
        local uuid="${CURRENT[array_${j}_uuid]:-}"
        local c_name="${CURRENT[array_${j}_name]:-unknown}"
        local c_status="${CURRENT[array_${j}_status]:-Unknown}"
        [[ -z "$uuid" ]] && continue

        local prior_idx
        prior_idx=$(find_prior_idx "$uuid") || true
        if [[ -z "$prior_idx" ]]; then
            _log INFO "Array '${c_name}' (${uuid}) first seen — status: ${c_status}"
        fi
    done
}

_handle_status_change() {
    local name="$1" uuid="$2" prev_status="$3" cur_status="$4" cur_idx="$5"

    # Build member summary for notification body
    local mc="${CURRENT[array_${cur_idx}_member_count]:-0}"
    local member_summary=""
    local m
    for (( m = 0; m < mc; m++ )); do
        local mdev="${CURRENT[array_${cur_idx}_member_${m}_dev]:-?}"
        local mst="${CURRENT[array_${cur_idx}_member_${m}_status]:-?}"
        member_summary+="#${m} ${mdev}: ${mst}. "
    done
    member_summary="${member_summary%. }"  # trim trailing ". "

    local level body

    case "$cur_status" in
        Online)
            if [[ "${NOTIFY_ON_ONLINE:-false}" != "true" ]]; then
                _log INFO "Array '${name}' returned to Online — NOTIFY_ON_ONLINE=false, suppressing alert"
                return 0
            fi
            level="info"
            body="Array is back Online. ${member_summary}"
            ;;
        Degraded)
            level="warning"
            body="${member_summary:+${member_summary}. }Check Disk Utility."
            ;;
        Failed)
            level="critical"
            body="Array has FAILED. Immediate attention required. ${member_summary}"
            ;;
        *)
            # Handles "Rebuilding" or any other unexpected state string
            if [[ "$cur_status" == *"Rebuilding"* ]]; then
                level="info"
                body="Rebuild in progress. ${member_summary}"
            else
                level="warning"
                body="Unknown state: '${cur_status}'. ${member_summary}"
            fi
            ;;
    esac

    _log "${level:u}" "Alerting: '${name}' → ${cur_status} (was: ${prev_status}). ${body}"
    _alert "$name" "$uuid" "$cur_status" "$level" "$body" "$prev_status"
}

# ---------------------------------------------------------------------------
# --test mode
# ---------------------------------------------------------------------------
_test_mode() {
    printf 'raid-monitor v%s — installation test\n\n' "$VERSION"

    local ok=true

    # Check notify binary
    if [[ -x "$NOTIFY_BIN" ]]; then
        printf '[OK]   Notification helper: %s\n' "$NOTIFY_BIN"
    else
        printf '[FAIL] Notification helper not found or not executable: %s\n' "$NOTIFY_BIN" >&2
        printf '       Compile it with:\n' >&2
        printf '         swiftc notify-helper.swift -o %s\n' "$NOTIFY_BIN" >&2
        printf '         codesign --sign - --identifier com.airic-lenz.raid-monitor %s\n' "$NOTIFY_BIN" >&2
        ok=false
    fi

    # Check data directory
    if [[ -d "$DATA_DIR" ]]; then
        printf '[OK]   Data directory: %s\n' "$DATA_DIR"
    else
        printf '[WARN] Data directory missing: %s — creating\n' "$DATA_DIR"
        mkdir -p "$DATA_DIR" || { printf '[FAIL] Could not create data directory\n' >&2; ok=false; }
    fi

    # Check config
    if [[ -f "$CONFIG_FILE" ]]; then
        printf '[OK]   Config file: %s\n' "$CONFIG_FILE"
    else
        printf '[WARN] Config file not found — defaults will be used\n'
    fi

    # Check diskutil
    if command -v diskutil &>/dev/null; then
        printf '[OK]   diskutil found\n'
        local du_test
        du_test=$(diskutil appleRAID list 2>&1) || true
        if [[ -n "$du_test" ]]; then
            printf '[OK]   diskutil appleRAID list returned output\n'
            # Quick parse to show array count
            local ac
            ac=$(printf '%s\n' "$du_test" | awk '/AppleRAID sets \(/{tmp=$0; sub(/.*\(/,"",tmp); sub(/ .*/,"",tmp); print tmp+0}')
            printf '       Arrays currently visible: %s\n' "${ac:-0}"
        else
            printf '[WARN] diskutil appleRAID list returned empty output\n'
        fi
    else
        printf '[FAIL] diskutil not found in PATH\n' >&2
        ok=false
    fi

    if ! $ok; then
        printf '\nPre-checks failed — fix the above before using raid-monitor.\n' >&2
        exit 1
    fi

    # Send test notification
    printf '\nSending test notification...\n'
    printf '(macOS may ask once: "RAID Monitor" would like to send notifications — click Allow)\n\n'

    _log INFO "[TEST] Installation test initiated"

    if "$NOTIFY_BIN" \
            --title    "RAID Monitor" \
            --subtitle "Installation verified" \
            --body     "raid-monitor v${VERSION} is correctly installed and can deliver notifications." \
            --level    "info" \
            2>>"$LOG_FILE"; then
        printf '[OK]   Test notification sent\n'
        _log INFO "[TEST] Test notification delivered"
    else
        printf '[FAIL] Test notification failed (code %d)\n' $? >&2
        _log ERROR "[TEST] Test notification failed"
        exit 1
    fi

    # Test email if enabled
    if [[ "${EMAIL_ENABLED:-false}" == "true" ]]; then
        printf '\nSending test email to %s...\n' "$EMAIL_TO"
        _send_email \
            "[RAID Monitor] Test email" \
            "This is a test email from raid-monitor --test mode. If you received it, email delivery is working." \
            && printf '[OK]   Test email sent\n' \
            || printf '[FAIL] Test email failed — check log for details\n' >&2
    fi

    printf '\nTest complete. Check that the notification appeared on screen.\n'
    printf 'If it did not, open System Settings → Notifications → raid-monitor-notify\n'
    printf 'and ensure "Allow Notifications" is enabled.\n'
    _log INFO "[TEST] Test complete"
    exit 0
}

# ---------------------------------------------------------------------------
# diskutil runner — exits on hard failure, returns 1 on soft failure
# ---------------------------------------------------------------------------
_run_diskutil() {
    if ! command -v diskutil &>/dev/null; then
        _log CRIT "diskutil not found in PATH (${PATH})"
        _notify "RAID Monitor — System Error" \
            "diskutil not found" \
            "Cannot query RAID status. Check PATH in the LaunchAgent plist." \
            "critical" || true
        exit 1
    fi

    local output
    output=$(diskutil appleRAID list 2>&1)
    local exit_code=$?

    if (( exit_code != 0 )); then
        _log WARN "diskutil appleRAID list exited ${exit_code}: ${output}"
        return 1
    fi

    if [[ -z "$output" ]]; then
        _log WARN "diskutil appleRAID list returned empty output — skipping poll"
        return 1
    fi

    printf '%s' "$output"
    return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    # Ensure data directory exists before any logging
    mkdir -p "$DATA_DIR"

    # Rotate log first, then load config (config may change LOG_MAX_SIZE_MB)
    # We call rotate again after config load in case the threshold changed.
    _rotate_log

    # Load configuration
    _load_config
    _rotate_log  # Re-check with potentially updated LOG_MAX_SIZE_MB

    _log INFO "Poll started (v${VERSION})"

    # 1. Query diskutil
    local diskutil_output
    diskutil_output=$(_run_diskutil) || {
        _log WARN "Skipping poll cycle due to diskutil failure"
        exit 0
    }

    # 2. Parse current state from diskutil output
    _load_current "$diskutil_output"

    if [[ -z "${CURRENT[array_count]:-}" ]]; then
        _log WARN "diskutil output could not be parsed (unexpected format) — skipping poll"
        _log WARN "Raw output was: ${diskutil_output}"
        exit 0
    fi

    _log INFO "diskutil reports ${CURRENT[array_count]} array(s)"

    # 3. Load prior state and compare
    if _load_state; then
        _log INFO "Prior state loaded (last checked: ${PRIOR[last_checked]:-unknown})"
        _compare_and_alert
    else
        _log INFO "No prior state — first run. Recording current state, no alerts."
    fi

    # 4. Persist new state
    _write_state || {
        _log CRIT "State write failed — state may be stale on next poll"
        exit 1
    }

    _log INFO "Poll complete"
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--test" ]]; then
    # Config must be loaded before test mode so EMAIL_ENABLED etc. are available
    mkdir -p "$DATA_DIR"
    _rotate_log
    _load_config
    _test_mode
fi

main "$@"
