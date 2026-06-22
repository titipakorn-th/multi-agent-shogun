#!/usr/bin/env bash
# auto_prompt_resolve_action.sh — sourced helper for Shogun's auto-resolve branch.
#
# Usage:
#   source scripts/lib/auto_prompt_resolve_action.sh
#   resolution=$(auto_prompt_resolve_action "$msg_file")
#   # or via stdin:
#   cat "$msg_file" | auto_prompt_resolve_action
#
# Behavior:
#   Parses a `ACTION_REQUIRED: <topic> | CHOICES: ...` style message body.
#   Splits the CHOICES section by commas AND newlines, then walks segments
#   looking for "(letter)" markers. A segment starting with "(letter)" opens
#   a new option; segments without a marker fold into the current option as
#   continuation. The first option carrying the literal "(Recommended)"
#   marker is printed on stdout with the marker stripped.
#
# Exit codes:
#   0 = success (resolution text on stdout)
#   2 = no_recommended    (stderr: "no_recommended: <N> choices parsed")
#   3 = parse_error       (stderr: "parse_error: <reason>")
#
# Ponytail: awk + grep -E + sed only. No Python or jq. BSD awk compatible.

auto_prompt_resolve_action() {
    local input_path="${1:-}"

    # Read input — prefer file path argument; fall back to stdin.
    local body
    if [[ -n "$input_path" ]]; then
        if [[ ! -f "$input_path" ]]; then
            echo "parse_error: input file not found: $input_path" >&2
            return 3
        fi
        body=$(cat "$input_path")
    else
        body=$(cat)
    fi

    # Validate: must contain a CHOICES marker.
    if ! echo "$body" | grep -qE "(^|[^A-Za-z])CHOICES:"; then
        echo "parse_error: no CHOICES: marker in input" >&2
        return 3
    fi

    # Slice off everything from the first CHOICES: marker onward. We use awk
    # (not sed) so we capture the CHOICES: line PLUS every subsequent line —
    # sed's `s/...//p` only prints lines where a substitution fired, dropping
    # multi-line option continuations that follow.
    local choices_slice
    choices_slice=$(echo "$body" | awk '
        !found && match($0, /([^A-Za-z]|^)CHOICES:[[:space:]]*/) {
            sub(/.*([^A-Za-z]|^)CHOICES:[[:space:]]*/, "")
            found = 1
        }
        found { print }
    ')

    # ponytail: defensive — if sed produced nothing, the CHOICES: marker had
    # no content after it.
    if [[ -z "$choices_slice" ]]; then
        echo "parse_error: empty CHOICES: payload" >&2
        return 3
    fi

    # Flatten: replace commas and newlines with a delimiter, then split into
    # one segment per line. Each segment is either an option-start
    # ("(letter) text") or a continuation.
    local parsed
    parsed=$(echo "$choices_slice" | tr ',\n' '\n\n' | awk '
        BEGIN { opt = ""; rec_idx = -1; count = 0 }
        {
            # Trim leading whitespace for matching; preserve for accumulation.
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line == "") {
                # Blank segment — flush current option if any.
                if (opt != "") {
                    count++
                    if (rec_idx < 0 && opt ~ /\(Recommended\)/) rec_idx = count
                    opts[count] = opt
                    opt = ""
                }
                next
            }

            # Option start: "(letter) text" — opens a new option.
            if (line ~ /^\([[:space:]]*[A-Za-z][[:space:]]*\)[[:space:]]*/) {
                # Flush previous option first.
                if (opt != "") {
                    count++
                    if (rec_idx < 0 && opt ~ /\(Recommended\)/) rec_idx = count
                    opts[count] = opt
                }
                # Strip "(letter) " prefix; start new option with trimmed body.
                sub(/^\([[:space:]]*[A-Za-z][[:space:]]*\)[[:space:]]*/, "", line)
                opt = line
                next
            }

            # Continuation segment — fold into current option (space-separated).
            if (opt != "") {
                opt = opt " " line
                next
            }
            # No active option yet: ignore stray text before the first option.
        }
        END {
            if (opt != "") {
                count++
                if (rec_idx < 0 && opt ~ /\(Recommended\)/) rec_idx = count
                opts[count] = opt
            }
            print "COUNT=" count
            print "REC_IDX=" rec_idx
            for (i = 1; i <= count; i++) print "OPT" i "=" opts[i]
        }
    ')

    local count
    count=$(echo "$parsed" | sed -nE 's/^COUNT=([0-9]+).*/\1/p')
    local rec_idx
    rec_idx=$(echo "$parsed" | sed -nE 's/^REC_IDX=(-?[0-9]+).*/\1/p')

    # ponytail: defensive — empty count means the parser produced nothing.
    if [[ -z "$count" || "$count" -eq 0 ]]; then
        echo "parse_error: no options detected in CHOICES line" >&2
        return 3
    fi

    # No (Recommended) marker found across all parsed options.
    if [[ -z "$rec_idx" || "$rec_idx" -lt 1 ]]; then
        echo "no_recommended: $count choices parsed" >&2
        return 2
    fi

    # Pull the recommended option text and strip the "(Recommended)" marker.
    local resolution
    resolution=$(echo "$parsed" | sed -nE "s/^OPT${rec_idx}=(.*)$/\1/p")
    resolution=$(echo "$resolution" | sed -E 's/[[:space:]]*\(Recommended\)[[:space:]]*$//')
    # Trim leading/trailing whitespace.
    resolution=$(echo "$resolution" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')

    echo "$resolution"
    return 0
}

# Allow direct invocation: `bash scripts/lib/auto_prompt_resolve_action.sh <file>`
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    auto_prompt_resolve_action "$@"
fi