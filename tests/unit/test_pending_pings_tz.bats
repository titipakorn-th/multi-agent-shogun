#!/usr/bin/env bats
# test_pending_pings_tz.bats — verify telegram_listener.py ping tz parser
# (cmd_045 ping-tz fix). All four forms must parse to the same epoch.
#
# Strategy: a tiny Python helper at tests/unit/_ping_tz_parser.py
# mirrors the production parser. The canonical implementation lives
# in scripts/telegram_listener.py → fire_due_pings.

setup() {
    REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    PARSER="$REPO_ROOT/tests/unit/_ping_tz_parser.py"
}

@test "no suffix: machine local time" {
    t_local=$(python3 -c "import time; print(time.mktime(time.strptime('2026-06-23T03:00:44','%Y-%m-%dT%H:%M:%S')))")
    t_parsed=$(python3 "$PARSER" '2026-06-23T03:00:44')
    [ "${t_local%%.*}" = "${t_parsed%%.*}" ]
}

@test "+00:00 suffix: UTC stamp" {
    t_local=$(python3 -c "import time; print(time.mktime(time.strptime('2026-06-23T03:00:44','%Y-%m-%dT%H:%M:%S')))")
    t_parsed=$(python3 "$PARSER" '2026-06-22T18:00:44+00:00')
    [ "${t_local%%.*}" = "${t_parsed%%.*}" ]
}

@test "+09:00 suffix: JST stamp" {
    t_local=$(python3 -c "import time; print(time.mktime(time.strptime('2026-06-23T03:00:44','%Y-%m-%dT%H:%M:%S')))")
    t_parsed=$(python3 "$PARSER" '2026-06-23T03:00:44+09:00')
    [ "${t_local%%.*}" = "${t_parsed%%.*}" ]
}

@test "-05:00 suffix: EST stamp" {
    t_local=$(python3 -c "import time; print(time.mktime(time.strptime('2026-06-23T03:00:44','%Y-%m-%dT%H:%M:%S')))")
    t_parsed=$(python3 "$PARSER" '2026-06-22T13:00:44-05:00')
    [ "${t_local%%.*}" = "${t_parsed%%.*}" ]
}

@test "Z suffix: equals +00:00" {
    a=$(python3 "$PARSER" '2026-06-22T18:00:44Z')
    b=$(python3 "$PARSER" '2026-06-22T18:00:44+00:00')
    [ "${a%%.*}" = "${b%%.*}" ]
}

@test "malformed: raises (caller suppresses + continues)" {
    run python3 "$PARSER" 'not-a-date'
    [ "$status" -ne 0 ]
}

@test "all four tz forms agree on the same wall instant" {
    local_t=$(python3 -c "import time; print(time.mktime(time.strptime('2026-06-23T03:00:44','%Y-%m-%dT%H:%M:%S')))")
    utc_t=$(python3 "$PARSER" '2026-06-22T18:00:44+00:00')
    jst_t=$(python3 "$PARSER" '2026-06-23T03:00:44+09:00')
    z_t=$(python3 "$PARSER" '2026-06-22T18:00:44Z')
    # Normalize: strip trailing .0 so int vs float compare cleanly.
    local_n="${local_t%%.*}"
    utc_n="${utc_t%%.*}"
    jst_n="${jst_t%%.*}"
    z_n="${z_t%%.*}"
    [ "$local_n" = "$utc_n" ]
    [ "$utc_n" = "$jst_n" ]
    [ "$jst_n" = "$z_n" ]
}