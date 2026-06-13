# shogun_telegram_relay_extract.sh — pure functions for extracting the
# "### 📨 To Lord" block from a captured Shogun pane.
#
# Marker note: spec uses "### 📨 To Lord" but actual headings in CLI output
# render as "### 📰 To Lord" (mailbox emoji, single letter). The match
# is permissive: it accepts any line beginning with "### " that contains
# "To Lord", tolerating both renderings.
#
# Sourced by shogun_telegram_relay.sh and the bats tests.

TRUNCATE_MAX=1500
TRUNCATE_SUFFIX='…[truncated]'

# extract_lord_block <pane_text> -> echoes the last block below the marker
# Block is: from the marker line, to the next `### ` heading OR end of input.
# Uses the LAST "### ... To Lord" marker (later markers supersede earlier ones).
extract_lord_block() {
    local pane="$1"
    local last_marker_idx=-1
    local i=0
    while IFS= read -r line; do
        if [[ "$line" == "### "*"To Lord"* ]]; then
            last_marker_idx=$i
        fi
        i=$((i + 1))
    done <<< "$pane"

    if [[ $last_marker_idx -lt 0 ]]; then
        return 0
    fi

    local out=""
    local started=0
    i=0
    while IFS= read -r line; do
        if [[ $i -le $last_marker_idx ]]; then
            i=$((i + 1))
            continue
        fi
        if [[ $started -eq 0 ]]; then
            started=1
            out="$line"
        elif [[ "$line" == "### "* ]]; then
            break
        else
            out+=$'\n'"$line"
        fi
        i=$((i + 1))
    done <<< "$pane"
    printf '%s' "$out"
}

# truncate_for_telegram <text> -> echoes truncated text with suffix
truncate_for_telegram() {
    local text="$1"
    if [[ ${#text} -gt $TRUNCATE_MAX ]]; then
        printf '%s%s' "${text:0:$TRUNCATE_MAX}" "$TRUNCATE_SUFFIX"
    else
        printf '%s' "$text"
    fi
}

# hash_block <text> -> echoes md5 hash
hash_block() {
    printf '%s' "$1" | md5sum | awk '{print $1}'
}

