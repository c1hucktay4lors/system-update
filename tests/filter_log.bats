#!/usr/bin/env bats
#====================================================================
# Regression tests for filter_log (src/lib/logging.sh)
#====================================================================
# filter_log has historically been the trickiest part of this script.
# CRLF line endings from the `script` pty, in-line progress-bar redraws,
# and 256-color escape sequences each produced garbled log files at some
# point. These tests pin the current behaviour so a future edit to the
# sed pipeline can't silently reintroduce those bugs.
#
# Run with:  bats tests/
#
# We extract ONLY the filter_log function from logging.sh rather than
# sourcing the whole module, so the tests never trigger logging.sh's
# side effects (the EXIT trap, log-file creation, log rotation).
#====================================================================

setup() {
    local logging="${BATS_TEST_DIRNAME}/../src/lib/logging.sh"
    local fn="${BATS_TEST_TMPDIR}/filter_log.sh"
    sed -n '/^filter_log() {/,/^}/p' "$logging" > "$fn"
    # shellcheck source=/dev/null
    source "$fn"
}

@test "strips basic ANSI color codes" {
    result="$(printf '%b' '\x1b[31mhello\x1b[0m' | filter_log)"
    [ "$result" = "hello" ]
}

@test "strips 256-color SGR sequences" {
    result="$(printf '%b' '\x1b[38;5;82mgreen\x1b[0m' | filter_log)"
    [ "$result" = "green" ]
}

@test "drops trailing CRLF without eating the line" {
    # A pty ends every line with \r\n; the \r must be stripped, but the
    # line content must survive (the bug was treating it as a redraw).
    result="$(printf '%b' 'line\r\n' | filter_log)"
    [ "$result" = "line" ]
}

@test "collapses an in-line CR progress redraw to its final frame" {
    result="$(printf '%b' '10%\r50%\r100%\n' | filter_log)"
    [ "$result" = "100%" ]
}

@test "strips a trailing [bar] NN% progress segment" {
    result="$(printf '%b' 'Downloading [######] 50%\n' | filter_log)"
    [ "$result" = "Downloading" ]
}

@test "preserves a [Y/n] prompt (no trailing percentage)" {
    result="$(printf '%b' 'Proceed? [Y/n]\n' | filter_log)"
    [ "$result" = "Proceed? [Y/n]" ]
}
