#!/usr/bin/env bash
# capture_local.sh — Search and retrieve the latest N screenshots from multiple paths
# Usage: capture_local.sh [-n NUM] [-p PATH]
# If no path is specified, searches screenshot.paths in config/settings.yaml in order of priority

set -euo pipefail

NUM=1
SCREENSHOT_PATH=""

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n) NUM="$2"; shift 2 ;;
        -p) SCREENSHOT_PATH="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [-n NUM] [-p PATH]"
            echo "  -n NUM   Number of images to retrieve (default: 1)"
            echo "  -p PATH  Path to screenshot folder (if omitted, searches all paths in config/settings.yaml)"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Search settings.yaml: Current directory → Repository root
if [[ -f "config/settings.yaml" ]]; then
    SETTINGS_FILE="config/settings.yaml"
elif [[ -n "${MULTI_AGENT_SHOGUN_DIR:-}" && -f "${MULTI_AGENT_SHOGUN_DIR}/config/settings.yaml" ]]; then
    SETTINGS_FILE="${MULTI_AGENT_SHOGUN_DIR}/config/settings.yaml"
else
    # Search from git root
    GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -n "$GIT_ROOT" && -f "$GIT_ROOT/config/settings.yaml" ]]; then
        SETTINGS_FILE="$GIT_ROOT/config/settings.yaml"
    else
        SETTINGS_FILE=""
    fi
fi

# --- Case of Single Path Specified ---
if [[ -n "$SCREENSHOT_PATH" ]]; then
    if [[ ! -d "$SCREENSHOT_PATH" ]]; then
        echo "ERROR: Screenshot folder not found: $SCREENSHOT_PATH" >&2
        exit 1
    fi
    find "$SCREENSHOT_PATH" -maxdepth 1 \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn \
        | head -n "$NUM" \
        | cut -d' ' -f2-
    exit 0
fi

# --- Search Multiple Paths (screenshot.paths in settings.yaml) ---
PATHS=()

if [[ -n "$SETTINGS_FILE" && -f "$SETTINGS_FILE" ]]; then
    # paths: Read the array (simple YAML parser)
    in_paths=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*paths: ]]; then
            in_paths=true
            continue
        fi
        if $in_paths; then
            # Read indented - "..." lines
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\"(.+)\" ]]; then
                PATHS+=("${BASH_REMATCH[1]}")
            elif [[ "$line" =~ ^[[:space:]]*- ]]; then
                # No quotes
                val=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//')
                PATHS+=("$val")
            else
                # End of array
                break
            fi
        fi
    done < "$SETTINGS_FILE"
fi

# Error if paths is empty
if [[ ${#PATHS[@]} -eq 0 ]]; then
    echo "ERROR: screenshot.paths is not configured in config/settings.yaml." >&2
    echo "Example configuration:" >&2
    echo '  screenshot:' >&2
    echo '    paths:' >&2
    echo '      - "/path/to/your/Screenshots/"' >&2
    exit 1
fi

# --- Collect images from all paths and return the latest N images ---
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

found_any=false
for dir in "${PATHS[@]}"; do
    if [[ -d "$dir" ]]; then
        find "$dir" -maxdepth 1 \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) -printf '%T@ %p\n' 2>/dev/null >> "$TMPFILE"
        found_any=true
    fi
done

if ! $found_any; then
    echo "ERROR: No valid screenshot folder found. Searched paths:" >&2
    for dir in "${PATHS[@]}"; do
        echo "  - $dir ($([ -d "$dir" ] && echo 'Exists' || echo 'Absent'))" >&2
    done
    exit 1
fi

# Sort images across all paths by modification time and output the latest N images
sort -rn "$TMPFILE" | head -n "$NUM" | cut -d' ' -f2-
