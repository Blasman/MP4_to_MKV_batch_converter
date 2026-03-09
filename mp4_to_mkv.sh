#!/bin/bash

###############################################
# USER SETTINGS
###############################################

# Root folder(s) to scan (space-separated)
SCAN_ROOTS=(
    "/mnt/user/Movies"
)

# Log file location
LOGFILE="/mnt/user/logs/mp4_to_mkv.log"

# MKVToolNix docker container name
CONTAINER="MKVToolNix"

# Host and MKVToolNix container root paths
HOST_ROOT="/mnt/user/Movies"
DOCKER_ROOT="/media"

# Optionally only process .mp4 files whose names match this regex (case-insensitive)
MATCH_REGEX="x265"

# Show files that were skipped due to regex matching or (if enabled with ONLY_PROCESS_FILES_WITH_MISSING_CTTS_ATOM) already containing a CTTS ATOM
# Options: YES / NO
SHOW_SKIPPED="NO"

# Add appropriately named .srt subtitle files found in movie folder to final .mkv file
# If using Radarr, be aware that Radarr will delete any .srt files in folder when rescanning the movie folder (a known issue)
# Options: YES / NO
PROCESS_SUBTITLES="YES"

# Delete original .mp4 file and any .srt files (if PROCESS_SUBTITLES is "YES") upon success of each conversion
# Options: YES / NO / ASK
DELETE_SOURCE="NO"

# Only process MP4 files that are missing the CTTS ATOM (requires AtomicParsley on host) https://github.com/wez/atomicparsley
ONLY_PROCESS_FILES_WITH_MISSING_CTTS_ATOM="NO"

# If ONLY_PROCESS_FILES_WITH_MISSING_CTTS_ATOM="YES" - keep a .txt file list of files that do have the CTTS ATOM (to prevent re-scanning on every script run)
LIST_OF_FILES_WITH_CTOS_ATOM="/mnt/user/logs/mp4_files_with_ctts_atom.txt"

###############################################
# RADARR SETTINGS
###############################################

# Enable Radarr integration? YES / NO
# Requires movie filenames to contain IMDb ID in format imdb-tt0468569
UPDATE_RADARR="NO"

# Radarr URL
RADARR_URL="http://192.168.1.1:7878"

# Radarr API key
RADARR_API_KEY=""

# Tag to apply after conversion
RADARR_TAG_NAME="mp4-to-mkv"

# Unmonitor movie? YES / NO
RADARR_UNMONITOR="YES"

###############################################
# VALIDATION CHECKS
###############################################

# 1. Check if Docker is installed
if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker is not installed or not in PATH."
    exit 1
fi

# 2. Check if container exists
if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "ERROR: Docker container '${CONTAINER}' does not exist."
    exit 1
fi

# 3. Check if container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "Container '${CONTAINER}' is not running. Starting it..."
    if ! docker start "$CONTAINER" >/dev/null; then
        echo "ERROR: Failed to start container '${CONTAINER}'."
        exit 1
    fi
    CONTAINER_STARTED_BY_SCRIPT=1
else
    CONTAINER_STARTED_BY_SCRIPT=0
fi

# 4. Check if mkvmerge exists inside container
if ! docker exec "$CONTAINER" which mkvmerge >/dev/null 2>&1; then
    echo "ERROR: mkvmerge is not available inside container '${CONTAINER}'."
    exit 1
fi

# CTTS ATOM checks
if [[ "$ONLY_PROCESS_FILES_WITH_MISSING_CTTS_ATOM" == "YES" ]]; then
    if ! command -v AtomicParsley >/dev/null 2>&1; then
        echo "ERROR: ONLY_PROCESS_FILES_WITH_MISSING_CTTS_ATOM=YES but AtomicParsley is not installed."
        echo "Please install AtomicParsley or set ONLY_PROCESS_FILES_WITH_MISSING_CTTS_ATOM=NO"
        exit 1
    fi
    # Resolve list file path: if user provided a directory (or trailing slash),
    # use a default filename inside that directory; otherwise treat value as file.
    if [[ -n "$LIST_OF_FILES_WITH_CTOS_ATOM" ]]; then
        if [[ -d "$LIST_OF_FILES_WITH_CTOS_ATOM" || "${LIST_OF_FILES_WITH_CTOS_ATOM: -1}" == "/" ]]; then
            LIST_OF_FILES_WITH_CTOS_ATOM_FILE="${LIST_OF_FILES_WITH_CTOS_ATOM%/}/mp4_files_with_ctts_atom.txt"
        else
            LIST_OF_FILES_WITH_CTOS_ATOM_FILE="$LIST_OF_FILES_WITH_CTOS_ATOM"
        fi
    else
        LIST_OF_FILES_WITH_CTOS_ATOM_FILE=""
    fi

    # Ensure the list file and parent dir exist
    if [[ -n "$LIST_OF_FILES_WITH_CTOS_ATOM_FILE" ]]; then
        mkdir -p "$(dirname "$LIST_OF_FILES_WITH_CTOS_ATOM_FILE")" 2>/dev/null || true
        touch "$LIST_OF_FILES_WITH_CTOS_ATOM_FILE" 2>/dev/null || true
    fi
fi

###############################################
# INTERNAL FUNCTIONS
###############################################

echo_ts() { printf "[%(%Y_%m_%d)T %(%H:%M:%S)T.${EPOCHREALTIME: -6:3}] $@\\n"; }

log() { echo_ts "$*" | tee -a "$LOGFILE"; }

docker_mkvmerge() {
    docker exec "$CONTAINER" mkvmerge "$@"
}

stop_container_if_needed() {
    if [[ "$CONTAINER_STARTED_BY_SCRIPT" -eq 1 ]]; then
        log "Stopping container '${CONTAINER}' (started by script)..."
        docker stop "$CONTAINER" >/dev/null
    fi
}

cleanup_and_exit() {
    echo ""
    log "===== CTRL-C detected — stopping early ====="

    if [[ "$CONTAINER_STARTED_BY_SCRIPT" -eq 1 ]]; then
        log "Stopping container '${CONTAINER}' (started by script)..."
        docker stop "$CONTAINER" >/dev/null

        log "The mkvmerge process for the current file has been terminated"
        log "because the container was stopped. You may want to manually"
        log "delete the partially created .mkv file."
        log "Source files for that file have NOT been deleted."
    else
        log "Container '${CONTAINER}' was already running before this script."
        log "The mkvmerge process for the current file will continue running"
        log "inside the container until it finishes naturally."
        log "Source files for that file will NOT be deleted."
    fi

    print_summary
    exit 1
}

print_summary() {
    log ""
    log "========== SUMMARY =========="
    log "Successful conversions: $success_count"
    log "Failed conversions:     $fail_count"
    log "Skipped: $skip_count"

    if (( fail_count > 0 )); then
        log ""
        log "Files that failed:"
        for i in "${!failed_files[@]}"; do
            log " - ${failed_files[$i]}"
            log "     ${failed_errors[$i]}"
        done
    fi

    if (( success_count > 0 )); then
        log ""
        log "Files that succeeded:"
        for f in "${success_files[@]}"; do
            log " - $f"
        done
    fi

    if [[ "$SHOW_SKIPPED" == "YES" && $skip_count -gt 0 ]]; then
        log ""
        log "Files that were skipped:"
        for f in "${skipped_files[@]}"; do
            log " - $f"
        done
    fi

    log "============================="
    log ""
}

update_radarr_for_movie() {
    local inputFile="$1"
    local filename="$(basename "$inputFile")"

    log "Updating Radarr for: $filename"

    # 1. Extract IMDb ID from filename
    local imdb_id
    imdb_id=$(echo "$filename" | grep -o 'imdb-tt[0-9]\+' | sed 's/imdb-//')

    if [[ -n "$imdb_id" ]]; then
        log "Radarr: Extracted IMDb ID: $imdb_id"
    else
        log "Radarr: No IMDb ID found in filename — cannot update Radarr"
        return
    fi

    # 2. Lookup movie in Radarr using IMDb ID
    local lookup_json
    lookup_json=$(curl -s \
        -H "X-Api-Key: $RADARR_API_KEY" \
        "$RADARR_URL/api/v3/movie/lookup?term=imdb:$imdb_id")

    local movie_id
    movie_id=$(echo "$lookup_json" | jq '.[0].id')

    if [[ -z "$movie_id" || "$movie_id" == "null" ]]; then
        log "Radarr: Could not find movie with IMDb ID $imdb_id"
        return
    fi

    log "Radarr: Found movie ID $movie_id"

    # 3. Ensure tag exists (create if missing)
    local tag_id
    tag_id=$(curl -s \
        -H "X-Api-Key: $RADARR_API_KEY" \
        "$RADARR_URL/api/v3/tag" \
        | jq ".[] | select(.label==\"$RADARR_TAG_NAME\") | .id")

    if [[ -z "$tag_id" ]]; then
        log "Radarr: Creating tag '$RADARR_TAG_NAME'"

        tag_id=$(curl -s \
            -H "X-Api-Key: $RADARR_API_KEY" \
            -H "Content-Type: application/json" \
            -d "{\"label\":\"$RADARR_TAG_NAME\"}" \
            "$RADARR_URL/api/v3/tag" | jq '.id')
    fi

    log "Radarr: Using tag ID $tag_id"

    # 4. Get full movie JSON so we can modify it
    local movie_json
    movie_json=$(curl -s \
        -H "X-Api-Key: $RADARR_API_KEY" \
        "$RADARR_URL/api/v3/movie/$movie_id")

    # 5. Modify JSON: unmonitor + add tag
    local updated_json
    
    if [[ "$RADARR_UNMONITOR" == "YES" ]]; then
        # Unmonitor + tag
        updated_json=$(echo "$movie_json" \
            | jq ".monitored=false | .tags += [$tag_id] | .tags |= unique")
    else
        # Only tag, keep monitored state unchanged
        updated_json=$(echo "$movie_json" \
            | jq ".tags += [$tag_id] | .tags |= unique")
    fi

    # 6. PUT updated movie back to Radarr
    curl -s \
        -X PUT \
        -H "X-Api-Key: $RADARR_API_KEY" \
        -H "Content-Type: application/json" \
        -d "$updated_json" \
        "$RADARR_URL/api/v3/movie/$movie_id" >/dev/null

    if [[ "$RADARR_UNMONITOR" == "YES" ]]; then
        log "Radarr: Movie unmonitored and tagged"
    else
        log "Radarr: Movie tagged"
    fi

    # 7. Trigger a refresh
    curl -s \
        -X POST \
        -H "X-Api-Key: $RADARR_API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"RefreshMovie\",\"movieIds\":[$movie_id]}" \
        "$RADARR_URL/api/v3/command" >/dev/null

    log "Radarr: Refresh triggered"
}

check_ctts_atom() {
    local file="$1"

    # If a list-file is configured and contains this file, treat it as having CTTS
    if [[ -n "$LIST_OF_FILES_WITH_CTOS_ATOM_FILE" && -f "$LIST_OF_FILES_WITH_CTOS_ATOM_FILE" ]]; then
        if grep -Fxq "$file" "$LIST_OF_FILES_WITH_CTOS_ATOM_FILE"; then
            return 0
        fi
    fi

    # Extract only atom lines, ignore everything else
    local atom_output
    atom_output=$(AtomicParsley "$file" -T 1 2>/dev/null | grep -E "Atom [a-zA-Z0-9]{4}")

    # Now check specifically for the CTTS atom
    if echo "$atom_output" | grep -q "Atom ctts"; then
        # append to list if configured and not already present
        if [[ -n "$LIST_OF_FILES_WITH_CTOS_ATOM_FILE" ]]; then
            if ! grep -Fxq "$file" "$LIST_OF_FILES_WITH_CTOS_ATOM_FILE"; then
                printf '%s\n' "$file" >> "$LIST_OF_FILES_WITH_CTOS_ATOM_FILE"
            fi
        fi
        return 0   # CTTS exists
    else
        return 1   # CTTS missing
    fi
}

###############################################
# MAIN LOOP
###############################################

log "===== Starting MP4 → MKV batch run ====="

success_count=0
success_files=()
fail_count=0
failed_files=()
failed_errors=()
skip_count=0
skipped_files=()

trap cleanup_and_exit INT

exec 3< <(find "${SCAN_ROOTS[@]}" -type f -name "*.mp4")

while IFS= read -r inputFile <&3; do

    # Skip files that do not match the regex
    if [[ ! "$(basename "$inputFile")" =~ $MATCH_REGEX ]]; then
        if [[ "$SHOW_SKIPPED" == "YES" ]]; then
            log "Skipping (no regex match): $inputFile"
            skipped_files+=("$inputFile")
        fi
        ((skip_count++))
        continue
    fi

    # Only process files with missing CTTS ATOM if enabled
    if [ "$ONLY_PROCESS_FILES_WITH_MISSING_CTTS_ATOM" = "YES" ]; then
        if check_ctts_atom "$inputFile"; then
            if [[ "$SHOW_SKIPPED" == "YES" ]]; then
                log "Skipping (CTTS ATOM present): $inputFile"
                skipped_files+=("$inputFile")
            fi
            ((skip_count++))
            continue
        else
            echo "Processing (CTTS ATOM missing): $inputFile"
        fi
    fi

    dir=$(dirname "$inputFile")
    base=$(basename "$inputFile" .mp4)
    outputFile="$dir/$base.mkv"

    log "Processing: $inputFile"

    # Convert host path to container path
    containerInput="${inputFile/$HOST_ROOT/$DOCKER_ROOT}"
    containerDir="${dir/$HOST_ROOT/$DOCKER_ROOT}"
    containerOutput="${outputFile/$HOST_ROOT/$DOCKER_ROOT}"

    # Find matching subtitles
    subs=()
    if [[ "$PROCESS_SUBTITLES" == "YES" ]]; then
        safe_base="${base//[/\
    
    \[}"
        safe_base="${safe_base//]/\\]
    
    }"
        mapfile -t subs < <(find "$dir" -maxdepth 1 -type f -name "${safe_base}*.srt")
    fi

    # Build mkvmerge arguments
    args=(-o "$containerOutput" "$containerInput")

    if [[ "$PROCESS_SUBTITLES" == "YES" ]]; then
        for sub in "${subs[@]}"; do
            subFile="${sub/$HOST_ROOT/$DOCKER_ROOT}"
            subBase=$(basename "$sub" .srt)
    
            # Extract language/type
            IFS='.' read -ra parts <<< "$subBase"
            last="${parts[-1]}"
    
            subLang="$last"
            subType=""
    
            if [[ "$subLang" =~ ^(sdh|forced|cc)$ ]]; then
                subType="$subLang"
                # walk backwards to find language
                for ((i=${#parts[@]}-2; i>=0; i--)); do
                    if [[ ! "${parts[$i]}" =~ ^(sdh|forced|cc)$ ]]; then
                        subLang="${parts[$i]}"
                        break
                    fi
                done
            fi
    
            # Validate language
            if [[ ! "$subLang" =~ ^[a-zA-Z]{2,3}(-[a-zA-Z0-9]+)?$ ]]; then
                subLang="und"
            fi
    
            # Determine default-track-flag
            defaultFlag="0:no"
            
            # Only forced subtitles are default
            if [[ "$subType" == "forced" ]]; then
                defaultFlag="0:yes"
            fi
    
            # Build subtitle args
            args+=(
                --language "0:$subLang"
                --default-track-flag "$defaultFlag"
            )
    
            if [[ "$subType" == "sdh" || "$subType" == "cc" ]]; then
                args+=(--hearing-impaired-flag "0:yes" --track-name "0:SDH")
            elif [[ "$subType" == "forced" ]]; then
                args+=(--forced-display-flag "0:yes" --track-name "0:Forced")
            fi
    
            args+=("$subFile")
        done
    fi

    # Run mkvmerge
    log "Running mkvmerge..."
    
    # Run mkvmerge in a subshell so we can capture both output and exit code
    mkv_output=$(
        {
            docker_mkvmerge "${args[@]}"
            echo "EXITCODE:$?"
        } 2>&1 | tee /dev/tty
    )
    
    # Extract exit code
    exit_code=$(echo "$mkv_output" | sed -n 's/^EXITCODE://p')
    
    # Remove EXITCODE line and mkvmerge banner line
    mkv_output=$(echo "$mkv_output" \
        | grep -v '^EXITCODE:' \
        | grep -v '^mkvmerge v')

    # Success or failure handling
    if [[ $exit_code -eq 0 ]]; then
        log "SUCCESS: Created $outputFile"
        ((success_count++))
        success_files+=("$inputFile")
    else
        log "ERROR: mkvmerge failed for $inputFile"
        ((fail_count++))
        failed_files+=("$inputFile")
        failed_errors+=("$mkv_output")
    fi
    
    # ASK / YES / NO deletion logic happens AFTER success/failure
    if [[ $exit_code -eq 0 ]]; then
        case "$DELETE_SOURCE" in
            YES)
                if [[ "$PROCESS_SUBTITLES" == "YES" ]]; then
                    log "Deleting source .mp4 and associated subtitle files..."
                else
                    log "Deleting source .mp4 file..."
                fi
    
                rm -f "$inputFile"
    
                if [[ "$PROCESS_SUBTITLES" == "YES" ]]; then
                    for s in "${subs[@]}"; do rm -f "$s"; done
                fi
                ;;
    
            ASK)
                if [[ "$PROCESS_SUBTITLES" == "YES" ]]; then
                    read -p "Delete the source .mp4 and its subtitle files? (y/N): " ans
                else
                    read -p "Delete the source .mp4 file? (y/N): " ans
                fi
    
                if [[ "$ans" =~ ^[Yy]$ ]]; then
                    if [[ "$PROCESS_SUBTITLES" == "YES" ]]; then
                        log "Deleting source .mp4 and subtitle files..."
                    else
                        log "Deleting source .mp4 file..."
                    fi
    
                    rm -f "$inputFile"
    
                    if [[ "$PROCESS_SUBTITLES" == "YES" ]]; then
                        for s in "${subs[@]}"; do rm -f "$s"; done
                    fi
                else
                    log "Keeping source files."
                fi
                ;;
    
            NO)
                log "Keeping source files."
                ;;
        esac
        if [[ "$UPDATE_RADARR" == "YES" ]];
            then update_radarr_for_movie "$inputFile"
        fi
    fi
    
    log "----------------------------------------"

done

exec 3<&-

stop_container_if_needed

print_summary
