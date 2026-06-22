#!/usr/bin/env python3
"""Mirror of the tz parser in scripts/telegram_listener.py → fire_due_pings.

If the production parser drifts, this helper must be updated to match.
Used by test_pending_pings_tz.bats.

Usage: _ping_tz_parser.py '<fire_at_str>'
Exits 0 on success (prints epoch), exits 1 on parse error.
"""
import sys
import time
import calendar


def parse(fire_at_str):
    wall_str = fire_at_str[:19]  # YYYY-MM-DDTHH:MM:SS
    tz_suffix = fire_at_str[19:]
    if tz_suffix in ("Z", "+00:00", "-00:00", ""):
        if tz_suffix in ("Z", "+00:00", "-00:00"):
            return calendar.timegm(time.strptime(wall_str, "%Y-%m-%dT%H:%M:%S"))
        else:
            return time.mktime(time.strptime(wall_str, "%Y-%m-%dT%H:%M:%S"))
    elif tz_suffix.startswith("+") or tz_suffix.startswith("-"):
        sign = 1 if tz_suffix[0] == "+" else -1
        hh, mm = tz_suffix[1:].split(":")
        offset_sec = sign * (int(hh) * 3600 + int(mm) * 60)
        utc_epoch = calendar.timegm(time.strptime(wall_str, "%Y-%m-%dT%H:%M:%S"))
        return utc_epoch - offset_sec
    else:
        return time.mktime(time.strptime(wall_str, "%Y-%m-%dT%H:%M:%S"))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: _ping_tz_parser.py '<fire_at_str>'", file=sys.stderr)
        sys.exit(2)
    try:
        print(parse(sys.argv[1]))
    except Exception as e:
        print(f"parse error: {e}", file=sys.stderr)
        sys.exit(1)