#!/usr/bin/env bash
# shellcheck disable=SC2317,SC2016 # Indirect test doubles and literal source assertions are intentional.

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
SUDO_TEST_STATUS=0
sudo() {
    local argument

    printf 'SUDO_ARG_COUNT:%d\n' "$#"
    for argument in "$@"; do
        printf 'SUDO_ARG:%s\n' "${argument}"
    done
    return "${SUDO_TEST_STATUS}"
}
sudo_output_has_args() {
    local output=$1
    local expected_count=$2
    local argument

    shift 2
    grep -Fq "SUDO_ARG_COUNT:${expected_count}" <<<"${output}" || return 1
    for argument in "$@"; do
        grep -Fxq "SUDO_ARG:${argument}" <<<"${output}" || return 1
    done
}
readonly_output=$(interactive_menu <<'INPUT'
1

0
INPUT
)
expect_success "read-only status selection uses the existing command path" \
    grep -Fq 'STATUS_DISPATCHED' <<<"${readonly_output}"
expect_success "completed menu command shows the continue prompt" \
    grep -Fq 'Press Enter to continue...' <<<"${readonly_output}"
expect_failure "read-only status does not use sudo" grep -Fq 'SUDO_ARG:' <<<"${readonly_output}"

menu_is_root() { return 1; }
command_backup() { printf 'ROOT_BYPASS\n'; }
root_output=$(interactive_menu <<'INPUT' 2>&1
3

0
INPUT
)
expect_success "non-root backup launches only vwctl backup through sudo" \
    sudo_output_has_args "${root_output}" 2 "${PROGRAM_PATH}" backup
expect_failure "non-root backup never bypasses the privileged CLI path" \
    grep -Fq 'ROOT_BYPASS' <<<"${root_output}"

command_restore() { printf 'RESTORE_BYPASS\n'; }
restore_root_output=$(interactive_menu <<'INPUT' 2>&1
5

0
INPUT
)
expect_success "non-root restore launches only vwctl restore through sudo" \
    sudo_output_has_args "${restore_root_output}" 2 "${PROGRAM_PATH}" restore
expect_failure "non-root restore never bypasses the privileged CLI path" \
    grep -Fq 'RESTORE_BYPASS' <<<"${restore_root_output}"

command_version() { printf 'DIRECT_VERSION\n'; }
expect_success "direct CLI dispatch remains unchanged" test "$(main version)" = DIRECT_VERSION
help_output=$(main help)
expect_success "help remains command-line help" grep -Fq 'Usage:' <<<"${help_output}"
expect_failure "help does not open the menu" grep -Fq '0) Exit' <<<"${help_output}"

command_usb() { printf 'USB_DISPATCH:%s\n' "$1"; }
usb_setup_output=$(interactive_menu <<'INPUT'
6
2

0
0
INPUT
)
expect_success "non-root USB setup launches only vwctl usb setup through sudo" \
    sudo_output_has_args "${usb_setup_output}" 3 "${PROGRAM_PATH}" usb setup
expect_failure "non-root USB setup does not invoke the unprivileged function directly" \
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
expect_success "non-root update launches only vwctl update through sudo" \
    sudo_output_has_args "${update_output}" 2 "${PROGRAM_PATH}" update
expect_failure "non-root update does not invoke the unprivileged function directly" \
    grep -Fq 'UPDATE_DISPATCHED' <<<"${update_output}"
expect_success "existing update confirmation remains present" grep -Fq \
    "read -r -p 'Continue? [y/N] ' update_answer </dev/tty" "${REPO_DIR}/vwctl"

SUDO_TEST_STATUS=130
sudo_failure_output=$(interactive_menu <<'INPUT' 2>&1
3

1

0
INPUT
)
expect_success "cancelled sudo reports that the operation was not performed" \
    grep -Fq 'Privileged operation was not performed (sudo exited with status 130).' \
        <<<"${sudo_failure_output}"
expect_success "cancelled sudo returns to the menu and permits another action" \
    grep -Fq 'STATUS_DISPATCHED' <<<"${sudo_failure_output}"
menu_count=$(grep -Fc 'Vaultwarden Appliance' <<<"${sudo_failure_output}")
expect_success "cancelled sudo keeps the interactive menu active" test "${menu_count}" -ge 3
SUDO_TEST_STATUS=0

menu_is_root() { return 0; }
root_usb_output=$(interactive_menu <<'INPUT'
6
2

0
0
INPUT
)
expect_success "an explicitly root-run menu dispatches without sudo" \
    grep -Fq 'USB_DISPATCH:setup' <<<"${root_usb_output}"
expect_failure "an explicitly root-run menu does not invoke sudo" \
    grep -Fq 'SUDO_ARG:' <<<"${root_usb_output}"

command_backup() { printf 'DIRECT_BACKUP\n'; }
command_restore() { printf 'DIRECT_RESTORE\n'; }
expect_success "direct backup CLI dispatch remains compatible" \
    test "$(main backup)" = DIRECT_BACKUP
expect_success "direct restore CLI dispatch remains compatible" \
    test "$(main restore)" = DIRECT_RESTORE

expect_success "all mutating main-menu actions use the privileged argv dispatcher" bash -c '
    file=$1
    for invocation in \
        "backup" "restore" "update" "start" "stop" "restart" "access"; do
        grep -Fq "menu_run_root_command $invocation" "$file" || exit 1
    done
' _ "${REPO_DIR}/vwctl"
expect_success "all mutating submenu actions use the privileged argv dispatcher" bash -c '
    file=$1
    grep -Fq "menu_run_root_command usb setup" "$file" &&
        grep -Fq "menu_run_root_command signup on" "$file" &&
        grep -Fq "menu_run_root_command signup off" "$file" &&
        grep -Fq "menu_run_root_command cert export" "$file"
' _ "${REPO_DIR}/vwctl"
expect_success "all read-only menu actions remain on unprivileged command paths" bash -c '
    file=$1
    for invocation in \
        "command_status" "command_health" "command_backup_status" \
        "command_update_check" "command_version" "command_usb status" \
        "command_cert_info" "command_logs"; do
        grep -Fq "menu_run_command $invocation" "$file" || exit 1
    done
' _ "${REPO_DIR}/vwctl"
expect_success "privileged child receives selected command argv and cannot recurse into the menu" grep -Fq \
    'sudo "${PROGRAM_PATH}" "$@"' "${REPO_DIR}/vwctl"
expect_failure "menu privilege dispatch never uses sudo sh, eval, or a command string" \
    grep -Eq 'sudo[[:space:]]+(sh|bash)[[:space:]]+-c|(^|[[:space:]])eval[[:space:]]' \
        "${REPO_DIR}/vwctl"
expect_success "backup restore USB and update root checks remain present" bash -c '
    file=$1
    grep -A5 -F "command_backup()" "$file" | grep -Fq "require_root \"backup\"" &&
        grep -A5 -F "command_restore()" "$file" | grep -Fq "require_root \"restore\"" &&
        grep -A8 -F "command_usb_setup()" "$file" | grep -Fq "require_root \"usb setup\"" &&
        grep -A8 -F "command_update()" "$file" | grep -Fq "require_root \"update\""
' _ "${REPO_DIR}/vwctl"
expect_success "restore exact destructive confirmation remains unchanged" grep -Fq \
    'readonly RESTORE_CONFIRMATION="RESTORE VAULTWARDEN"' "${REPO_DIR}/libexec/restore"
expect_failure "vwctl introduces no sudoers or setuid policy changes" \
    grep -Eq '/etc/sudoers|visudo|chmod[[:space:]].*(u\+s|4[0-7]{3})|setuid' \
        "${REPO_DIR}/vwctl"

expect_success "EOF exits the interactive menu cleanly" bash -c \
    ". '$REPO_DIR/vwctl'; interactive_menu </dev/null >/dev/null"
process_eof_exits() { bash "${REPO_DIR}/vwctl" </dev/null >/dev/null; }
expect_success "argument-free vwctl process exits cleanly on EOF" process_eof_exits

printf '1..%d\n' "${TESTS}"
(( FAILURES == 0 ))
