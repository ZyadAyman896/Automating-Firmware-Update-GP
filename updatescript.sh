#!/bin/bash
# ==============================================================================
# FOTA (Firmware Over The Air) Update Script – Phase 1
# Project: Trial-For-GP
# Description: Checks for updates on GitHub, backs up current code,
#              pulls the latest version, verifies it, and runs it.
#              Falls back to backup if anything goes wrong.
# ==============================================================================

# ==============================================================================
# CONFIGURATION – edit these to match your setup
# ==============================================================================
REPO_PATH="/home/drivx/projects/Trial-For-GP"
BACKUP_PATH="/home/drivx/projects/Trial-For-GP-backup"
BRANCH="main"
Updated_Firmware="UpdatedFirmware.py"                # the file your firmware runs
VERSION_FILE="version.txt"                          # file inside repo that holds version string
LOG_FILE="/home/drivx/update_log.txt"
WIFI_INTERFACE="wlan0"                             #changeable
WIFI_TIMEOUT=30                                     # seconds to wait for WiFi before giving up
WIFI_RETRY_INTERVAL=6                               # seconds between WiFi retries

# ==============================================================================
# LOGGING HELPER
# Prints a timestamped message to both the terminal and the log file.
# ==============================================================================
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# ==============================================================================
# STEP 1 – CHECK WIFI
# Waits up to WIFI_TIMEOUT seconds for the interface to get an IP address.
# ==============================================================================
check_wifi() {
    log "INFO" "Checking WiFi connection on $WIFI_INTERFACE..."
    local elapsed=0

    while [ $elapsed -lt $WIFI_TIMEOUT ]; do
        # 'ip addr' returns the IP assigned to the interface; grep filters for it
        if ip addr show "$WIFI_INTERFACE" 2>/dev/null | grep -q "inet "; then
            log "INFO" "WiFi connected."
            return 0
        fi
        log "INFO" "WiFi not ready. Retrying in ${WIFI_RETRY_INTERVAL}s... (${elapsed}s elapsed)"
        sleep "$WIFI_RETRY_INTERVAL"
        elapsed=$((elapsed + WIFI_RETRY_INTERVAL))
    done

    log "ERROR" "WiFi not available after ${WIFI_TIMEOUT}s. Skipping update."
    return 1
}

# ==============================================================================
# STEP 2 – CHECK REPO EXISTS
# If the repo folder is missing, clone it fresh from GitHub.
# ==============================================================================
check_repo() {
    log "INFO" "Checking if repo exists at $REPO_PATH..."

    if [ ! -d "$REPO_PATH/.git" ]; then
        log "WARN" "Repo not found. Attempting to clone..."

        # Extract the remote URL from git config if available, otherwise fail clearly
        # You can hardcode your repo URL here as a fallback:
        local REPO_URL="https://github.com/ZyadAyman896/Trial-For-GP.git"

        git clone "$REPO_URL" "$REPO_PATH" 2>>"$LOG_FILE"
        if [ $? -ne 0 ]; then
            log "ERROR" "git clone failed. Cannot continue."
            return 1
        fi
        log "INFO" "Repo cloned successfully."
    else
        log "INFO" "Repo found."
    fi
    return 0
}

# ==============================================================================
# STEP 3 – CHECK BRANCH
# Switches to the correct branch if not already on it.
# ==============================================================================
check_branch() {
    log "INFO" "Checking current branch..."

    cd "$REPO_PATH" || { log "ERROR" "Cannot cd into $REPO_PATH"; return 1; }

    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>>"$LOG_FILE")

    if [ "$current_branch" != "$BRANCH" ]; then
        log "WARN" "On branch '$current_branch', switching to '$BRANCH'..."
        git checkout "$BRANCH" 2>>"$LOG_FILE"
        if [ $? -ne 0 ]; then
            log "ERROR" "Failed to switch to branch '$BRANCH'."
            return 1
        fi
        log "INFO" "Switched to branch '$BRANCH'."
    else
        log "INFO" "Already on branch '$BRANCH'."
    fi
    return 0
}


# ==============================================================================
# STEP 4 – READ LOCAL VERSION
# Reads the version string from the local version.txt file.
# ==============================================================================
get_local_version() {
local version_path="$REPO_PATH/$VERSION_FILE"
    if [ ! -f "$version_path" ]; then
        echo "0.0.0"
        return
    fi
    # Use a variable to hold the version and echo only that
    local ver=$(cat "$version_path" | tr -d '[:space:]')
    echo "$ver"
}

# ==============================================================================
# STEP 5 – FETCH AND READ REMOTE VERSION
# Fetches remote metadata (no file changes yet) and reads the remote version.
# ==============================================================================
get_remote_version() {
cd "$REPO_PATH" || return 1
    # Suppress git output from being captured
    git fetch origin "$BRANCH" &>/dev/null
    
    local ver=$(git show "origin/$BRANCH:$VERSION_FILE" 2>/dev/null | tr -d '[:space:]')
    echo "$ver"
}

# ==============================================================================
# STEP 6 – COMPARE VERSIONS
# Simple string comparison. Returns 0 (equal) or 1 (different).
# For semantic versioning comparison, this can be upgraded later.
# ==============================================================================
versions_differ() {
    local local_ver="$1"
    local remote_ver="$2"

    if [ "$local_ver" = "$remote_ver" ]; then
        log "INFO" "Already on latest version ($local_ver). No update needed."
        return 1 # 1 = same = no update needed
    else
        log "INFO" "Update available: $local_ver -> $remote_ver"
        return 0 # 0 = different = update needed
    fi
}

# ==============================================================================
# STEP 7 – BACKUP CURRENT CODE
# Copies the entire repo folder to a backup location before pulling.
# This runs BEFORE the pull so we always have something to roll back to.
# ==============================================================================
backup_current() {
    log "INFO" "Backing up current code to $BACKUP_PATH..."

    # Remove old backup first so we get a clean copy
    rm -rf "$BACKUP_PATH"
    cp -r "$REPO_PATH" "$BACKUP_PATH"

    if [ $? -ne 0 ]; then
        log "ERROR" "Backup failed. Aborting update to protect current code."
        return 1
    fi

    log "INFO" "Backup complete."
    return 0
}

# ==============================================================================
# STEP 8 – PULL UPDATE
# Downloads the latest code from the remote branch.
# ==============================================================================
pull_update() {
    log "INFO" "Pulling latest code from origin/$BRANCH..."

    cd "$REPO_PATH" || return 1

    git pull origin "$BRANCH" 2>>"$LOG_FILE"
    if [ $? -ne 0 ]; then
        log "ERROR" "git pull failed."
        return 1
    fi

    log "INFO" "Pull successful."
    return 0
}

# ==============================================================================
# STEP 9 – VERIFY DOWNLOAD
# Checks that the main script still exists and the version file updated.
# ==============================================================================

verify_update() {
    local expected_version="$1"
    log "INFO" "Verifying downloaded update..."

    # Check the main script exists
    if [ ! -f "$REPO_PATH/$Updated_Firmware" ]; then
        log "ERROR" "Verification failed: $Updated_Firmware missing after pull."
        return 1
    fi

    # Check version file now matches the remote version we expected
    local new_version
    new_version=$(cat "$REPO_PATH/$VERSION_FILE" 2>/dev/null | tr -d '[:space:]')

    if [ "$new_version" != "$expected_version" ]; then
        log "ERROR" "Verification failed: expected version $expected_version but got '$new_version'."
        return 1
    fi

    log "INFO" "Verification passed. Running version: $new_version"
    return 0
}

# ==============================================================================
# STEP 10 – RESTORE BACKUP
# Called when pull or verification fails. Restores the backup copy.
# ==============================================================================
restore_backup() {
    log "WARN" "Restoring from backup..."

    if [ ! -d "$BACKUP_PATH" ]; then
        log "ERROR" "No backup found at $BACKUP_PATH. Cannot restore."
        return 1
    fi

    rm -rf "$REPO_PATH"
    cp -r "$BACKUP_PATH" "$REPO_PATH"

    if [ $? -ne 0 ]; then
        log "ERROR" "Restore failed. System may be in a broken state."
        return 1
    fi

    log "INFO" "Restore complete. Running previous version."
    return 0
}

# ==============================================================================
# STEP 11 – RUN CODE
# Launches the main firmware script.
# ==============================================================================
run_code() {
    local code_path="$REPO_PATH/$Updated_Firmware"
    log "INFO" "Launching $code_path..."

    if [ ! -f "$code_path" ]; then
        log "ERROR" "Cannot run: $code_path not found."
        return 1
    fi

    python3 "$code_path"
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log "ERROR" "$Updated_Firmware exited with code $exit_code."
        return 1
    fi

    return 0
}

# ==============================================================================
# MAIN – orchestrates all steps in order
# ==============================================================================
main() {
    log "INFO" "================================================"
    log "INFO" "FOTA Update Script started"
    log "INFO" "================================================"

    # --- Startup checks ---
    check_wifi || { run_code; exit $?; }
    check_repo || { run_code; exit $?; }
    check_branch || { run_code; exit $?; }

    # --- Version check ---
    local_version=$(get_local_version)
    remote_version=$(get_remote_version)

    # If we couldn't reach remote, just run what we have
    if [ -z "$remote_version" ]; then
        log "WARN" "Could not determine remote version. Running current code."
        run_code
        exit $?
    fi

    # --- Compare ---
    if ! versions_differ "$local_version" "$remote_version"; then
        # No update needed
        run_code
        exit $?
    fi

    # --- Update path ---
    backup_current || { run_code; exit $?; }

    pull_update
    if [ $? -ne 0 ]; then
        log "ERROR" "Pull failed. Restoring backup and running previous version."
        restore_backup
        run_code
        exit $?
    fi

    verify_update "$remote_version"
    if [ $? -ne 0 ]; then
        log "ERROR" "Verification failed. Restoring backup and running previous version."
        restore_backup
        run_code
        exit $?
    fi

    # --- Run new code ---
    run_code
    if [ $? -ne 0 ]; then
        log "ERROR" "New code crashed. Restoring backup and running previous version."
        restore_backup
        run_code
        exit $?
    fi

    log "INFO" "FOTA session complete."
}

# Entry point
main
