#!/usr/bin/env bash
# shellcheck disable=SC2317 # Menu dispatch invokes test doubles indirectly.

set -o errexit
set -o nounset
set -o pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly TEST_DIR
REPO_DIR=$(cd -- "${TEST_DIR}/.." && pwd -P)
readonly REPO_DIR

# shellcheck disable=SC1090
. "${REPO_DIR}/vwctl"

TESTS=0
FAILURES=0

pass() { TESTS=$((TESTS + 1)); printf 'ok %d - %s\n' "${TESTS}" "$1"; }
fail() { TESTS=$((TESTS + 1)); FAILURES=$((FAILURES + 1)); printf 'not ok %d - %s\n' "${TESTS}" "$1" >&2; }
expect_success() { local description=$1; shift; if "$@"; then pass "${description}"; else fail "${description}"; fi; }
expect_failure() { local description=$1; shift; if "$@"; then fail "${description}"; else pass "${description}"; fi; }

menu_output=$(main <<<"0")
expect_success "no arguments enter the interactive menu" grep -Fq 'Vaultwarden Appliance' <<<"${menu_output}"
process_menu_output=$(printf '0\n' | bash "${REPO_DIR}/vwctl")
expect_success "argument-free vwctl process opens the menu" grep -Fq '0) Exit' <<<"${process_menu_output}"
menu_zero_exits() { interactive_menu <<<"0" >/dev/null; }
expect_success "zero exits the main menu cleanly" menu_zero_exits

invalid_output=$(interactive_menu <<'INPUT'
invalid
0
INPUT
)
expect_success "invalid selection prints a short error" grep -Fq 'Invalid selection.' <<<"${invalid_output}"
main_menu_count=$(grep -Fc 'Vaultwarden Appliance' <<<"${invalid_output}")
expect_success "invalid selection redisplays the menu" test "${main_menu_count}" -ge 2

submenu_output=$(interactive_menu <<'INPUT'
6
0
0
INPUT
)
expect_success "USB submenu opens" grep -Fq 'USB backup media' <<<"${submenu_output}"
main_menu_count=$(grep -Fc 'Vaultwarden Appliance' <<<"${submenu_output}")
expect_success "submenu zero returns to the main menu" test "${main_menu_count}" -ge 2

command_status() { printf 'STATUS_DISPATCHED\n'; }
readonly_output=$(interactive_menu <<'INPUT'
1

0
INPUT
)
expect_success "read-only status selection uses the existing command path" \
    grep -Fq 'STATUS_DISPATCHED' <<<"${readonly_output}"
expect_success "completed menu command shows the continue prompt" \
    grep -Fq 'Press Enter to continue...' <<<"${readonly_output}"

menu_is_root() { return 1; }
command_backup() { printf 'ROOT_BYPASS\n'; }
root_output=$(interactive_menu <<'INPUT' 2>&1
3

0
INPUT
)
expect_success "non-root backup selection prints the existing privilege message" \
    grep -Fq 'This operation requires root privileges.' <<<"${root_output}"
expect_success "non-root backup selection prints the exact sudo command" \
    grep -Fq 'sudo vwctl backup' <<<"${root_output}"
expect_failure "non-root menu selection never invokes the mutating command" \
    grep -Fq 'ROOT_BYPASS' <<<"${root_output}"

command_restore() { printf 'RESTORE_BYPASS\n'; }
restore_root_output=$(interactive_menu <<'INPUT' 2>&1
5

0
INPUT
)
expect_success "non-root restore selection prints the exact sudo command" \
    grep -Fq 'sudo vwctl restore' <<<"${restore_root_output}"
expect_failure "non-root menu selection never invokes restore" \
    grep -Fq 'RESTORE_BYPASS' <<<"${restore_root_output}"

command_version() { printf 'DIRECT_VERSION\n'; }
expect_success "direct CLI dispatch remains unchanged" test "$(main version)" = DIRECT_VERSION
help_output=$(main help)
expect_success "help remains command-line help" grep -Fq 'Usage:' <<<"${help_output}"
expect_failure "help does not open the menu" grep -Fq '0) Exit' <<<"${help_output}"

menu_is_root() { return 0; }
command_usb() { printf 'USB_DISPATCH:%s\n' "$1"; }
usb_setup_output=$(interactive_menu <<'INPUT'
6
2

0
0
INPUT
)
expect_success "USB setup menu dispatches to the existing setup path" \
    grep -Fq 'USB_DISPATCH:setup' <<<"${usb_setup_output}"
# shellcheck disable=SC2016 # The assertion intentionally matches literal shell source.
expect_success "USB destructive confirmation remains in the existing helper" \
    grep -Fq 'confirmation=$(storage_disk_confirmation_text "${identity}")' \
        "${REPO_DIR}/libexec/usb-setup"
expect_success "menu contains no duplicate ERASE USB confirmation" bash -c \
    "! grep -Fq 'Type ERASE USB to continue' '$REPO_DIR/vwctl'"

command_update() { printf 'UPDATE_DISPATCHED\n'; }
update_output=$(interactive_menu <<'INPUT'
8

0
INPUT
)
expect_success "update menu dispatches to the existing update path" \
    grep -Fq 'UPDATE_DISPATCHED' <<<"${update_output}"
expect_success "existing update confirmation remains present" grep -Fq \
    "read -r -p 'Continue? [y/N] ' update_answer </dev/tty" "${REPO_DIR}/vwctl"

expect_success "EOF exits the interactive menu cleanly" bash -c \
    ". '$REPO_DIR/vwctl'; interactive_menu </dev/null >/dev/null"
process_eof_exits() { bash "${REPO_DIR}/vwctl" </dev/null >/dev/null; }
expect_success "argument-free vwctl process exits cleanly on EOF" process_eof_exits

printf '1..%d\n' "${TESTS}"
(( FAILURES == 0 ))
