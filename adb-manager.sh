#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${STATE_DIR:-$SCRIPT_DIR/device_states}"
OPERATION_DIR="${OPERATION_DIR:-$SCRIPT_DIR/operations}"
BACKUP_LIMIT="${BACKUP_LIMIT:-5}"
UNSET_MARKER="__UNSET__"
DELETE_MARKER="__DELETE__"
RC_OK=0
RC_GENERIC_ERROR=1
RC_CANCELLED=10
RC_UNSUPPORTED_PLATFORM=11
RC_ADB_NOT_INSTALLED=20
RC_NO_DEVICE=21
RC_ALIAS_RESOLUTION_FAILED=22
RC_BACKUP_FAILED=30
RC_SNAPSHOT_INVALID=31
RC_LOCK_BUSY=32
RC_OPERATION_FAILED=33
RC_ROLLBACK_FAILED=34
CURRENT_ALIAS=""
CURRENT_DEVICE_SERIAL=""
CURRENT_DEVICE_ID=""
HAS_ACTIVE_PAIRING=0
CURRENT_DEVICE_ENDPOINT=""
ALIAS_MAP_FILE="$STATE_DIR/device_alias_map.tsv"
ALIAS_MAP_LOCK_FILE="$STATE_DIR/device_alias_map.lock"
ALIAS_BACKUP_LIMIT_FILE="$STATE_DIR/alias_backup_limit.tsv"
ACTIVE_LOCK_METHOD=""
ACTIVE_LOCK_PATH=""
ACTIVE_LOCK_FD=""
TUI_ENABLED=0
TUI_ALT_SCREEN_ACTIVE=0
UI_THEME_ENABLED=0
UI_PAD_TOP=1
UI_PAD_LEFT="   "
UI_COLOR_RESET=""
UI_COLOR_BORDER=""
UI_COLOR_TITLE=""
UI_COLOR_META=""
UI_COLOR_LABEL=""
UI_COLOR_VALUE=""
UI_COLOR_OPTION_INDEX=""
UI_COLOR_OPTION_TEXT=""
UI_COLOR_PROMPT=""

mkdir -p "$STATE_DIR" "$OPERATION_DIR"

ui_printf() {
    builtin printf "$@"
}


trim_output() {
    ui_printf '%s' "$1" | tr -d '\r' | sed 's/[[:space:]]*$//'
}

is_yes_response() {
    local raw="$1"
    local normalized

    normalized=$(trim_output "$raw")
    normalized=$(ui_printf '%s' "$normalized" | tr '[:upper:]' '[:lower:]')
    [ "$normalized" = "y" ] || [ "$normalized" = "yes" ]
}

is_valid_identity_value() {
    local v

    v=$(ui_printf '%s' "$1" | tr '[:upper:]' '[:lower:]')

    [ -n "$v" ] && [ "$v" != "unknown" ] && [ "$v" != "null" ] && [ "$v" != "n/a" ] && [ "$v" != "none" ]
}

get_selected_device_prop() {
    local key="$1"
    local output

    output=$(adb_cmd shell getprop "$key" 2>/dev/null)
    trim_output "$output"
}

prompt_number_in_range() {
    local prompt="$1"
    local min="$2"
    local max="$3"
    local value
    local typed=""
    local key
    local esc_1
    local esc_2
    local display_prompt
    local cleaned_value

    display_prompt="${UI_PAD_LEFT}${UI_COLOR_PROMPT}${prompt}${UI_COLOR_RESET}"

    if [ -t 0 ]; then
        ui_printf '%s' "$display_prompt" >&2
        while true; do
            IFS= read -rsn1 key
            case "$key" in
                ''|$'\n'|$'\r')
                    ui_printf '\n' >&2
                    cleaned_value=$(trim_output "$typed")
                    case "$cleaned_value" in
                        '')
                            typed=""
                            ui_printf '%s' "$display_prompt" >&2
                            continue
                            ;;
                        *[!0-9]*)
                            typed=""
                            ui_printf '%s' "$display_prompt" >&2
                            continue
                            ;;
                    esac

                    if [ "$cleaned_value" -lt "$min" ] || [ "$cleaned_value" -gt "$max" ]; then
                        ui_msg_err "Invalid selection."
                        typed=""
                        ui_printf '%s' "$display_prompt" >&2
                        continue
                    fi

                    ui_printf '%s' "$cleaned_value"
                    return 0
                    ;;
                $'\x1b')
                    IFS= read -rsn1 -t 0.1 esc_1 || {
                        ui_printf '\n' >&2
                        return "$RC_CANCELLED"
                    }
                    if [ "$esc_1" = "[" ]; then
                        IFS= read -rsn1 -t 0.1 esc_2 || {
                            ui_printf '\n' >&2
                            return "$RC_CANCELLED"
                        }
                    fi
                    continue
                    ;;
                $'\177'|$'\b')
                    if [ -n "$typed" ]; then
                        typed="${typed%?}"
                        ui_printf '\r\033[2K%s%s%s%s' "$display_prompt" "$UI_COLOR_VALUE" "$typed" "$UI_COLOR_RESET" >&2
                    fi
                    ;;
                [0-9])
                    typed+="$key"
                    ui_printf '\r\033[2K%s%s%s%s' "$display_prompt" "$UI_COLOR_VALUE" "$typed" "$UI_COLOR_RESET" >&2
                    ;;
                *)
                    ;;
            esac
        done
    fi

    while true; do
        read -r -p "$display_prompt" value
        cleaned_value=$(trim_output "$value")

        case "$cleaned_value" in
            ''|*[!0-9]*)
                ui_msg_err "Invalid selection."
                continue
                ;;
        esac

        if [ "$cleaned_value" -lt "$min" ] || [ "$cleaned_value" -gt "$max" ]; then
            ui_msg_err "Invalid selection."
            continue
        fi

        ui_printf '%s' "$cleaned_value"
        return 0
    done
}

ui_divider() {
    ui_printf '%s%s----------------------------------------%s\n' "$UI_PAD_LEFT" "$UI_COLOR_BORDER" "$UI_COLOR_RESET"
}

init_tui_mode() {
    local tui_env="${ADB_MANAGER_TUI:-1}"

    if [ "$tui_env" = "0" ] || [ "$tui_env" = "false" ] || [ "$tui_env" = "off" ]; then
        TUI_ENABLED=0
        return 0
    fi

    if [ -t 0 ] && [ -t 1 ]; then
        TUI_ENABLED=1
    else
        TUI_ENABLED=0
    fi
}

init_ui_theme() {
    UI_THEME_ENABLED=0
    UI_PAD_TOP=1
    UI_PAD_LEFT="   "

    UI_COLOR_RESET=""
    UI_COLOR_BORDER=""
    UI_COLOR_TITLE=""
    UI_COLOR_META=""
    UI_COLOR_LABEL=""
    UI_COLOR_VALUE=""
    UI_COLOR_OPTION_INDEX=""
    UI_COLOR_OPTION_TEXT=""
    UI_COLOR_PROMPT=""

    if [ -t 1 ] && [ "${TERM:-}" != "dumb" ]; then
        UI_THEME_ENABLED=1
        UI_COLOR_RESET=$'\033[0m'
        UI_COLOR_BORDER=$'\033[38;5;45m'
        UI_COLOR_TITLE=$'\033[1;38;5;51m'
        UI_COLOR_META=$'\033[38;5;110m'
        UI_COLOR_LABEL=$'\033[1;38;5;117m'
        UI_COLOR_VALUE=$'\033[38;5;255m'
        UI_COLOR_OPTION_INDEX=$'\033[1;38;5;87m'
        UI_COLOR_OPTION_TEXT=$'\033[38;5;252m'
        UI_COLOR_PROMPT=$'\033[1;38;5;159m'
    fi
}

enter_tui_alt_screen() {
    [ "$TUI_ENABLED" -eq 1 ] || return 0
    [ "$TUI_ALT_SCREEN_ACTIVE" -eq 0 ] || return 0

    ui_printf '\033[?1049h\033[2J\033[H\033[?25l'
    TUI_ALT_SCREEN_ACTIVE=1
}

leave_tui_alt_screen() {
    [ "$TUI_ALT_SCREEN_ACTIVE" -eq 1 ] || return 0

    ui_printf '\033[?25h\033[?1049l'
    TUI_ALT_SCREEN_ACTIVE=0
}

refresh_tui_screen() {
    [ "$TUI_ENABLED" -eq 1 ] || return 0
    ui_printf '\033[2J\033[H'
}

ui_header() {
    local title="$1"
    local pad_i

    refresh_tui_screen
    for ((pad_i=0; pad_i<UI_PAD_TOP; pad_i++)); do
        ui_emitln ""
    done
    ui_divider
    ui_printf '%s%s%s%s\n' "$UI_PAD_LEFT" "$UI_COLOR_TITLE" "$title" "$UI_COLOR_RESET"
    ui_printf '%s%sDeveloped by obsidzen%s\n' "$UI_PAD_LEFT" "$UI_COLOR_META" "$UI_COLOR_RESET"
    ui_divider
}

ui_status_line() {
    local label="$1"
    local value="$2"
    ui_printf '%s%s%-12s%s %s%s%s\n' "$UI_PAD_LEFT" "$UI_COLOR_LABEL" "$label" "$UI_COLOR_RESET" "$UI_COLOR_VALUE" "$value" "$UI_COLOR_RESET"
}

ui_option() {
    local index="$1"
    local label="$2"
    ui_printf '%s%s%s)%s %s%s%s\n' "$UI_PAD_LEFT" "$UI_COLOR_OPTION_INDEX" "$index" "$UI_COLOR_RESET" "$UI_COLOR_OPTION_TEXT" "$label" "$UI_COLOR_RESET"
}

ui_indexed_row() {
    local index="$1"
    local width="$2"
    local label="$3"
    ui_printf '%s%s%*s)%s %s%s%s\n' "$UI_PAD_LEFT" "$UI_COLOR_OPTION_INDEX" "$width" "$index" "$UI_COLOR_RESET" "$UI_COLOR_OPTION_TEXT" "$label" "$UI_COLOR_RESET"
}

ui_header_err() {
    ui_header "$1" >&2
}

ui_status_line_err() {
    ui_status_line "$1" "$2" >&2
}

ui_option_err() {
    ui_option "$1" "$2" >&2
}

ui_indexed_row_err() {
    ui_indexed_row "$1" "$2" "$3" >&2
}

ui_meta_line_err() {
    local label="$1"
    local value="$2"
    ui_printf '%s   %s%s%s %s%s%s\n' "$UI_PAD_LEFT" "$UI_COLOR_LABEL" "$label" "$UI_COLOR_RESET" "$UI_COLOR_VALUE" "$value" "$UI_COLOR_RESET" >&2
}

ui_pause() {
    local message="${1:-Press Enter to continue...}"
    local _

    [ -t 0 ] && [ -t 1 ] || return 0
    ui_printf '%s%s%s%s' "$UI_PAD_LEFT" "$UI_COLOR_META" "$message" "$UI_COLOR_RESET" >&2
    IFS= read -r _
}

ui_emit() {
    ui_printf '%s' "$1"
}

ui_emitln() {
    ui_printf '%s\n' "$1"
}

ui_emitln_err() {
    ui_printf '%s\n' "$1" >&2
}

ui_msg() {
    ui_printf '%s%s\n' "$UI_PAD_LEFT" "$1"
}

ui_msg_err() {
    ui_printf '%s%s\n' "$UI_PAD_LEFT" "$1" >&2
}

ui_print() {
    ui_msg "$1"
}

ui_prompt_input() {
    local prompt="$1"
    local var_name="$2"
    local value
    local display_prompt

    display_prompt="${UI_PAD_LEFT}${UI_COLOR_PROMPT}${prompt}${UI_COLOR_RESET}"
    read -r -p "$display_prompt" value
    ui_printf -v "$var_name" '%s' "$value"
}
list_aliases_for_management() {
    local map_aliases
    local state_aliases
    local limit_aliases

    ensure_alias_map_file
    ensure_alias_backup_limit_file

    map_aliases=$(awk -F '\t' 'NF >= 2 && $2 != "" { print $2 }' "$ALIAS_MAP_FILE" 2>/dev/null || true)
    state_aliases=$(find "$STATE_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | grep -v '^_archive$' | grep -v '^_checkpoints$' | grep -v '^_txn$' || true)
    limit_aliases=$(awk -F '\t' 'NF >= 2 && $1 != "" { print $1 }' "$ALIAS_BACKUP_LIMIT_FILE" 2>/dev/null || true)

    ui_printf '%s\n%s\n%s\n' "$map_aliases" "$state_aliases" "$limit_aliases" | sed '/^$/d' | sort -u
}

select_alias_for_management() {
    local prompt="${1:-Select alias: }"
    local exclude_alias="${2:-}"
    local selection
    local prompt_rc
    local index
    local alias
    local max_index
    local index_width
    local -a aliases

    mapfile -t aliases < <(list_aliases_for_management)
    [ "${#aliases[@]}" -gt 0 ] || {
        ui_msg_err "No aliases available."
        return "$RC_GENERIC_ERROR"
    }

    ui_header_err "Alias List"
    max_index=${#aliases[@]}
    index_width=${#max_index}
    for index in "${!aliases[@]}"; do
        alias="${aliases[$index]}"
        if [ -n "$exclude_alias" ] && [ "$alias" = "$exclude_alias" ]; then
            ui_indexed_row_err "$((index + 1))" "$index_width" "$alias [excluded]"
        else
            ui_indexed_row_err "$((index + 1))" "$index_width" "$alias"
        fi
    done
    ui_option_err "0" "Cancel"

    while true; do
        selection=$(prompt_number_in_range "$prompt" 0 "${#aliases[@]}")
        prompt_rc=$?
        [ "$prompt_rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"
        [ "$selection" -eq 0 ] && return "$RC_CANCELLED"
        alias="${aliases[$((selection - 1))]}"
        if [ -n "$exclude_alias" ] && [ "$alias" = "$exclude_alias" ]; then
            ui_msg_err "This alias is excluded."
            continue
        fi
        ui_printf '%s' "$alias"
        return "$RC_OK"
    done
}

list_checkpoint_dirs_sorted() {
    local checkpoint_root="$STATE_DIR/_checkpoints"
    local path
    local base
    local mtime

    [ -d "$checkpoint_root" ] || return "$RC_GENERIC_ERROR"

    shopt -s nullglob
    for path in "$checkpoint_root"/*; do
        [ -d "$path" ] || continue
        base=$(basename "$path")
        mtime=$(stat -c %Y "$path" 2>/dev/null || ui_printf '0')
        ui_printf '%020d|%s\n' "$mtime" "$base"
    done | sort -r | cut -d'|' -f2-
    shopt -u nullglob
}

select_checkpoint_dir() {
    local checkpoint_root="$STATE_DIR/_checkpoints"
    local selection
    local prompt_rc
    local index
    local max_index
    local index_width
    local name
    local mtime
    local -a checkpoints

    mapfile -t checkpoints < <(list_checkpoint_dirs_sorted)
    [ "${#checkpoints[@]}" -gt 0 ] || {
        ui_msg_err "No checkpoints found."
        return "$RC_GENERIC_ERROR"
    }

    ui_header_err "Select Checkpoint"
    max_index=${#checkpoints[@]}
    index_width=${#max_index}
    for index in "${!checkpoints[@]}"; do
        name="${checkpoints[$index]}"
        mtime=$(date -d "@$(stat -c %Y "$checkpoint_root/$name" 2>/dev/null || ui_printf '0')" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || ui_printf 'unknown')
        ui_indexed_row_err "$((index + 1))" "$index_width" "$name"
        ui_meta_line_err "modified:" "$mtime"
    done
    ui_option_err "0" "Cancel"

    selection=$(prompt_number_in_range "Select checkpoint: " 0 "${#checkpoints[@]}")
    prompt_rc=$?
    [ "$prompt_rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"
    [ "$selection" -eq 0 ] && return "$RC_CANCELLED"
    ui_printf '%s/%s' "$checkpoint_root" "${checkpoints[$((selection - 1))]}"
}
select_snapshot_file_common() {
    local alias="$1"
    local mode="${2:-standard}"
    local list_mode="${3:-with_list}"
    local dir="$STATE_DIR/$alias/backups"
    local filter_choice
    local keyword
    local recent_n
    local selection
    local prompt_rc
    local index
    local index_width
    local max_index
    local snapshot_path
    local created_at
    local input
    local max_recent
    local filter_title
    local select_title
    local -a snapshots
    local -a filtered_snapshots

    [ -d "$dir" ] || {
        ui_msg_err "No backups found for alias: $alias"
        return "$RC_GENERIC_ERROR"
    }

    mapfile -t snapshots < <(list_snapshot_files_sorted "$alias")
    [ "${#snapshots[@]}" -gt 0 ] || {
        ui_msg_err "No backups found for alias: $alias"
        return "$RC_GENERIC_ERROR"
    }

    filtered_snapshots=("${snapshots[@]}")

    if [ "$mode" = "view" ]; then
        filter_title="Select Snapshot Filter (View)"
        select_title="Select Snapshot (View)"
    else
        filter_title="Select Snapshot Filter"
        select_title="Select Snapshot"
    fi

    if [ "$mode" = "view" ] || [ "$list_mode" != "skip_list" ]; then
        while true; do
            ui_header_err "$filter_title"
            ui_status_line_err "Alias:" "$alias"

            if [ "$mode" = "view" ]; then
                ui_option_err "1" "Recent 10 (Recommended)"
                ui_option_err "2" "All"
                ui_option_err "3" "Keyword"
                ui_option_err "4" "Recent N"
                ui_option_err "5" "Cancel"
            else
                ui_option_err "1" "All"
                ui_option_err "2" "Keyword"
                ui_option_err "3" "Recent N"
                ui_option_err "4" "Cancel"
            fi

            ui_prompt_input "Select filter: " input
            input=$(trim_output "$input")
            filter_choice="${input:-1}"

            case "$mode:$filter_choice" in
                view:1)
                    max_recent=10
                    [ "${#snapshots[@]}" -lt "$max_recent" ] && max_recent="${#snapshots[@]}"
                    filtered_snapshots=("${snapshots[@]:0:$max_recent}")
                    break
                    ;;
                view:2|standard:1)
                    filtered_snapshots=("${snapshots[@]}")
                    break
                    ;;
                view:3|standard:2)
                    ui_prompt_input "Keyword: " keyword
                    keyword=$(trim_output "$keyword")
                    [ -n "$keyword" ] || {
                        ui_msg_err "Keyword is required."
                        continue
                    }
                    mapfile -t filtered_snapshots < <(ui_printf '%s\n' "${snapshots[@]}" | grep -i -- "$keyword" || true)
                    [ "${#filtered_snapshots[@]}" -gt 0 ] && break
                    ui_msg_err "No snapshots matched keyword: $keyword"
                    ;;
                view:4|standard:3)
                    recent_n=$(prompt_number_in_range "Recent count: " 1 "${#snapshots[@]}")
                    prompt_rc=$?
                    [ "$prompt_rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"
                    filtered_snapshots=("${snapshots[@]:0:$recent_n}")
                    break
                    ;;
                view:5|standard:4)
                    return "$RC_CANCELLED"
                    ;;
                *)
                    ui_msg_err "Invalid selection."
                    ;;
            esac
        done
    fi

    ui_header_err "$select_title"
    ui_status_line_err "Alias:" "$alias"
    max_index=${#filtered_snapshots[@]}
    index_width=${#max_index}
    for index in "${!filtered_snapshots[@]}"; do
        snapshot_path="$dir/${filtered_snapshots[$index]}"
        created_at=$(snapshot_metadata_value "$snapshot_path" "created_at")
        ui_indexed_row_err "$((index + 1))" "$index_width" "${filtered_snapshots[$index]}"
        if [ -n "$created_at" ]; then
            ui_meta_line_err "created:" "$created_at"
        fi
    done
    ui_option_err "0" "Cancel"

    selection=$(prompt_number_in_range "Select snapshot: " 0 "${#filtered_snapshots[@]}")
    prompt_rc=$?
    [ "$prompt_rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"
    [ "$selection" -eq 0 ] && return "$RC_CANCELLED"
    ui_printf '%s' "$dir/${filtered_snapshots[$((selection - 1))]}"
}

select_snapshot_file() {
    local alias="$1"
    local list_mode="${2:-with_list}"

    select_snapshot_file_common "$alias" "standard" "$list_mode"
}

select_snapshot_file_for_view() {
    local alias="$1"

    select_snapshot_file_common "$alias" "view" "with_list"
}

list_snapshot_aliases() {
    local backup_dir
    local alias
    local first_entry

    [ -d "$STATE_DIR" ] || return "$RC_GENERIC_ERROR"

    while IFS= read -r backup_dir; do
        [ -n "$backup_dir" ] || continue
        first_entry=$(find "$backup_dir" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)
        [ -n "$first_entry" ] || continue
        alias=$(basename "$(dirname "$backup_dir")")
        [ -n "$alias" ] && ui_printf '%s\n' "$alias"
    done < <(find "$STATE_DIR" -mindepth 2 -maxdepth 2 -type d -name backups 2>/dev/null | sort)
}

select_snapshot_alias_for_view() {
    local selection
    local prompt_rc
    local index
    local alias
    local snapshot_count
    local label
    local max_index
    local index_width
    local -a aliases

    mapfile -t aliases < <(list_snapshot_aliases)
    [ "${#aliases[@]}" -gt 0 ] || {
        ui_msg_err "No snapshot aliases found."
        return "$RC_GENERIC_ERROR"
    }

    if [ "${#aliases[@]}" -eq 1 ]; then
        ui_printf '%s' "${aliases[0]}"
        return "$RC_OK"
    fi

    ui_header_err "Select Snapshot Alias"
    max_index=${#aliases[@]}
    index_width=${#max_index}
    for index in "${!aliases[@]}"; do
        alias="${aliases[$index]}"
        snapshot_count=$(count_snapshot_files_for_alias "$alias")
        if [ "$alias" = "$CURRENT_ALIAS" ]; then
            label="$alias [current] ($snapshot_count snapshots)"
        else
            label="$alias ($snapshot_count snapshots)"
        fi
        ui_indexed_row_err "$((index + 1))" "$index_width" "$label"
    done
    ui_option_err "0" "Cancel"

    selection=$(prompt_number_in_range "Select alias: " 0 "${#aliases[@]}")
    prompt_rc=$?
    [ "$prompt_rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"
    [ "$selection" -eq 0 ] && return "$RC_CANCELLED"
    ui_printf '%s' "${aliases[$((selection - 1))]}"
}
show_operation_list() {
    local title="${1:-Operation List}"
    local index
    local index_width
    local max_index
    local operation_path
    local entry_count
    local -a operation_files

    mapfile -t operation_files < <(list_operation_files)
    [ "${#operation_files[@]}" -gt 0 ] || {
        ui_print "No operation files found in: $OPERATION_DIR"
        return "$RC_GENERIC_ERROR"
    }
    max_index=${#operation_files[@]}
    index_width=${#max_index}

    ui_header "$title"
    for index in "${!operation_files[@]}"; do
        operation_path="$OPERATION_DIR/${operation_files[$index]}"
        entry_count=$(grep -Ecv '^[[:space:]]*(#|$)' "$operation_path" 2>/dev/null || ui_printf '0')
        ui_indexed_row "$((index + 1))" "$index_width" "${operation_files[$index]}"
        ui_printf '%s   %sentries:%s %s%s%s\n' "$UI_PAD_LEFT" "$UI_COLOR_LABEL" "$UI_COLOR_RESET" "$UI_COLOR_VALUE" "$entry_count" "$UI_COLOR_RESET"
    done
    return "$RC_OK"
}

select_operation_file() {
    local selection
    local prompt_rc
    local -a operation_files

    mapfile -t operation_files < <(list_operation_files)
    [ "${#operation_files[@]}" -gt 0 ] || {
        ui_print "No operation files found in: $OPERATION_DIR"
        return "$RC_GENERIC_ERROR"
    }

    show_operation_list "Select Operation" >&2 || return "$RC_GENERIC_ERROR"

    ui_option_err "0" "Cancel"

    selection=$(prompt_number_in_range "Select operation: " 0 "${#operation_files[@]}")
    prompt_rc=$?
    [ "$prompt_rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"
    [ "$selection" -eq 0 ] && return "$RC_CANCELLED"
    ui_printf '%s/%s' "$OPERATION_DIR" "${operation_files[$((selection - 1))]}"
}

run_cmd() {
    if [ "$EUID" -ne 0 ]; then
        sudo "$@"
    else
        "$@"
    fi
}

check_kernel() {
    [ "$(uname -s)" != "Linux" ] && ui_print "Linux only." && exit "$RC_UNSUPPORTED_PLATFORM"
}

detect_distro() {
    [ ! -f /etc/os-release ] && ui_print "Unsupported distro." && exit "$RC_UNSUPPORTED_PLATFORM"
    . /etc/os-release
    ui_emitln "$ID"
}

install_adb() {
    local distro

    distro=$(detect_distro)

    case "$distro" in
        ubuntu|debian)
            run_cmd apt update
            run_cmd apt install -y android-tools-adb
            ;;
        arch|cachyos)
            run_cmd pacman -Sy --noconfirm android-tools
            ;;
        *)
            ui_print "Unsupported distro."
            return "$RC_GENERIC_ERROR"
            ;;
    esac
}

ensure_adb_installed() {
    command -v adb >/dev/null 2>&1 || install_adb
    command -v adb >/dev/null 2>&1
}

list_devices() {
    adb devices | sed 1d | awk '$2 == "device" { print $1 }'
}

adb_cmd() {
    if [ -n "$CURRENT_DEVICE_SERIAL" ]; then
        adb -s "$CURRENT_DEVICE_SERIAL" "$@"
    else
        adb "$@"
    fi
}

ensure_alias_map_file() {
    [ -f "$ALIAS_MAP_FILE" ] || : > "$ALIAS_MAP_FILE"
}

ensure_alias_backup_limit_file() {
    [ -f "$ALIAS_BACKUP_LIMIT_FILE" ] || : > "$ALIAS_BACKUP_LIMIT_FILE"
}

sanitize_positive_int_or_empty() {
    local raw="$1"

    raw=$(trim_output "$raw")
    [ -n "$raw" ] || return "$RC_GENERIC_ERROR"
    ui_printf '%s' "$raw" | grep -Eq '^[0-9]+$' || return "$RC_GENERIC_ERROR"
    [ "$raw" -gt 0 ] || return "$RC_GENERIC_ERROR"
    ui_printf '%s' "$raw"
}

get_backup_limit_for_alias() {
    local alias="$1"
    local default_limit
    local alias_limit

    default_limit=$(sanitize_positive_int_or_empty "$BACKUP_LIMIT" 2>/dev/null || true)
    [ -n "$default_limit" ] || default_limit=5

    [ -n "$alias" ] || {
        ui_printf '%s' "$default_limit"
        return 0
    }

    ensure_alias_backup_limit_file
    alias_limit=$(awk -F '\t' -v a="$alias" '$1 == a { print $2; exit }' "$ALIAS_BACKUP_LIMIT_FILE")
    alias_limit=$(sanitize_positive_int_or_empty "$alias_limit" 2>/dev/null || true)
    if [ -n "$alias_limit" ]; then
        ui_printf '%s' "$alias_limit"
    else
        ui_printf '%s' "$default_limit"
    fi
}

get_configured_backup_limit_for_alias() {
    local alias="$1"
    local alias_limit

    [ -n "$alias" ] || return "$RC_GENERIC_ERROR"
    ensure_alias_backup_limit_file
    alias_limit=$(awk -F '\t' -v a="$alias" '$1 == a { print $2; exit }' "$ALIAS_BACKUP_LIMIT_FILE")
    alias_limit=$(sanitize_positive_int_or_empty "$alias_limit" 2>/dev/null || true)
    [ -n "$alias_limit" ] || return "$RC_GENERIC_ERROR"
    ui_printf '%s' "$alias_limit"
}

set_backup_limit_for_alias() {
    local alias="$1"
    local limit="$2"
    local normalized_limit
    local tmp_file
    local lock_fd_opened=0

    [ -n "$alias" ] || return "$RC_GENERIC_ERROR"
    ensure_alias_backup_limit_file
    tmp_file="$ALIAS_BACKUP_LIMIT_FILE.tmp.$$"

    if [ -n "$limit" ]; then
        normalized_limit=$(sanitize_positive_int_or_empty "$limit" 2>/dev/null || true)
        [ -n "$normalized_limit" ] || return "$RC_GENERIC_ERROR"
    else
        normalized_limit=""
    fi

    if command -v flock >/dev/null 2>&1; then
        exec 9>"$ALIAS_MAP_LOCK_FILE"
        flock -x 9
        lock_fd_opened=1
    fi

    if ! awk -F '\t' -v a="$alias" '$1 != a { print $0 }' "$ALIAS_BACKUP_LIMIT_FILE" > "$tmp_file"; then
        rm -f "$tmp_file"
        [ "$lock_fd_opened" -eq 1 ] && { flock -u 9; exec 9>&-; }
        return "$RC_GENERIC_ERROR"
    fi

    if [ -n "$normalized_limit" ]; then
        if ! ui_printf '%s\t%s\n' "$alias" "$normalized_limit" >> "$tmp_file"; then
            rm -f "$tmp_file"
            [ "$lock_fd_opened" -eq 1 ] && { flock -u 9; exec 9>&-; }
            return "$RC_GENERIC_ERROR"
        fi
    fi

    if ! mv "$tmp_file" "$ALIAS_BACKUP_LIMIT_FILE"; then
        rm -f "$tmp_file"
        [ "$lock_fd_opened" -eq 1 ] && { flock -u 9; exec 9>&-; }
        return "$RC_GENERIC_ERROR"
    fi

    [ "$lock_fd_opened" -eq 1 ] && { flock -u 9; exec 9>&-; }
    return 0
}

build_fingerprint_identity() {
    local brand
    local manufacturer
    local model
    local device
    local fingerprint
    local combined
    local hash

    brand=$(trim_output "$(get_selected_device_prop "ro.product.brand")")
    manufacturer=$(trim_output "$(get_selected_device_prop "ro.product.manufacturer")")
    model=$(trim_output "$(get_selected_device_prop "ro.product.model")")
    device=$(trim_output "$(get_selected_device_prop "ro.product.device")")
    fingerprint=$(trim_output "$(get_selected_device_prop "ro.build.fingerprint")")

    is_valid_identity_value "$brand" || brand=""
    is_valid_identity_value "$manufacturer" || manufacturer=""
    is_valid_identity_value "$model" || model=""
    is_valid_identity_value "$device" || device=""
    is_valid_identity_value "$fingerprint" || fingerprint=""

    combined="$brand|$manufacturer|$model|$device|$fingerprint"
    [ -n "${combined//|/}" ] || return "$RC_GENERIC_ERROR"

    if command -v sha256sum >/dev/null 2>&1; then
        hash=$(ui_printf '%s' "$combined" | sha256sum | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        hash=$(ui_printf '%s' "$combined" | shasum -a 256 | awk '{print $1}')
    else
        hash=$(ui_printf '%s' "$combined" | cksum | awk '{print $1}')
    fi

    ui_printf 'fingerprint:%s' "$hash"
}

lookup_alias_by_device_id() {
    local device_id="$1"

    ensure_alias_map_file
    awk -F '\t' -v did="$device_id" '$1 == did { print $2; exit }' "$ALIAS_MAP_FILE"
}

lookup_serial_by_device_id() {
    local device_id="$1"

    ensure_alias_map_file
    awk -F '\t' -v did="$device_id" '$1 == did { print $4; exit }' "$ALIAS_MAP_FILE"
}

lookup_device_id_by_alias() {
    local alias="$1"

    ensure_alias_map_file
    awk -F '\t' -v a="$alias" '$2 == a { print $1; exit }' "$ALIAS_MAP_FILE"
}

ensure_unique_path_with_index_suffix() {
    local dir="$1"
    local name="$2"
    local candidate="$dir/$name"
    local index=1

    while [ -e "$candidate" ]; do
        candidate="$dir/${name}.${index}"
        index=$((index + 1))
    done

    ui_printf '%s' "$candidate"
}

rename_alias_in_map() {
    local old_alias="$1"
    local new_alias="$2"
    local tmp_file
    local lock_fd_opened=0

    ensure_alias_map_file
    tmp_file="$ALIAS_MAP_FILE.tmp.$$"

    if command -v flock >/dev/null 2>&1; then
        exec 9>"$ALIAS_MAP_LOCK_FILE"
        flock -x 9
        lock_fd_opened=1
    fi

    if ! awk -F '\t' -v old="$old_alias" -v new="$new_alias" 'BEGIN { OFS="\t" } { if ($2 == old) { $2 = new } print }' "$ALIAS_MAP_FILE" > "$tmp_file"; then
        rm -f "$tmp_file"
        [ "$lock_fd_opened" -eq 1 ] && { flock -u 9; exec 9>&-; }
        return "$RC_GENERIC_ERROR"
    fi

    if ! mv "$tmp_file" "$ALIAS_MAP_FILE"; then
        rm -f "$tmp_file"
        [ "$lock_fd_opened" -eq 1 ] && { flock -u 9; exec 9>&-; }
        return "$RC_GENERIC_ERROR"
    fi

    [ "$lock_fd_opened" -eq 1 ] && { flock -u 9; exec 9>&-; }
    return 0
}

remove_alias_from_map() {
    local alias="$1"
    local tmp_file
    local lock_fd_opened=0

    ensure_alias_map_file
    tmp_file="$ALIAS_MAP_FILE.tmp.$$"

    if command -v flock >/dev/null 2>&1; then
        exec 9>"$ALIAS_MAP_LOCK_FILE"
        flock -x 9
        lock_fd_opened=1
    fi

    if ! awk -F '\t' -v a="$alias" '$2 != a { print $0 }' "$ALIAS_MAP_FILE" > "$tmp_file"; then
        rm -f "$tmp_file"
        [ "$lock_fd_opened" -eq 1 ] && { flock -u 9; exec 9>&-; }
        return "$RC_GENERIC_ERROR"
    fi

    if ! mv "$tmp_file" "$ALIAS_MAP_FILE"; then
        rm -f "$tmp_file"
        [ "$lock_fd_opened" -eq 1 ] && { flock -u 9; exec 9>&-; }
        return "$RC_GENERIC_ERROR"
    fi

    [ "$lock_fd_opened" -eq 1 ] && { flock -u 9; exec 9>&-; }
    return 0
}

prepare_alias_txn_dir() {
    local label="${1:-alias-op}"
    local txn_root="$STATE_DIR/_txn"
    local timestamp
    local safe_label
    local txn_dir

    mkdir -p "$txn_root" || return "$RC_GENERIC_ERROR"
    timestamp=$(date +"%Y%m%d_%H%M%S")
    safe_label=$(sanitize_alias "$label")
    txn_dir=$(ensure_unique_path_with_index_suffix "$txn_root" "$timestamp-$safe_label")
    mkdir -p "$txn_dir" || return "$RC_GENERIC_ERROR"
    ui_printf '%s' "$txn_dir"
}

stage_alias_map_rename() {
    local old_alias="$1"
    local new_alias="$2"
    local output_file="$3"

    ensure_alias_map_file
    awk -F '\t' -v old="$old_alias" -v new="$new_alias" '
        BEGIN { OFS="\t" }
        {
            if ($2 == old) { $2 = new }
            print
        }
    ' "$ALIAS_MAP_FILE" > "$output_file"
}

stage_alias_map_remove() {
    local alias="$1"
    local output_file="$2"

    ensure_alias_map_file
    awk -F '\t' -v a="$alias" '$2 != a { print $0 }' "$ALIAS_MAP_FILE" > "$output_file"
}

stage_alias_limit_rename() {
    local old_alias="$1"
    local new_alias="$2"
    local output_file="$3"

    ensure_alias_backup_limit_file
    awk -F '\t' -v old="$old_alias" -v new="$new_alias" '
        BEGIN { OFS="\t" }
        {
            if ($1 == old) { $1 = new }
            print
        }
    ' "$ALIAS_BACKUP_LIMIT_FILE" > "$output_file"
}

stage_alias_limit_remove() {
    local alias="$1"
    local output_file="$2"

    ensure_alias_backup_limit_file
    awk -F '\t' -v a="$alias" '$1 != a { print $0 }' "$ALIAS_BACKUP_LIMIT_FILE" > "$output_file"
}

move_dir_children_with_suffix() {
    local src_dir="$1"
    local dst_dir="$2"
    local item
    local base_name
    local dst_path

    [ -d "$src_dir" ] || return 0
    mkdir -p "$dst_dir" || return "$RC_GENERIC_ERROR"

    shopt -s nullglob dotglob
    for item in "$src_dir"/*; do
        [ -e "$item" ] || continue
        base_name=$(basename "$item")
        dst_path=$(ensure_unique_path_with_index_suffix "$dst_dir" "$base_name")
        mv "$item" "$dst_path" || {
            shopt -u nullglob dotglob
            return "$RC_GENERIC_ERROR"
        }
    done
    shopt -u nullglob dotglob
    return 0
}

is_weak_device_id() {
    case "$1" in
        fingerprint:*) return 0 ;;
        *) return "$RC_GENERIC_ERROR" ;;
    esac
}

save_alias_mapping() {
    local device_id="$1"
    local alias="$2"
    local manufacturer="$3"
    local model="$4"
    local serial="$5"
    local ts
    local tmp_file
    local lock_fd_opened=0

    ensure_alias_map_file

    ts=$(date +"%Y-%m-%dT%H:%M:%S%z")
    tmp_file="$ALIAS_MAP_FILE.tmp.$$"

    if command -v flock >/dev/null 2>&1; then
        exec 9>"$ALIAS_MAP_LOCK_FILE"
        flock -x 9
        lock_fd_opened=1
    fi

    if ! awk -F '\t' -v did="$device_id" -v a="$alias" '$1 != did && $2 != a { print $0 }' "$ALIAS_MAP_FILE" > "$tmp_file"; then
        rm -f "$tmp_file"
        if [ "$lock_fd_opened" -eq 1 ]; then
            flock -u 9
            exec 9>&-
        fi
        return "$RC_GENERIC_ERROR"
    fi

    if ! ui_printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$device_id" "$alias" "$ts" "$serial" "$manufacturer" "$model" >> "$tmp_file"; then
        rm -f "$tmp_file"
        if [ "$lock_fd_opened" -eq 1 ]; then
            flock -u 9
            exec 9>&-
        fi
        return "$RC_GENERIC_ERROR"
    fi

    if ! mv "$tmp_file" "$ALIAS_MAP_FILE"; then
        rm -f "$tmp_file"
        if [ "$lock_fd_opened" -eq 1 ]; then
            flock -u 9
            exec 9>&-
        fi
        return "$RC_GENERIC_ERROR"
    fi

    if [ "$lock_fd_opened" -eq 1 ]; then
        flock -u 9
        exec 9>&-
    fi
}

update_current_device_identity() {
    local boot_serial
    local serial_prop
    local android_id_raw

    [ -n "$CURRENT_DEVICE_SERIAL" ] || return "$RC_GENERIC_ERROR"

    boot_serial=$(trim_output "$(get_selected_device_prop "ro.boot.serialno")")
    serial_prop=$(trim_output "$(get_selected_device_prop "ro.serialno")")
    android_id_raw=$(trim_output "$(adb_cmd shell settings get secure android_id 2>/dev/null)")

    if is_valid_identity_value "$boot_serial"; then
        CURRENT_DEVICE_ID="serial:$boot_serial"
    elif is_valid_identity_value "$serial_prop"; then
        CURRENT_DEVICE_ID="serial:$serial_prop"
    elif is_valid_identity_value "$android_id_raw"; then
        CURRENT_DEVICE_ID="android_id:$android_id_raw"
    elif [ -n "$CURRENT_DEVICE_SERIAL" ] && ! is_wireless_serial "$CURRENT_DEVICE_SERIAL"; then
        CURRENT_DEVICE_ID="adb_serial:$CURRENT_DEVICE_SERIAL"
    else
        CURRENT_DEVICE_ID=$(build_fingerprint_identity 2>/dev/null)
        if [ -z "$CURRENT_DEVICE_ID" ]; then
            CURRENT_DEVICE_ID="transport:$CURRENT_DEVICE_SERIAL"
        fi
    fi
}

refresh_context_for_selected_device() {
    local mapped_alias

    [ -n "$CURRENT_DEVICE_SERIAL" ] || {
        CURRENT_ALIAS=""
        CURRENT_DEVICE_ID=""
        return 0
    }

    if [ -z "$CURRENT_DEVICE_ID" ]; then
        update_current_device_identity || return "$RC_GENERIC_ERROR"
    fi

    if [ -z "$CURRENT_ALIAS" ]; then
        mapped_alias=$(lookup_alias_by_device_id "$CURRENT_DEVICE_ID")
        [ -n "$mapped_alias" ] && CURRENT_ALIAS="$mapped_alias"
    fi
}

resolve_or_register_alias_for_current_device() {
    local mapped_alias
    local mapped_serial
    local alias
    local mapped_device_id
    local confirm_use
    local confirm
    local manufacturer
    local model

    update_current_device_identity || return "$RC_GENERIC_ERROR"

    mapped_alias=$(lookup_alias_by_device_id "$CURRENT_DEVICE_ID")
    if [ -n "$mapped_alias" ]; then
        if is_weak_device_id "$CURRENT_DEVICE_ID"; then
            mapped_serial=$(lookup_serial_by_device_id "$CURRENT_DEVICE_ID")
            if [ -n "$mapped_serial" ] && [ "$mapped_serial" != "$CURRENT_DEVICE_SERIAL" ]; then
                ui_print "Weak identity match detected for alias '$mapped_alias'."
                ui_print "Mapped serial: $mapped_serial"
                ui_print "Current serial: $CURRENT_DEVICE_SERIAL"
                ui_prompt_input "Use this alias anyway? (y/N): " confirm_use
                if ! is_yes_response "$confirm_use"; then
                    mapped_alias=""
                fi
            fi
        fi
    fi

    if [ -n "$mapped_alias" ]; then
        CURRENT_ALIAS="$mapped_alias"
        manufacturer=$(trim_output "$(get_selected_device_prop "ro.product.manufacturer")")
        model=$(trim_output "$(get_selected_device_prop "ro.product.model")")
        save_alias_mapping "$CURRENT_DEVICE_ID" "$CURRENT_ALIAS" "$manufacturer" "$model" "$CURRENT_DEVICE_SERIAL" || return "$RC_GENERIC_ERROR"
        return 0
    fi

    alias=$(prompt_device_alias)
    mapped_device_id=$(lookup_device_id_by_alias "$alias")

    if [ -n "$mapped_device_id" ] && [ "$mapped_device_id" != "$CURRENT_DEVICE_ID" ]; then
        ui_print "Alias '$alias' is already mapped to another device."
        ui_prompt_input "Reassign this alias to current device? (y/N): " confirm
        if ! is_yes_response "$confirm"; then
            return "$RC_GENERIC_ERROR"
        fi
    fi

    manufacturer=$(trim_output "$(get_selected_device_prop "ro.product.manufacturer")")
    model=$(trim_output "$(get_selected_device_prop "ro.product.model")")
    CURRENT_ALIAS="$alias"
    save_alias_mapping "$CURRENT_DEVICE_ID" "$CURRENT_ALIAS" "$manufacturer" "$model" "$CURRENT_DEVICE_SERIAL"
}

list_wireless_devices() {
    list_devices | awk '/:[0-9]+$/ { print $1 }'
}

is_wireless_serial() {
    ui_printf '%s\n' "$1" | grep -Eq ':[0-9]+$'
}

refresh_pairing_state() {
    local index
    local has_selected_serial=0
    local previous_serial="$CURRENT_DEVICE_SERIAL"
    local -a devices
    local -a wireless_devices

    mapfile -t devices < <(list_devices)
    mapfile -t wireless_devices < <(list_wireless_devices)

    if [ -n "$CURRENT_DEVICE_SERIAL" ]; then
        for index in "${!devices[@]}"; do
            if [ "${devices[$index]}" = "$CURRENT_DEVICE_SERIAL" ]; then
                has_selected_serial=1
                break
            fi
        done
    fi

    if [ "$has_selected_serial" -ne 1 ]; then
        CURRENT_DEVICE_SERIAL=""
    fi

    if [ -z "$CURRENT_DEVICE_SERIAL" ] && [ "${#devices[@]}" -eq 1 ]; then
        CURRENT_DEVICE_SERIAL="${devices[0]}"
    fi

    if [ "$CURRENT_DEVICE_SERIAL" != "$previous_serial" ]; then
        CURRENT_ALIAS=""
        CURRENT_DEVICE_ID=""
    fi

    if [ "${#wireless_devices[@]}" -gt 0 ]; then
        HAS_ACTIVE_PAIRING=1
    else
        HAS_ACTIVE_PAIRING=0
    fi

    if [ "$HAS_ACTIVE_PAIRING" -eq 1 ]; then
        if [ -n "$CURRENT_DEVICE_SERIAL" ] && is_wireless_serial "$CURRENT_DEVICE_SERIAL"; then
            CURRENT_DEVICE_ENDPOINT="$CURRENT_DEVICE_SERIAL"
        elif [ "${#wireless_devices[@]}" -eq 1 ]; then
            CURRENT_DEVICE_ENDPOINT="${wireless_devices[0]}"
        else
            CURRENT_DEVICE_ENDPOINT=""
        fi
    else
        CURRENT_DEVICE_ENDPOINT=""
    fi

    if [ "${#devices[@]}" -eq 0 ]; then
        CURRENT_ALIAS=""
        CURRENT_DEVICE_ID=""
    fi
}

ensure_target_device_selected() {
    local selection
    local prompt_rc
    local index
    local -a devices

    mapfile -t devices < <(list_devices)

    [ "${#devices[@]}" -gt 0 ] || return "$RC_GENERIC_ERROR"

    if [ -n "$CURRENT_DEVICE_SERIAL" ]; then
        for index in "${!devices[@]}"; do
            if [ "${devices[$index]}" = "$CURRENT_DEVICE_SERIAL" ]; then
                return 0
            fi
        done
    fi

    if [ "${#devices[@]}" -eq 1 ]; then
        if [ "$CURRENT_DEVICE_SERIAL" != "${devices[0]}" ]; then
            CURRENT_ALIAS=""
            CURRENT_DEVICE_ID=""
        fi
        CURRENT_DEVICE_SERIAL="${devices[0]}"
        return 0
    fi

    ui_header "Select Target Device"
    for index in "${!devices[@]}"; do
        if [ "${devices[$index]}" = "$CURRENT_DEVICE_SERIAL" ]; then
            ui_option "$((index + 1))" "${devices[$index]} [current]"
        else
            ui_option "$((index + 1))" "${devices[$index]}"
        fi
    done

    selection=$(prompt_number_in_range "Select: " 1 "${#devices[@]}")
    prompt_rc=$?
    [ "$prompt_rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"

    if [ "$CURRENT_DEVICE_SERIAL" != "${devices[$((selection - 1))]}" ]; then
        CURRENT_ALIAS=""
        CURRENT_DEVICE_ID=""
    fi
    CURRENT_DEVICE_SERIAL="${devices[$((selection - 1))]}"
}

pair_device() {
    local ip
    local port
    local code
    local connect_port
    local device

    ensure_adb_installed || {
        ui_print "ADB is not installed."
        return "$RC_GENERIC_ERROR"
    }

    ui_header "Pair Device"
    ui_prompt_input "IP: " ip
    ui_prompt_input "Pairing Port: " port
    ui_prompt_input "Pairing Code: " code

    if ! adb pair "$ip:$port" <<< "$code"; then
        ui_print "Pairing failed."
        return "$RC_GENERIC_ERROR"
    fi

    ui_prompt_input "Connect Port: " connect_port

    if ! adb connect "$ip:$connect_port"; then
        ui_print "Connect failed."
        return "$RC_GENERIC_ERROR"
    fi

    CURRENT_DEVICE_SERIAL="$ip:$connect_port"
    CURRENT_DEVICE_ENDPOINT="$ip:$connect_port"
    refresh_pairing_state

    resolve_or_register_alias_for_current_device || {
        ui_print "Alias setup cancelled."
        return "$RC_GENERIC_ERROR"
    }

    ui_header "Pairing Complete"
    ui_status_line "Endpoint:" "$CURRENT_DEVICE_SERIAL"
    ui_status_line "Active alias:" "$CURRENT_ALIAS"
    ui_divider
    ui_print "Connected devices:"
    while IFS= read -r device; do
        [ -n "$device" ] && ui_print "$device"
    done < <(list_devices)
}

disconnect_active_pairing() {
    local mode="${1:-interactive}"
    local selection
    local prompt_rc
    local index
    local target_endpoint
    local rc=0
    local -a wireless_devices

    refresh_pairing_state

    if [ "$HAS_ACTIVE_PAIRING" -ne 1 ]; then
        ui_print "No active pairing."
        return 0
    fi

    ensure_adb_installed || {
        ui_print "ADB is not installed."
        return "$RC_GENERIC_ERROR"
    }

    mapfile -t wireless_devices < <(list_wireless_devices)
    [ "${#wireless_devices[@]}" -gt 0 ] || {
        ui_print "No active pairing."
        return 0
    }

    if [ -n "$CURRENT_DEVICE_SERIAL" ] && is_wireless_serial "$CURRENT_DEVICE_SERIAL"; then
        target_endpoint="$CURRENT_DEVICE_SERIAL"
    elif [ "${#wireless_devices[@]}" -eq 1 ]; then
        target_endpoint="${wireless_devices[0]}"
    elif [ "$mode" = "auto" ]; then
        ui_print "Auto disconnect skipped: multiple wireless devices."
        return "$RC_GENERIC_ERROR"
    else
        ui_header "Select Wireless Device"
        for index in "${!wireless_devices[@]}"; do
            ui_option "$((index + 1))" "${wireless_devices[$index]}"
        done

        selection=$(prompt_number_in_range "Select: " 1 "${#wireless_devices[@]}")
        prompt_rc=$?
        [ "$prompt_rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"

        target_endpoint="${wireless_devices[$((selection - 1))]}"
    fi

    if adb disconnect "$target_endpoint"; then
        ui_print "Disconnected: $target_endpoint"
    else
        ui_print "Disconnect failed: $target_endpoint"
        rc=1
    fi

    if [ "$CURRENT_DEVICE_SERIAL" = "$target_endpoint" ]; then
        CURRENT_ALIAS=""
        CURRENT_DEVICE_SERIAL=""
        CURRENT_DEVICE_ID=""
    fi

    refresh_pairing_state

    return $rc
}

ensure_device_connected() {
    local rc
    local choice
    local prompt_rc
    local device

    while true; do
        if [ -n "$(list_devices)" ]; then
            if ! ensure_target_device_selected; then
                rc=$?
                [ "$rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"
                continue
            fi
            refresh_pairing_state
            refresh_context_for_selected_device >/dev/null 2>&1 || true
            ui_header "Connected Devices"
            while IFS= read -r device; do
                [ -n "$device" ] && ui_print "$device"
            done < <(list_devices)
            ui_status_line "Target:" "$CURRENT_DEVICE_SERIAL"
            return 0
        fi

        ui_header "No Device Detected"
        ui_option "1" "USB"
        ui_option "2" "Pairing"
        ui_option "3" "Retry"
        ui_option "4" "Exit"
        choice=$(prompt_number_in_range "Select: " 1 4)
        prompt_rc=$?
        [ "$prompt_rc" -eq "$RC_CANCELLED" ] && continue

        case "$choice" in
            1) ui_pause "Connect USB and press Enter..." ;;
            2)
                pair_device
                ui_pause
                ;;
            3) ;;
            4) return "$RC_GENERIC_ERROR" ;;
        esac
    done
}

normalize_value() {
    local value

    value=$(ui_printf '%s' "$1" | tr -d '\r' | sed 's/[[:space:]]*$//')

    if [ -z "$value" ] || [ "$value" = "null" ]; then
        ui_printf '%s' "$UNSET_MARKER"
    else
        ui_printf '%s' "$value"
    fi
}

display_value() {
    if [ "$1" = "$UNSET_MARKER" ]; then
        ui_printf '%s' "<unset>"
    else
        ui_printf '%s' "$1"
    fi
}

sanitize_alias() {
    local alias="$1"

    alias=$(trim_output "$alias")
    alias="${alias// /_}"
    alias="${alias//\//_}"
    alias=$(ui_printf '%s' "$alias" | sed 's/[^A-Za-z0-9._-]/_/g')
    alias=$(ui_printf '%s' "$alias" | sed 's/_\+/_/g; s/^_//; s/_$//')

    if [ -z "$alias" ]; then
        alias="default"
    fi

    ui_printf '%s' "$alias"
}

is_valid_alias() {
    ui_printf '%s' "$1" | grep -Eq '^[A-Za-z0-9._-]{1,64}$'
}

prompt_device_alias() {
    local alias_input
    local alias

    while true; do
        ui_prompt_input "Device alias: " alias_input
        alias=$(sanitize_alias "$alias_input")

        if is_valid_alias "$alias"; then
            ui_printf '%s' "$alias"
            return 0
        fi

        ui_print "Alias must use [A-Za-z0-9._-] and be 1-64 chars."
    done
}

ensure_alias_for_selected_device() {
    if resolve_or_register_alias_for_current_device; then
        ui_print "Using alias: $CURRENT_ALIAS"
        return 0
    fi

    ui_print "Alias resolution failed."
    return "$RC_GENERIC_ERROR"
}

acquire_alias_lock() {
    local alias="$1"
    local lock_file
    local lock_dir
    local fd

    [ -n "$alias" ] || return "$RC_GENERIC_ERROR"

    if [ -n "$ACTIVE_LOCK_METHOD" ]; then
        return "$RC_OK"
    fi

    mkdir -p "$STATE_DIR/$alias" || {
        ui_print "Failed to create alias state directory: $STATE_DIR/$alias"
        return "$RC_GENERIC_ERROR"
    }

    lock_file="$STATE_DIR/$alias/.transaction.lock"

    if command -v flock >/dev/null 2>&1; then
        exec {fd}>"$lock_file" || {
            ui_print "Failed to open lock file: $lock_file"
            return "$RC_GENERIC_ERROR"
        }
        if flock -n "$fd"; then
            ACTIVE_LOCK_METHOD="flock"
            ACTIVE_LOCK_PATH="$lock_file"
            ACTIVE_LOCK_FD="$fd"
            return "$RC_OK"
        fi

        eval "exec ${fd}>&-"
        ui_print "Another transaction is already running for alias '$alias'."
        return "$RC_LOCK_BUSY"
    fi

    lock_dir="$lock_file.d"
    if mkdir "$lock_dir" 2>/dev/null; then
        ACTIVE_LOCK_METHOD="mkdir"
        ACTIVE_LOCK_PATH="$lock_dir"
        ACTIVE_LOCK_FD=""
        return "$RC_OK"
    fi

    ui_print "Another transaction is already running for alias '$alias'."
    return "$RC_LOCK_BUSY"
}

release_alias_lock() {
    if [ "$ACTIVE_LOCK_METHOD" = "flock" ] && [ -n "$ACTIVE_LOCK_FD" ]; then
        flock -u "$ACTIVE_LOCK_FD" >/dev/null 2>&1 || true
        eval "exec ${ACTIVE_LOCK_FD}>&-"
    elif [ "$ACTIVE_LOCK_METHOD" = "mkdir" ] && [ -n "$ACTIVE_LOCK_PATH" ]; then
        rmdir "$ACTIVE_LOCK_PATH" >/dev/null 2>&1 || true
    fi

    ACTIVE_LOCK_METHOD=""
    ACTIVE_LOCK_PATH=""
    ACTIVE_LOCK_FD=""
}

get_operation_key() {
    local kind="$1"
    local namespace="$2"
    local key="$3"

    case "$kind" in
        device_config) ui_printf '%s' "device_config.$namespace.$key" ;;
        settings) ui_printf '%s' "settings.$namespace.$key" ;;
        *) ui_printf '%s' "$key" ;;
    esac
}

get_operation_key_width() {
    local -n operations_ref="$1"
    local index
    local kind
    local namespace
    local key
    local target
    local operation_key
    local max_width=1

    for index in "${!operations_ref[@]}"; do
        IFS='|' read -r kind namespace key target <<< "${operations_ref[$index]}"
        operation_key=$(get_operation_key "$kind" "$namespace" "$key")
        if [ "${#operation_key}" -gt "$max_width" ]; then
            max_width=${#operation_key}
        fi
    done

    ui_printf '%s' "$max_width"
}

print_operation_result() {
    local status="$1"
    local operation_key="$2"
    local detail="$3"
    local key_width="${4:-1}"

    ui_printf '%s%-16s %-*s => %s\n' "$UI_PAD_LEFT" "$status" "$key_width" "$operation_key" "$detail"
}

print_lint_result() {
    local level="$1"
    local subject="$2"
    local detail="$3"
    local subject_width="${4:-1}"

    ui_printf '%s%-16s %-*s : %s\n' "$UI_PAD_LEFT" "$level" "$subject_width" "$subject" "$detail"
}

resolve_target_value() {
    local kind="$1"
    local key="$2"
    local value="$3"

    if [ "$kind" = "device_config" ] && [ "$key" = "sync_disabled_for_tests" ]; then
        if [ "$value" = "$UNSET_MARKER" ]; then
            ui_printf '%s' "none"
        else
            ui_printf '%s' "$value"
        fi
    elif [ "$value" = "$UNSET_MARKER" ]; then
        ui_printf '%s' "$DELETE_MARKER"
    else
        ui_printf '%s' "$value"
    fi
}

display_target_value() {
    local target="$1"
    local normalized

    if [ "$target" = "$DELETE_MARKER" ]; then
        ui_printf '%s' "<delete>"
        return 0
    fi

    normalized=$(normalize_value "$target")
    display_value "$normalized"
}

read_remote_value() {
    local kind="$1"
    local namespace="$2"
    local key="$3"
    local output

    case "$kind" in
        device_config)
            if [ "$key" = "sync_disabled_for_tests" ]; then
                output=$(adb_cmd shell /system/bin/device_config get_sync_disabled_for_tests 2>&1) || {
                    ui_printf '%s' "$output"
                    return "$RC_GENERIC_ERROR"
                }
            else
                output=$(adb_cmd shell /system/bin/device_config get "$namespace" "$key" 2>&1) || {
                    ui_printf '%s' "$output"
                    return "$RC_GENERIC_ERROR"
                }
            fi
            ;;
        settings)
            output=$(adb_cmd shell settings get "$namespace" "$key" 2>&1) || {
                ui_printf '%s' "$output"
                return "$RC_GENERIC_ERROR"
            }
            ;;
        *)
            ui_printf '%s' "Unsupported operation kind: $kind"
            return "$RC_GENERIC_ERROR"
            ;;
    esac

    ui_printf '%s' "$output"
}

get_current_value() {
    local raw

    raw=$(read_remote_value "$1" "$2" "$3" 2>&1) || {
        ui_printf '%s' "$raw"
        return "$RC_GENERIC_ERROR"
    }

    normalize_value "$raw"
}

set_remote_value() {
    local kind="$1"
    local namespace="$2"
    local key="$3"
    local target="$4"
    local output

    case "$kind" in
        device_config)
            if [ "$key" = "sync_disabled_for_tests" ]; then
                output=$(adb_cmd shell /system/bin/device_config set_sync_disabled_for_tests "$target" 2>&1) || {
                    ui_printf '%s' "$output"
                    return "$RC_GENERIC_ERROR"
                }
            else
                if [ "$target" = "$DELETE_MARKER" ]; then
                    output=$(adb_cmd shell /system/bin/device_config delete "$namespace" "$key" 2>&1) || {
                        ui_printf '%s' "$output"
                        return "$RC_GENERIC_ERROR"
                    }
                else
                    output=$(adb_cmd shell /system/bin/device_config put "$namespace" "$key" "$target" 2>&1) || {
                        ui_printf '%s' "$output"
                        return "$RC_GENERIC_ERROR"
                    }
                fi
            fi
            ;;
        settings)
            if [ "$target" = "$DELETE_MARKER" ]; then
                output=$(adb_cmd shell settings delete "$namespace" "$key" 2>&1) || {
                    ui_printf '%s' "$output"
                    return "$RC_GENERIC_ERROR"
                }
            else
                output=$(adb_cmd shell settings put "$namespace" "$key" "$target" 2>&1) || {
                    ui_printf '%s' "$output"
                    return "$RC_GENERIC_ERROR"
                }
            fi
            ;;
        *)
            ui_printf '%s' "Unsupported operation kind: $kind"
            return "$RC_GENERIC_ERROR"
            ;;
    esac

    ui_printf '%s' "$output"
}

verify_remote_value() {
    local kind="$1"
    local namespace="$2"
    local key="$3"
    local expected="$4"
    local current
    local expected_normalized

    current=$(get_current_value "$kind" "$namespace" "$key" 2>&1) || {
        ui_printf '%s' "verification failed: $current"
        return "$RC_GENERIC_ERROR"
    }

    if [ "$expected" = "$DELETE_MARKER" ]; then
        expected_normalized="$UNSET_MARKER"
    else
        expected_normalized=$(normalize_value "$expected")
    fi

    if [ "$current" != "$expected_normalized" ]; then
        ui_printf '%s' "expected $(display_value "$expected_normalized"), got $(display_value "$current")"
        return "$RC_GENERIC_ERROR"
    fi

    ui_printf '%s' "$current"
}

restore_original_value() {
    local kind="$1"
    local namespace="$2"
    local key="$3"
    local original="$4"
    local rollback_target

    rollback_target=$(resolve_target_value "$kind" "$key" "$original")

    set_remote_value "$kind" "$namespace" "$key" "$rollback_target" >/dev/null 2>&1 || return "$RC_GENERIC_ERROR"
    verify_remote_value "$kind" "$namespace" "$key" "$rollback_target" >/dev/null 2>&1
}

calculate_text_checksum() {
    local text="$1"
    local hash

    if command -v sha256sum >/dev/null 2>&1; then
        hash=$(ui_printf '%s' "$text" | sha256sum | awk '{print $1}')
        ui_printf 'sha256:%s' "$hash"
    elif command -v shasum >/dev/null 2>&1; then
        hash=$(ui_printf '%s' "$text" | shasum -a 256 | awk '{print $1}')
        ui_printf 'sha256:%s' "$hash"
    else
        hash=$(ui_printf '%s' "$text" | cksum | awk '{print $1":"$2}')
        ui_printf 'cksum:%s' "$hash"
    fi
}

snapshot_metadata_value() {
    local snapshot_file="$1"
    local key="$2"

    sed -n "s/^# ${key}=//p" "$snapshot_file" | head -n 1
}

validate_snapshot_integrity() {
    local snapshot_file="$1"
    local snapshot_version
    local expected_checksum
    local operations_payload
    local actual_checksum

    snapshot_version=$(snapshot_metadata_value "$snapshot_file" "version")
    expected_checksum=$(snapshot_metadata_value "$snapshot_file" "operations_checksum")

    if [ "$snapshot_version" != "2" ]; then
        ui_msg_err "Snapshot integrity failed: unsupported or missing version."
        return "$RC_SNAPSHOT_INVALID"
    fi

    if [ -z "$expected_checksum" ]; then
        ui_msg_err "Snapshot integrity failed: checksum metadata missing."
        return "$RC_SNAPSHOT_INVALID"
    fi

    operations_payload=$(grep -E '^(device_config|settings)\|' "$snapshot_file" || true)
    if [ -z "$operations_payload" ]; then
        ui_msg_err "Snapshot integrity failed: no operation lines found."
        return "$RC_SNAPSHOT_INVALID"
    fi

    actual_checksum=$(calculate_text_checksum "$operations_payload")
    if [ "$actual_checksum" != "$expected_checksum" ]; then
        ui_msg_err "Snapshot integrity failed: checksum mismatch."
        ui_msg_err "Expected: $expected_checksum"
        ui_msg_err "Actual:   $actual_checksum"
        return "$RC_SNAPSHOT_INVALID"
    fi

    ui_msg_err "Snapshot integrity: OK ($actual_checksum)."
}

show_snapshot_metadata() {
    local snapshot_file="$1"
    local version
    local created_at
    local alias
    local target_serial
    local device_id
    local source_snapshot

    version=$(snapshot_metadata_value "$snapshot_file" "version")
    created_at=$(snapshot_metadata_value "$snapshot_file" "created_at")
    alias=$(snapshot_metadata_value "$snapshot_file" "alias")
    target_serial=$(snapshot_metadata_value "$snapshot_file" "target_serial")
    device_id=$(snapshot_metadata_value "$snapshot_file" "device_id")
    source_snapshot=$(snapshot_metadata_value "$snapshot_file" "source_snapshot")

    ui_header "Snapshot Metadata"
    ui_status_line "Version:" "${version:-unknown}"
    ui_status_line "Created:" "${created_at:-unknown}"
    ui_status_line "Alias:" "${alias:-unknown}"
    ui_status_line "Target:" "${target_serial:-unknown}"
    ui_status_line "Device ID:" "${device_id:-unknown}"
    [ -n "$source_snapshot" ] && ui_status_line "Source:" "$source_snapshot"
}

guard_restore_snapshot_loop() {
    local snapshot_file="$1"
    local snapshot_kind
    local source_snapshot
    local confirm

    snapshot_kind=$(snapshot_metadata_value "$snapshot_file" "snapshot")
    source_snapshot=$(snapshot_metadata_value "$snapshot_file" "source_snapshot")

    case "$snapshot_kind" in
        restore-snapshot|auto-pre-restore)
            ui_print "Warning: selected snapshot appears to be an automatic pre-restore backup."
            [ -n "$source_snapshot" ] && [ "$source_snapshot" != "unknown" ] && ui_printf '%sSource snapshot: %s\n' "$UI_PAD_LEFT" "$source_snapshot"
            ui_prompt_input "Continue restore anyway? (y/N): " confirm
            is_yes_response "$confirm" || return "$RC_CANCELLED"
            ;;
    esac

    return "$RC_OK"
}

confirm_snapshot_target_compatibility() {
    local snapshot_file="$1"
    local snapshot_device_id
    local snapshot_target_serial
    local confirm

    snapshot_device_id=$(snapshot_metadata_value "$snapshot_file" "device_id")
    snapshot_target_serial=$(snapshot_metadata_value "$snapshot_file" "target_serial")

    if [ -n "$snapshot_device_id" ] && [ "$snapshot_device_id" != "unknown" ] && [ -n "$CURRENT_DEVICE_ID" ] && [ "$snapshot_device_id" != "$CURRENT_DEVICE_ID" ]; then
        ui_print "Warning: snapshot device_id differs from current device."
        ui_print "Snapshot: $snapshot_device_id"
        ui_print "Current : $CURRENT_DEVICE_ID"
        ui_prompt_input "Continue restore anyway? (y/N): " confirm
        is_yes_response "$confirm" || return "$RC_CANCELLED"
    elif [ -n "$snapshot_target_serial" ] && [ "$snapshot_target_serial" != "unknown" ] && [ -n "$CURRENT_DEVICE_SERIAL" ] && [ "$snapshot_target_serial" != "$CURRENT_DEVICE_SERIAL" ]; then
        ui_print "Warning: snapshot target_serial differs from current serial."
        ui_print "Snapshot: $snapshot_target_serial"
        ui_print "Current : $CURRENT_DEVICE_SERIAL"
        ui_prompt_input "Continue restore anyway? (y/N): " confirm
        is_yes_response "$confirm" || return "$RC_CANCELLED"
    fi

    return "$RC_OK"
}

confirm_snapshot_target_compatibility_non_interactive() {
    local snapshot_file="$1"
    local snapshot_device_id
    local snapshot_target_serial

    snapshot_device_id=$(snapshot_metadata_value "$snapshot_file" "device_id")
    snapshot_target_serial=$(snapshot_metadata_value "$snapshot_file" "target_serial")

    if [ -n "$snapshot_device_id" ] && [ "$snapshot_device_id" != "unknown" ] && [ -n "$CURRENT_DEVICE_ID" ] && [ "$snapshot_device_id" != "$CURRENT_DEVICE_ID" ]; then
        ui_printf '%sSnapshot device_id mismatch (non-interactive mode).\n' "$UI_PAD_LEFT"
        ui_print "Snapshot: $snapshot_device_id"
        ui_print "Current : $CURRENT_DEVICE_ID"
        return "$RC_GENERIC_ERROR"
    fi

    if [ -n "$snapshot_target_serial" ] && [ "$snapshot_target_serial" != "unknown" ] && [ -n "$CURRENT_DEVICE_SERIAL" ] && [ "$snapshot_target_serial" != "$CURRENT_DEVICE_SERIAL" ]; then
        ui_printf '%sSnapshot target_serial mismatch (non-interactive mode).\n' "$UI_PAD_LEFT"
        ui_print "Snapshot: $snapshot_target_serial"
        ui_print "Current : $CURRENT_DEVICE_SERIAL"
        return "$RC_GENERIC_ERROR"
    fi

    return 0
}

backup_snapshot() {
    local alias="$1"
    local mode="$2"
    local -n operations_ref="$3"
    local source_snapshot="${4:-unknown}"
    local dir="$STATE_DIR/$alias/backups"
    local ts
    local file
    local tmp_file
    local base_name
    local index=1
    local created_at
    local operation
    local kind
    local namespace
    local key
    local target
    local key_id
    local line
    local operations_payload=""
    local operations_checksum
    local current_value
    local backup_target
    local seen_keys=""
    local -a backups
    local old_backup
    local backup_limit

    mkdir -p "$dir" || {
        ui_print "Failed to create backup directory."
        return "$RC_BACKUP_FAILED"
    }

    ts=$(date +"%Y%m%d_%H%M%S")
    base_name="$ts-$mode.snapshot"
    file="$dir/$base_name"

    while [ -e "$file" ]; do
        file="$dir/$ts-$mode-$index.snapshot"
        index=$((index + 1))
    done

    created_at=$(date +"%Y-%m-%dT%H:%M:%S%z")

    for operation in "${operations_ref[@]}"; do
        IFS='|' read -r kind namespace key target <<< "$operation"
        [ -n "$kind" ] || continue
        key_id="$kind|$namespace|$key"

        if ui_printf '%s\n' "$seen_keys" | grep -Fxq "$key_id"; then
            continue
        fi
        if [ -n "$seen_keys" ]; then
            seen_keys+=$'\n'
        fi
        seen_keys+="$key_id"

        current_value=$(get_current_value "$kind" "$namespace" "$key" 2>&1) || {
            ui_msg_err "Failed to read $(get_operation_key "$kind" "$namespace" "$key"): $current_value"
            return "$RC_BACKUP_FAILED"
        }
        backup_target=$(resolve_target_value "$kind" "$key" "$current_value")
        line="$kind|$namespace|$key|$backup_target"
        if [ -n "$operations_payload" ]; then
            operations_payload+=$'\n'
        fi
        operations_payload+="$line"
    done

    operations_checksum=$(calculate_text_checksum "$operations_payload")
    tmp_file="$file.tmp.$$"

    {
        ui_printf '# version=2\n'
        ui_printf '# snapshot=%s\n' "$mode"
        ui_printf '# created_at=%s\n' "$created_at"
        ui_printf '# alias=%s\n' "${alias:-unknown}"
        ui_printf '# target_serial=%s\n' "${CURRENT_DEVICE_SERIAL:-unknown}"
        ui_printf '# device_id=%s\n' "${CURRENT_DEVICE_ID:-unknown}"
        ui_printf '# source_snapshot=%s\n' "${source_snapshot:-unknown}"
        ui_printf '# operations_checksum=%s\n' "$operations_checksum"
        ui_printf '%s\n' "$operations_payload"
    } > "$tmp_file" || {
        rm -f "$tmp_file"
        ui_print "Failed to write backup file."
        return "$RC_BACKUP_FAILED"
    }

    if ! mv "$tmp_file" "$file"; then
        rm -f "$tmp_file"
        ui_print "Failed to finalize backup file."
        return "$RC_BACKUP_FAILED"
    fi

    mapfile -t backups < <(list_snapshot_files_sorted "$alias")
    backup_limit=$(get_backup_limit_for_alias "$alias")

    if [ "${#backups[@]}" -gt "$backup_limit" ]; then
        for old_backup in "${backups[@]:$backup_limit}"; do
            rm -f "$dir/$old_backup"
        done
    fi

    ui_printf '%s' "$file"
}

load_snapshot_operations() {
    local snapshot_file="$1"
    local operations

    validate_snapshot_integrity "$snapshot_file" || return "$RC_SNAPSHOT_INVALID"
    operations=$(grep -E '^(device_config|settings)\|' "$snapshot_file" || true)
    [ -n "$operations" ] || {
        ui_msg_err "Snapshot has no operations: $snapshot_file"
        return "$RC_SNAPSHOT_INVALID"
    }

    ui_printf '%s\n' "$operations"
}

snapshot_created_at_to_epoch() {
    local snapshot_file="$1"
    local created_at
    local epoch

    created_at=$(snapshot_metadata_value "$snapshot_file" "created_at")
    if [ -n "$created_at" ]; then
        epoch=$(date -d "$created_at" +%s 2>/dev/null || true)
        if [ -n "$epoch" ]; then
            ui_printf '%s' "$epoch"
            return 0
        fi
    fi

    stat -c %Y "$snapshot_file" 2>/dev/null || ui_printf '0'
}

list_snapshot_files_sorted() {
    local alias="$1"
    local dir="$STATE_DIR/$alias/backups"
    local file
    local base
    local epoch

    [ -d "$dir" ] || return "$RC_GENERIC_ERROR"

    shopt -s nullglob
    for file in "$dir"/*.snapshot; do
        [ -e "$file" ] || continue
        base=$(basename "$file")
        epoch=$(snapshot_created_at_to_epoch "$file")
        ui_printf '%020d|%s\n' "$epoch" "$base"
    done | sort -r | cut -d'|' -f2-
    shopt -u nullglob
}

show_snapshot_list() {
    local alias="$1"
    local dir="$STATE_DIR/$alias/backups"
    local index
    local index_width
    local max_index
    local snapshot_path
    local created_at
    local -a snapshots

    [ -d "$dir" ] || {
        ui_msg_err "No backups found for alias: $alias"
        return "$RC_GENERIC_ERROR"
    }

    mapfile -t snapshots < <(list_snapshot_files_sorted "$alias")
    [ "${#snapshots[@]}" -gt 0 ] || {
        ui_msg_err "No backups found for alias: $alias"
        return "$RC_GENERIC_ERROR"
    }
    max_index=${#snapshots[@]}
    index_width=${#max_index}

    ui_header "Snapshot List"
    for index in "${!snapshots[@]}"; do
        snapshot_path="$dir/${snapshots[$index]}"
        created_at=$(snapshot_metadata_value "$snapshot_path" "created_at")
        ui_indexed_row "$((index + 1))" "$index_width" "${snapshots[$index]}"
        if [ -n "$created_at" ]; then
            ui_printf '%s   %screated:%s %s%s%s\n' "$UI_PAD_LEFT" "$UI_COLOR_LABEL" "$UI_COLOR_RESET" "$UI_COLOR_VALUE" "$created_at" "$UI_COLOR_RESET"
        fi
    done
    return "$RC_OK"
}

prompt_execution_mode() {
    local mode_choice
    local prompt_rc

    ui_header_err "Execution Mode"
    ui_option_err "1" "Execute"
    ui_option_err "2" "Dry-run"
    ui_option_err "3" "Cancel"
    mode_choice=$(prompt_number_in_range "Select: " 1 3)
    prompt_rc=$?
    [ "$prompt_rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"

    case "$mode_choice" in
        1) ui_printf '%s' "execute" ;;
        2) ui_printf '%s' "dry-run" ;;
        3) ui_printf '%s' "cancel" ;;
    esac
}

sanitize_operation_name() {
    sanitize_alias "$1"
}

is_valid_operation_name() {
    is_valid_alias "$1"
}

validate_operation_value_by_type() {
    local value_type="$1"
    local target="$2"
    local target_lc

    case "$value_type" in
        string)
            [ -n "$target" ] || {
                ui_print "string type requires non-empty target"
                return "$RC_GENERIC_ERROR"
            }
            ;;
        int)
            ui_printf '%s' "$target" | grep -Eq '^-?[0-9]+$' || {
                ui_print "int type requires integer target"
                return "$RC_GENERIC_ERROR"
            }
            ;;
        bool)
            target_lc=$(ui_printf '%s' "$target" | tr '[:upper:]' '[:lower:]')
            case "$target_lc" in
                true|false) ;;
                *)
                    ui_print "bool type requires true/false target"
                    return "$RC_GENERIC_ERROR"
                    ;;
            esac
            ;;
        delete)
            [ -n "$target" ] || target="$DELETE_MARKER"
            case "$target" in
                "$DELETE_MARKER"|-) ;;
                *)
                    ui_print "delete type target must be '$DELETE_MARKER' or '-'"
                    return "$RC_GENERIC_ERROR"
                    ;;
            esac
            ;;
        *)
            ui_print "Unsupported value type: $value_type"
            return "$RC_GENERIC_ERROR"
            ;;
    esac

    return 0
}

normalize_operation_target_by_type() {
    local value_type="$1"
    local target="$2"

    case "$value_type" in
        string) ui_printf '%s' "$target" ;;
        int) ui_printf '%s' "$target" ;;
        bool) ui_printf '%s' "$(ui_printf '%s' "$target" | tr '[:upper:]' '[:lower:]')" ;;
        delete) ui_printf '%s' "$DELETE_MARKER" ;;
        *) return "$RC_GENERIC_ERROR" ;;
    esac
}

operation_file_path() {
    local operation_name="$1"
    ui_printf '%s/%s.op' "$OPERATION_DIR" "$operation_name"
}

list_operation_files() {
    local file
    local -a matched

    shopt -s nullglob
    matched=("$OPERATION_DIR"/*.op)
    shopt -u nullglob

    [ "${#matched[@]}" -gt 0 ] || return "$RC_GENERIC_ERROR"

    for file in "${matched[@]}"; do
        basename "$file"
    done | sort
}

load_operation_spec() {
    local operation_file="$1"
    local raw_line
    local line
    local version
    local kind
    local namespace
    local key
    local value_type
    local target
    local extra
    local operation_spec=""
    local normalized_target

    [ -f "$operation_file" ] || {
        ui_print "Operation file not found: $operation_file"
        return "$RC_GENERIC_ERROR"
    }

    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        line=$(trim_output "$raw_line")
        [ -n "$line" ] || continue
        case "$line" in
            \#\ version=*)
                version="${line#\# version=}"
                continue
                ;;
            \#*) continue ;;
        esac

        case "$version" in
            1)
                IFS='|' read -r kind namespace key target extra <<< "$line"
                if [ -n "$extra" ] || [ -z "$kind" ] || [ -z "$namespace" ] || [ -z "$key" ] || [ -z "$target" ]; then
                    ui_print "Invalid operation line: $line"
                    return "$RC_GENERIC_ERROR"
                fi

                case "$kind" in
                    device_config|settings) ;;
                    *)
                        ui_print "Unsupported operation kind in file: $kind"
                        return "$RC_GENERIC_ERROR"
                        ;;
                esac

                normalized_target="$target"
                ;;
            2)
                IFS='|' read -r kind namespace key value_type target extra <<< "$line"
                if [ -n "$extra" ] || [ -z "$kind" ] || [ -z "$namespace" ] || [ -z "$key" ] || [ -z "$value_type" ] || [ -z "$target" ]; then
                    ui_print "Invalid operation line: $line"
                    return "$RC_GENERIC_ERROR"
                fi

                case "$kind" in
                    device_config|settings) ;;
                    *)
                        ui_print "Unsupported operation kind in file: $kind"
                        return "$RC_GENERIC_ERROR"
                        ;;
                esac

                value_type=$(ui_printf '%s' "$value_type" | tr '[:upper:]' '[:lower:]')
                validate_operation_value_by_type "$value_type" "$target" || {
                    ui_print "Invalid typed target in file ($kind|$namespace|$key): $line"
                    return "$RC_GENERIC_ERROR"
                }

                normalized_target=$(normalize_operation_target_by_type "$value_type" "$target") || {
                    ui_print "Failed to normalize typed target: $line"
                    return "$RC_GENERIC_ERROR"
                }
                ;;
            *)
                ui_print "Unsupported or missing operation version in file: $operation_file"
                return "$RC_GENERIC_ERROR"
                ;;
        esac

        if [ -n "$operation_spec" ]; then
            operation_spec+=$'\n'
        fi
        operation_spec+="$kind|$namespace|$key|$normalized_target"
    done < "$operation_file"

    if [ "$version" != "1" ] && [ "$version" != "2" ]; then
        ui_print "Unsupported or missing operation version in file: $operation_file"
        return "$RC_GENERIC_ERROR"
    fi

    [ -n "$operation_spec" ] || {
        ui_print "Operation file has no entries: $operation_file"
        return "$RC_GENERIC_ERROR"
    }

    ui_printf '%s\n' "$operation_spec"
}

show_operation_preview() {
    local title="$1"
    local -n operations_ref="$2"
    local show_count="${3:-1}"
    local index
    local index_width
    local max_index
    local kind
    local namespace
    local key
    local target
    local operation_key

    ui_header "$title"
    max_index=${#operations_ref[@]}
    index_width=${#max_index}
    for index in "${!operations_ref[@]}"; do
        IFS='|' read -r kind namespace key target <<< "${operations_ref[$index]}"
        operation_key=$(get_operation_key "$kind" "$namespace" "$key")
        ui_indexed_row "$((index + 1))" "$index_width" "$operation_key -> $(display_target_value "$target")"
    done
    [ "$show_count" = "1" ] && ui_status_line "Entries:" "${#operations_ref[@]}"
}

show_pre_execution_diff() {
    local title="$1"
    local -n operations_ref="$2"
    local index
    local kind
    local namespace
    local key
    local target
    local operation_key
    local current_value
    local expected_normalized
    local changed_count=0
    local same_count=0
    local read_fail_count=0
    local operation_key_width

    ui_header "$title"
    operation_key_width=$(get_operation_key_width operations_ref)
    for index in "${!operations_ref[@]}"; do
        IFS='|' read -r kind namespace key target <<< "${operations_ref[$index]}"
        operation_key=$(get_operation_key "$kind" "$namespace" "$key")
        current_value=$(get_current_value "$kind" "$namespace" "$key" 2>&1) || {
            print_operation_result "[READ-FAIL]" "$operation_key" "$current_value" "$operation_key_width"
            read_fail_count=$((read_fail_count + 1))
            continue
        }

        if [ "$target" = "$DELETE_MARKER" ]; then
            expected_normalized="$UNSET_MARKER"
        else
            expected_normalized=$(normalize_value "$target")
        fi

        if [ "$current_value" = "$expected_normalized" ]; then
            print_operation_result "[SAME]" "$operation_key" "$(display_value "$current_value")" "$operation_key_width"
            same_count=$((same_count + 1))
        else
            print_operation_result "[CHANGE]" "$operation_key" "$(display_value "$current_value") -> $(display_target_value "$target")" "$operation_key_width"
            changed_count=$((changed_count + 1))
        fi
    done

    ui_status_line "Change:" "$changed_count"
    ui_status_line "No change:" "$same_count"
    ui_status_line "Read fail:" "$read_fail_count"

    [ "$read_fail_count" -eq 0 ] && return "$RC_OK"
    return "$RC_OPERATION_FAILED"
}

create_operation_interactive() {
    local operation_input
    local operation_name
    local operation_file
    local tmp_file
    local confirm
    local kind_choice
    local kind
    local value_type_choice
    local value_type
    local prompt_rc
    local namespace
    local key
    local target
    local -a entries
    local entry

    ui_prompt_input "Operation name: " operation_input
    operation_name=$(sanitize_operation_name "$operation_input")

    if ! is_valid_operation_name "$operation_name"; then
        ui_print "Operation name must use [A-Za-z0-9._-] and be 1-64 chars."
        return "$RC_GENERIC_ERROR"
    fi

    operation_file=$(operation_file_path "$operation_name")
    if [ -e "$operation_file" ]; then
        ui_prompt_input "Operation already exists. Overwrite? (y/N): " confirm
        is_yes_response "$confirm" || return "$RC_CANCELLED"
    fi

    ui_print "Add operation entries."
    while true; do
        ui_header "Create Operation Entry"
        ui_option "1" "device_config"
        ui_option "2" "settings"
        ui_option "3" "Finish"
        ui_option "4" "Cancel"
        kind_choice=$(prompt_number_in_range "Select kind: " 1 4)
        prompt_rc=$?
        [ "$prompt_rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"

        case "$kind_choice" in
            1) kind="device_config" ;;
            2) kind="settings" ;;
            3) break ;;
            4) return "$RC_CANCELLED" ;;
        esac

        ui_prompt_input "Namespace: " namespace
        ui_prompt_input "Key: " key

        ui_option "1" "string"
        ui_option "2" "int"
        ui_option "3" "bool"
        ui_option "4" "delete"
        value_type_choice=$(prompt_number_in_range "Select value type: " 1 4)
        prompt_rc=$?
        [ "$prompt_rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"

        case "$value_type_choice" in
            1) value_type="string" ;;
            2) value_type="int" ;;
            3) value_type="bool" ;;
            4) value_type="delete" ;;
        esac

        if [ "$value_type" = "delete" ]; then
            target="$DELETE_MARKER"
            ui_print "Target value: $DELETE_MARKER"
        else
            ui_prompt_input "Target value: " target
        fi

        namespace=$(trim_output "$namespace")
        key=$(trim_output "$key")
        target=$(trim_output "$target")
        value_type=$(trim_output "$value_type")

        if [ -z "$namespace" ] || [ -z "$key" ] || [ -z "$target" ]; then
            ui_print "Namespace, key, target are required."
            continue
        fi

        if ui_printf '%s' "$namespace" | grep -q '[|]' || ui_printf '%s' "$key" | grep -q '[|]' || ui_printf '%s' "$target" | grep -q '[|]' || ui_printf '%s' "$value_type" | grep -q '[|]'; then
            ui_print "Namespace, key, value_type, target cannot contain '|'."
            continue
        fi

        validate_operation_value_by_type "$value_type" "$target" || {
            ui_print "Invalid typed target: $kind|$namespace|$key|$value_type|$target"
            continue
        }

        entries+=("$kind|$namespace|$key|$value_type|$target")
    done

    [ "${#entries[@]}" -gt 0 ] || {
        ui_print "No entries added."
        return "$RC_CANCELLED"
    }

    tmp_file="$operation_file.tmp.$$"
    {
        ui_printf '# operation=%s\n' "$operation_name"
        ui_printf '# version=2\n'
        ui_printf '# format=kind|namespace|key|value_type|target\n'
        for entry in "${entries[@]}"; do
            ui_printf '%s\n' "$entry"
        done
    } > "$tmp_file" || {
        rm -f "$tmp_file"
        ui_print "Failed to write operation file."
        return "$RC_GENERIC_ERROR"
    }

    if ! mv "$tmp_file" "$operation_file"; then
        rm -f "$tmp_file"
        ui_print "Failed to finalize operation file."
        return "$RC_GENERIC_ERROR"
    fi

    ui_print "Created operation: $(basename "$operation_file")"
    return "$RC_OK"
}

delete_operation_interactive() {
    local operation_file
    local rc
    local confirm

    operation_file=$(select_operation_file)
    rc=$?
    [ "$rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"
    [ "$rc" -eq "$RC_OK" ] || return "$RC_GENERIC_ERROR"

    ui_prompt_input "Delete $(basename "$operation_file")? (y/N): " confirm
    is_yes_response "$confirm" || return "$RC_CANCELLED"

    rm -f "$operation_file" || {
        ui_print "Failed to delete operation file."
        return "$RC_GENERIC_ERROR"
    }

    ui_print "Deleted operation: $(basename "$operation_file")"
    return "$RC_OK"
}

rollback_transaction() {
    local start_index="$1"
    local -n ops_ref="$2"
    local -n originals_ref="$3"
    local rollback_index
    local rollback_failed=0
    local kind
    local namespace
    local key
    local target
    local operation_key
    local operation_key_width

    operation_key_width=$(get_operation_key_width ops_ref)
    for ((rollback_index=start_index; rollback_index>=0; rollback_index--)); do
        [ -z "${originals_ref[$rollback_index]+x}" ] && continue

        IFS='|' read -r kind namespace key target <<< "${ops_ref[$rollback_index]}"
        operation_key=$(get_operation_key "$kind" "$namespace" "$key")

        if restore_original_value "$kind" "$namespace" "$key" "${originals_ref[$rollback_index]}"; then
            print_operation_result "[ROLLBACK]" "$operation_key" "$(display_value "${originals_ref[$rollback_index]}")" "$operation_key_width"
        else
            print_operation_result "[ROLLBACK-FAIL]" "$operation_key" "could not restore $(display_value "${originals_ref[$rollback_index]}")" "$operation_key_width"
            rollback_failed=1
        fi
    done

    [ "$rollback_failed" -eq 0 ] && return "$RC_OK"
    return "$RC_ROLLBACK_FAILED"
}

execute_transaction() {
    local action_name="$1"
    local alias="$2"
    local mode="$3"
    local -n operations_ref="$4"
    local run_mode="${5:-execute}"
    local source_snapshot="${6:-unknown}"
    local backup_file
    local -a original_values
    local index
    local kind
    local namespace
    local key
    local target
    local operation_key
    local current_value
    local command_output
    local verified_value
    local expected_normalized
    local rollback_rc
    local lock_acquired=0
    local operation_key_width

    if [ "$run_mode" = "dry-run" ]; then
        ui_print "$action_name dry-run started."
    else
        acquire_alias_lock "$alias" || return $?
        lock_acquired=1

        backup_file=$(backup_snapshot "$alias" "$mode" operations_ref "$source_snapshot" 2>&1) || {
            ui_print "Automatic backup failed: $backup_file"
            release_alias_lock
            lock_acquired=0
            return "$RC_BACKUP_FAILED"
        }

        ui_print "Automatic backup created: $backup_file"
        ui_print "$action_name transaction started."
    fi

    operation_key_width=$(get_operation_key_width operations_ref)
    for index in "${!operations_ref[@]}"; do
        IFS='|' read -r kind namespace key target <<< "${operations_ref[$index]}"
        operation_key=$(get_operation_key "$kind" "$namespace" "$key")

        current_value=$(get_current_value "$kind" "$namespace" "$key" 2>&1) || {
            print_operation_result "[FAIL]" "$operation_key" "failed to read current value: $current_value" "$operation_key_width"
            [ "$run_mode" != "dry-run" ] && [ "$index" -gt 0 ] && {
                ui_print "Rolling back..."
                rollback_transaction $((index - 1)) operations_ref original_values
                rollback_rc=$?
                if [ "$rollback_rc" -ne "$RC_OK" ]; then
                    ui_print "Rollback completed with failures."
                    [ "$lock_acquired" -eq 1 ] && release_alias_lock
                    return "$RC_ROLLBACK_FAILED"
                fi
            }
            [ "$lock_acquired" -eq 1 ] && release_alias_lock
            return "$RC_OPERATION_FAILED"
        }

        original_values[$index]="$current_value"

        if [ "$run_mode" = "dry-run" ]; then
            if [ "$target" = "$DELETE_MARKER" ]; then
                expected_normalized="$UNSET_MARKER"
            else
                expected_normalized=$(normalize_value "$target")
            fi

            if [ "$current_value" = "$expected_normalized" ]; then
                print_operation_result "[DRY-RUN]" "$operation_key" "no change ($(display_value "$current_value"))" "$operation_key_width"
            else
                print_operation_result "[DRY-RUN]" "$operation_key" "$(display_value "$current_value") -> $(display_target_value "$target")" "$operation_key_width"
            fi
            continue
        fi

        command_output=$(set_remote_value "$kind" "$namespace" "$key" "$target" 2>&1) || {
            if [ -z "$command_output" ]; then
                command_output="command failed"
            fi
            print_operation_result "[FAIL]" "$operation_key" "$command_output" "$operation_key_width"
            ui_print "Rolling back..."
            rollback_transaction "$index" operations_ref original_values
            rollback_rc=$?
            [ "$lock_acquired" -eq 1 ] && release_alias_lock
            if [ "$rollback_rc" -ne "$RC_OK" ]; then
                ui_print "Rollback completed with failures."
                return "$RC_ROLLBACK_FAILED"
            fi
            return "$RC_OPERATION_FAILED"
        }

        verified_value=$(verify_remote_value "$kind" "$namespace" "$key" "$target" 2>&1) || {
            print_operation_result "[FAIL]" "$operation_key" "$verified_value" "$operation_key_width"
            ui_print "Rolling back..."
            rollback_transaction "$index" operations_ref original_values
            rollback_rc=$?
            [ "$lock_acquired" -eq 1 ] && release_alias_lock
            if [ "$rollback_rc" -ne "$RC_OK" ]; then
                ui_print "Rollback completed with failures."
                return "$RC_ROLLBACK_FAILED"
            fi
            return "$RC_OPERATION_FAILED"
        }

        print_operation_result "[OK]" "$operation_key" "$(display_value "$verified_value")" "$operation_key_width"
    done

    if [ "$run_mode" = "dry-run" ]; then
        ui_print "$action_name dry-run completed. No changes applied."
    else
        ui_print "$action_name transaction completed successfully."
        [ "$lock_acquired" -eq 1 ] && release_alias_lock
    fi

    return "$RC_OK"
}

execute_operation() {
    local alias
    local operation_file
    local rc
    local operation_name
    local mode_key
    local operation_spec
    local load_error
    local run_mode
    local prompt_rc
    local confirm
    local -a operations

    ensure_adb_installed || {
        ui_print "ADB is not installed."
        return "$RC_ADB_NOT_INSTALLED"
    }

    ensure_device_connected || {
        ui_print "No device connected."
        return "$RC_NO_DEVICE"
    }

    ensure_alias_for_selected_device || return "$RC_ALIAS_RESOLUTION_FAILED"
    alias="$CURRENT_ALIAS"
    operation_file=$(select_operation_file)
    rc=$?
    [ "$rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"
    [ "$rc" -eq "$RC_OK" ] || return "$RC_GENERIC_ERROR"

    operation_name=$(basename "$operation_file" .op)
    mode_key=$(sanitize_operation_name "$operation_name")

    operation_spec=$(load_operation_spec "$operation_file" 2>&1) || {
        load_error="$operation_spec"
        ui_print "Failed to read operation: $operation_file"
        [ -n "$load_error" ] && ui_print "Reason: $load_error"
        return "$RC_GENERIC_ERROR"
    }
    mapfile -t operations <<< "$operation_spec"

    run_mode=$(prompt_execution_mode)
    prompt_rc=$?
    [ "$prompt_rc" -eq "$RC_CANCELLED" ] && {
        ui_print "Cancelled."
        return "$RC_CANCELLED"
    }
    [ "$run_mode" = "cancel" ] && {
        ui_print "Cancelled."
        return "$RC_CANCELLED"
    }

    show_operation_preview "Operation preview: $operation_name" operations

    if [ "$run_mode" = "execute" ]; then
        show_pre_execution_diff "Pre-execution diff: $operation_name" operations || {
            ui_print "Pre-execution diff failed due to read errors."
            return "$RC_OPERATION_FAILED"
        }
        ui_prompt_input "Proceed with execute? (y/N): " confirm
        is_yes_response "$confirm" || return "$RC_CANCELLED"
    fi

    execute_transaction "OPERATION ($operation_name)" "$alias" "operation-$mode_key" operations "$run_mode"
    return $?
}

show_operation_entries_interactive() {
    local operation_file
    local rc
    local operation_name
    local operation_spec
    local load_error
    local -a operations

    operation_file=$(select_operation_file)
    rc=$?
    [ "$rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"
    if [ "$rc" -ne "$RC_OK" ]; then
        ui_pause
        return "$rc"
    fi

    operation_name=$(basename "$operation_file" .op)
    operation_spec=$(load_operation_spec "$operation_file" 2>&1) || {
        load_error="$operation_spec"
        ui_print "Failed to read operation: $operation_file"
        [ -n "$load_error" ] && ui_print "Reason: $load_error"
        ui_pause
        return "$RC_CANCELLED"
    }
    mapfile -t operations <<< "$operation_spec"

    show_operation_preview "Operation entries: $operation_name" operations "0"
    ui_pause
    return "$RC_OK"
}

lint_operation_spec() {
    local operation_file="$1"
    local operation_name
    local operation_spec
    local line
    local kind
    local namespace
    local key
    local target
    local key_id
    local status="$RC_OK"
    local duplicate_count=0
    local lint_subject_width=1
    local -a key_ids=()
    local -a duplicate_keys=()

    operation_name=$(basename "$operation_file" .op)
    if [ "${#operation_name}" -gt "$lint_subject_width" ]; then
        lint_subject_width=${#operation_name}
    fi
    operation_spec=$(load_operation_spec "$operation_file" 2>&1) || {
        print_lint_result "[LINT][FAIL]" "$operation_name" "$operation_spec" "$lint_subject_width"
        return "$RC_GENERIC_ERROR"
    }

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        IFS='|' read -r kind namespace key target <<< "$line"
        key_id="$kind|$namespace|$key"
        if [ "${#key_id}" -gt "$lint_subject_width" ]; then
            lint_subject_width=${#key_id}
        fi
        if ui_printf '%s\n' "${key_ids[@]}" | grep -Fxq "$key_id"; then
            duplicate_keys+=("$key_id")
            duplicate_count=$((duplicate_count + 1))
            status="$RC_GENERIC_ERROR"
            continue
        fi
        key_ids+=("$key_id")
    done <<< "$operation_spec"

    for key_id in "${duplicate_keys[@]}"; do
        print_lint_result "[LINT][WARN]" "$key_id" "duplicate key" "$lint_subject_width"
    done

    if [ "$status" -eq "$RC_OK" ]; then
        print_lint_result "[LINT][OK]" "$operation_name" "entries=${#key_ids[@]}" "$lint_subject_width"
    else
        print_lint_result "[LINT][FAIL]" "$operation_name" "duplicate_keys=$duplicate_count" "$lint_subject_width"
    fi

    return "$status"
}

lint_operation_interactive() {
    local operation_file
    local rc
    local lint_rc

    operation_file=$(select_operation_file)
    rc=$?
    [ "$rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"
    if [ "$rc" -ne "$RC_OK" ]; then
        ui_pause
        return "$rc"
    fi

    lint_operation_spec "$operation_file"
    lint_rc=$?
    ui_pause
    return "$lint_rc"
}

run_snapshot_restore_flow() {
    local snapshot_file="$1"
    local alias="$2"
    local flow_mode="${3:-normal}"
    local forced_run_mode="${4:-}"
    local non_interactive="${5:-0}"
    local snapshot_kind
    local run_mode
    local prompt_rc
    local operation_spec
    local confirm
    local -a operations

    show_snapshot_metadata "$snapshot_file"

    if [ "$flow_mode" != "auto-shortcut" ]; then
        if [ "$non_interactive" = "1" ]; then
            snapshot_kind=$(snapshot_metadata_value "$snapshot_file" "snapshot")
            case "$snapshot_kind" in
                restore-snapshot|auto-pre-restore)
                    ui_print "Refusing non-interactive restore for automatic pre-restore snapshot: $(basename "$snapshot_file")"
                    return "$RC_CANCELLED"
                    ;;
            esac
        else
            guard_restore_snapshot_loop "$snapshot_file" || {
                ui_print "Restore cancelled."
                return "$RC_CANCELLED"
            }
        fi
    fi

    if [ "$non_interactive" = "1" ]; then
        if ! confirm_snapshot_target_compatibility_non_interactive "$snapshot_file"; then
            return "$RC_CANCELLED"
        fi
    else
        confirm_snapshot_target_compatibility "$snapshot_file" || {
            ui_print "Restore cancelled."
            return "$RC_CANCELLED"
        }
    fi

    operation_spec=$(load_snapshot_operations "$snapshot_file") || {
        ui_print "Failed to load snapshot: $snapshot_file"
        return "$RC_SNAPSHOT_INVALID"
    }
    mapfile -t operations <<< "$operation_spec"
    show_operation_preview "Snapshot operation preview: $(basename "$snapshot_file")" operations

    if [ -n "$forced_run_mode" ]; then
        run_mode="$forced_run_mode"
    else
        run_mode=$(prompt_execution_mode)
        prompt_rc=$?
        [ "$prompt_rc" -eq "$RC_CANCELLED" ] && {
            ui_print "Cancelled."
            return "$RC_CANCELLED"
        }
        [ "$run_mode" = "cancel" ] && {
            ui_print "Cancelled."
            return "$RC_CANCELLED"
        }
    fi

    if [ "$run_mode" = "execute" ]; then
        show_pre_execution_diff "Pre-execution diff: $(basename "$snapshot_file")" operations || {
            ui_print "Pre-execution diff failed due to read errors."
            return "$RC_OPERATION_FAILED"
        }
        if [ "$non_interactive" != "1" ]; then
            ui_prompt_input "Proceed with snapshot restore? (y/N): " confirm
            is_yes_response "$confirm" || return "$RC_CANCELLED"
        fi
    fi

    execute_transaction "RESTORE SNAPSHOT ($(basename "$snapshot_file"))" "$alias" "auto-pre-restore" operations "$run_mode" "$(basename "$snapshot_file")"
    return $?
}

find_latest_auto_snapshot_for_alias() {
    local alias="$1"
    local dir="$STATE_DIR/$alias/backups"
    local snapshot_file
    local snapshot_kind
    local -a snapshots

    [ -d "$dir" ] || return "$RC_GENERIC_ERROR"
    mapfile -t snapshots < <(list_snapshot_files_sorted "$alias")
    [ "${#snapshots[@]}" -gt 0 ] || return "$RC_GENERIC_ERROR"

    for snapshot_file in "${snapshots[@]}"; do
        snapshot_kind=$(snapshot_metadata_value "$dir/$snapshot_file" "snapshot")
        case "$snapshot_kind" in
            operation-*|auto-pre-restore|restore-snapshot)
                ui_printf '%s' "$dir/$snapshot_file"
                return "$RC_OK"
                ;;
        esac
    done

    return "$RC_GENERIC_ERROR"
}

restore_snapshot_operation() {
    local alias
    local snapshot_file
    local rc

    ensure_adb_installed || {
        ui_print "ADB is not installed."
        return "$RC_ADB_NOT_INSTALLED"
    }

    ensure_device_connected || {
        ui_print "No device connected."
        return "$RC_NO_DEVICE"
    }

    ensure_alias_for_selected_device || return "$RC_ALIAS_RESOLUTION_FAILED"
    alias="$CURRENT_ALIAS"

    snapshot_file=$(select_snapshot_file "$alias")
    rc=$?
    [ "$rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"
    [ "$rc" -eq "$RC_OK" ] || return "$RC_GENERIC_ERROR"

    run_snapshot_restore_flow "$snapshot_file" "$alias" "normal"
    return $?
}

restore_last_auto_backup_operation() {
    local alias
    local snapshot_file

    ensure_adb_installed || {
        ui_print "ADB is not installed."
        return "$RC_ADB_NOT_INSTALLED"
    }

    ensure_device_connected || {
        ui_print "No device connected."
        return "$RC_NO_DEVICE"
    }

    ensure_alias_for_selected_device || return "$RC_ALIAS_RESOLUTION_FAILED"
    alias="$CURRENT_ALIAS"

    snapshot_file=$(find_latest_auto_snapshot_for_alias "$alias") || {
        ui_print "No automatic backup snapshot found for alias: $alias"
        return "$RC_GENERIC_ERROR"
    }

    ui_print "Selected latest auto snapshot: $(basename "$snapshot_file")"
    run_snapshot_restore_flow "$snapshot_file" "$alias" "auto-shortcut"
    return $?
}

show_snapshot_entries_interactive() {
    local alias
    local snapshot_file
    local rc
    local operation_spec
    local -a operations

    alias=$(select_snapshot_alias_for_view)
    rc=$?
    [ "$rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"
    if [ "$rc" -ne "$RC_OK" ]; then
        ui_pause
        return "$RC_CANCELLED"
    fi

    snapshot_file=$(select_snapshot_file_for_view "$alias")
    rc=$?
    [ "$rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"
    if [ "$rc" -ne "$RC_OK" ]; then
        ui_pause
        return "$RC_CANCELLED"
    fi

    show_snapshot_metadata "$snapshot_file"

    operation_spec=$(load_snapshot_operations "$snapshot_file") || {
        ui_print "Failed to load snapshot: $snapshot_file"
        ui_pause
        return "$RC_CANCELLED"
    }
    mapfile -t operations <<< "$operation_spec"

    show_operation_preview "Snapshot entries: $(basename "$snapshot_file")" operations "0"
    ui_pause
    return "$RC_OK"
}

run_menu_action() {
    local action_fn="$1"
    local pause_on_success="${2:-0}"
    local action_rc

    "$action_fn"
    action_rc=$?
    if [ "$action_rc" -eq "$RC_OK" ] && [ "$pause_on_success" -eq 1 ]; then
        ui_pause
    fi
    return "$action_rc"
}

snapshot_menu() {
    local choice
    local rc
    local prompt_rc

    while true; do
        ui_header "Snapshot Menu"
        ui_option "1" "Restore Snapshot"
        ui_option "2" "View Entries"
        ui_option "3" "Restore Last Auto Backup"
        ui_option "4" "Restore Checkpoint"
        ui_option "5" "Back"
        choice=$(prompt_number_in_range "Select: " 1 5)
        prompt_rc=$?
        [ "$prompt_rc" -eq "$RC_CANCELLED" ] && continue

        case "$choice" in
            1) run_menu_action restore_snapshot_operation 1 ;;
            2) run_menu_action show_snapshot_entries_interactive 0 ;;
            3) run_menu_action restore_last_auto_backup_operation 1 ;;
            4) run_menu_action restore_checkpoint_interactive 1 ;;
            5) return "$RC_OK" ;;
        esac

        rc=$?
        if [ "$rc" -ne "$RC_OK" ] && [ "$rc" -ne "$RC_CANCELLED" ]; then
            ui_print "Snapshot operation failed (code: $rc)."
            ui_pause
        fi
    done
}

count_files_in_dir_recursive() {
    local dir="$1"
    [ -d "$dir" ] || {
        ui_printf '0'
        return 0
    }
    find "$dir" -type f 2>/dev/null | wc -l | tr -d ' '
}

show_alias_state_summary() {
    local alias="$1"
    local dir="$STATE_DIR/$alias"
    local snapshot_count
    local file_count
    local effective_limit
    local configured_limit

    snapshot_count=$(count_snapshot_files_for_alias "$alias")
    file_count=$(count_files_in_dir_recursive "$dir")
    effective_limit=$(get_backup_limit_for_alias "$alias")
    configured_limit=$(get_configured_backup_limit_for_alias "$alias" 2>/dev/null || true)

    ui_status_line "Alias:" "$alias"
    ui_status_line "Snapshots:" "$snapshot_count"
    ui_status_line "Files:" "$file_count"
    if [ -n "$configured_limit" ]; then
        ui_status_line "BackupLimit:" "$effective_limit (override)"
    else
        ui_status_line "BackupLimit:" "$effective_limit (default)"
    fi
}

prompt_keyword_confirmation() {
    local keyword="$1"
    local input

    ui_prompt_input "Type '$keyword' to continue: " input
    input=$(trim_output "$input")
    [ "$input" = "$keyword" ] || return "$RC_CANCELLED"

    ui_prompt_input "Final confirm? (y/N): " input
    is_yes_response "$input" || return "$RC_CANCELLED"
    return "$RC_OK"
}

restore_checkpoint_dir() {
    local checkpoint_dir="$1"
    local pre_checkpoint
    local txn_dir
    local alias_dir
    local alias_name
    local dst_dir
    local rollback_dir

    [ -d "$checkpoint_dir" ] || {
        ui_print "Checkpoint not found: $checkpoint_dir"
        return "$RC_GENERIC_ERROR"
    }

    pre_checkpoint=$(create_alias_management_checkpoint "before-restore-checkpoint" $(list_aliases_for_management)) || {
        ui_print "Failed to create pre-restore checkpoint."
        return "$RC_GENERIC_ERROR"
    }
    ui_print "Pre-restore checkpoint: $pre_checkpoint"

    txn_dir=$(prepare_alias_txn_dir "restore-checkpoint")
    [ -n "$txn_dir" ] || {
        ui_print "Failed to prepare restore transaction directory."
        return "$RC_GENERIC_ERROR"
    }

    if [ -f "$checkpoint_dir/device_alias_map.tsv" ]; then
        cp -a "$checkpoint_dir/device_alias_map.tsv" "$txn_dir/device_alias_map.tsv" || {
            ui_print "Failed to stage alias map from checkpoint."
            rm -rf "$txn_dir"
            return "$RC_GENERIC_ERROR"
        }
    fi

    if [ -f "$checkpoint_dir/alias_backup_limit.tsv" ]; then
        cp -a "$checkpoint_dir/alias_backup_limit.tsv" "$txn_dir/alias_backup_limit.tsv" || {
            ui_print "Failed to stage backup limit map from checkpoint."
            rm -rf "$txn_dir"
            return "$RC_GENERIC_ERROR"
        }
    fi

    if [ -d "$checkpoint_dir/aliases" ]; then
        mkdir -p "$txn_dir/aliases" || {
            ui_print "Failed to create staged alias directory."
            rm -rf "$txn_dir"
            return "$RC_GENERIC_ERROR"
        }
        for alias_dir in "$checkpoint_dir"/aliases/*; do
            [ -d "$alias_dir" ] || continue
            cp -a "$alias_dir" "$txn_dir/aliases/" || {
                ui_print "Failed to stage alias from checkpoint: $(basename "$alias_dir")"
                rm -rf "$txn_dir"
                return "$RC_GENERIC_ERROR"
            }
        done
    fi

    if [ -f "$txn_dir/device_alias_map.tsv" ]; then
        mv "$txn_dir/device_alias_map.tsv" "$ALIAS_MAP_FILE" || {
            ui_print "Failed to restore alias map from checkpoint."
            rm -rf "$txn_dir"
            return "$RC_GENERIC_ERROR"
        }
    fi

    if [ -f "$txn_dir/alias_backup_limit.tsv" ]; then
        mv "$txn_dir/alias_backup_limit.tsv" "$ALIAS_BACKUP_LIMIT_FILE" || {
            ui_print "Failed to restore backup limit map from checkpoint."
            rm -rf "$txn_dir"
            return "$RC_GENERIC_ERROR"
        }
    fi

    if [ -d "$txn_dir/aliases" ]; then
        for alias_dir in "$txn_dir"/aliases/*; do
            [ -d "$alias_dir" ] || continue
            alias_name=$(basename "$alias_dir")
            dst_dir="$STATE_DIR/$alias_name"
            rollback_dir=""
            if [ -e "$dst_dir" ]; then
                rollback_dir="$txn_dir/${alias_name}.old"
                mv "$dst_dir" "$rollback_dir" || {
                    ui_print "Failed to stage existing alias for restore rollback: $alias_name"
                    rm -rf "$txn_dir"
                    return "$RC_GENERIC_ERROR"
                }
            fi
            mv "$alias_dir" "$dst_dir" || {
                ui_print "Failed to restore alias state: $alias_name"
                if [ -n "$rollback_dir" ] && [ -d "$rollback_dir" ]; then
                    mv "$rollback_dir" "$dst_dir" >/dev/null 2>&1 || true
                fi
                rm -rf "$txn_dir"
                return "$RC_GENERIC_ERROR"
            }
        done
    fi

    rm -rf "$txn_dir"
    refresh_pairing_state
    refresh_context_for_selected_device >/dev/null 2>&1 || true
    ui_print "Checkpoint restored: $(basename "$checkpoint_dir")"
    return "$RC_OK"
}

restore_checkpoint_interactive() {
    local checkpoint_dir
    local rc

    checkpoint_dir=$(select_checkpoint_dir)
    rc=$?
    [ "$rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"
    [ "$rc" -eq "$RC_OK" ] || return "$RC_GENERIC_ERROR"

    ui_header "Restore Checkpoint Preview"
    ui_status_line "Checkpoint:" "$(basename "$checkpoint_dir")"
    prompt_keyword_confirmation "RESTORE" || return "$RC_CANCELLED"

    restore_checkpoint_dir "$checkpoint_dir"
    return $?
}

create_alias_management_checkpoint() {
    local action_label="$1"
    shift
    local checkpoint_root="$STATE_DIR/_checkpoints"
    local timestamp
    local safe_label
    local checkpoint_dir
    local alias

    mkdir -p "$checkpoint_root" || return "$RC_GENERIC_ERROR"
    timestamp=$(date +"%Y%m%d_%H%M%S")
    safe_label=$(sanitize_alias "$action_label")
    checkpoint_dir=$(ensure_unique_path_with_index_suffix "$checkpoint_root" "$timestamp-$safe_label")
    mkdir -p "$checkpoint_dir/aliases" || return "$RC_GENERIC_ERROR"

    [ -f "$ALIAS_MAP_FILE" ] && cp -a "$ALIAS_MAP_FILE" "$checkpoint_dir/" || true
    [ -f "$ALIAS_BACKUP_LIMIT_FILE" ] && cp -a "$ALIAS_BACKUP_LIMIT_FILE" "$checkpoint_dir/" || true

    for alias in "$@"; do
        [ -n "$alias" ] || continue
        if [ -d "$STATE_DIR/$alias" ]; then
            cp -a "$STATE_DIR/$alias" "$checkpoint_dir/aliases/" || return "$RC_GENERIC_ERROR"
        fi
    done

    ui_printf '%s' "$checkpoint_dir"
}

rename_alias_interactive() {
    local old_alias
    local new_alias_input
    local new_alias
    local src_dir
    local dst_dir
    local checkpoint_dir
    local txn_dir
    local staged_dir=""
    local staged_map
    local staged_limit

    old_alias=$(select_alias_for_management "Select alias to rename: ")
    case $? in
        "$RC_CANCELLED") return "$RC_CANCELLED" ;;
        "$RC_OK") ;;
        *) return "$RC_GENERIC_ERROR" ;;
    esac

    ui_prompt_input "New alias: " new_alias_input
    new_alias=$(sanitize_alias "$new_alias_input")

    if ! is_valid_alias "$new_alias"; then
        ui_print "Alias must use [A-Za-z0-9._-] and be 1-64 chars."
        return "$RC_GENERIC_ERROR"
    fi

    if [ "$new_alias" = "$old_alias" ]; then
        ui_print "Alias is unchanged."
        return "$RC_CANCELLED"
    fi

    if list_aliases_for_management | grep -Fxq "$new_alias"; then
        ui_print "Alias already exists: $new_alias"
        return "$RC_GENERIC_ERROR"
    fi

    ui_header "Rename Alias Preview"
    show_alias_state_summary "$old_alias"
    ui_status_line "RenameTo:" "$new_alias"
    prompt_keyword_confirmation "RENAME" || return "$RC_CANCELLED"

    checkpoint_dir=$(create_alias_management_checkpoint "rename-$old_alias-to-$new_alias" "$old_alias") || {
        ui_print "Failed to create rollback checkpoint."
        return "$RC_GENERIC_ERROR"
    }
    ui_print "Rollback checkpoint: $checkpoint_dir"

    txn_dir=$(prepare_alias_txn_dir "rename-$old_alias-to-$new_alias")
    [ -n "$txn_dir" ] || {
        ui_print "Failed to prepare transaction directory."
        return "$RC_GENERIC_ERROR"
    }

    staged_map="$txn_dir/device_alias_map.tsv"
    staged_limit="$txn_dir/alias_backup_limit.tsv"
    stage_alias_map_rename "$old_alias" "$new_alias" "$staged_map" || {
        ui_print "Failed to stage alias map update."
        rm -rf "$txn_dir"
        return "$RC_GENERIC_ERROR"
    }
    stage_alias_limit_rename "$old_alias" "$new_alias" "$staged_limit" || {
        ui_print "Failed to stage backup limit map update."
        rm -rf "$txn_dir"
        return "$RC_GENERIC_ERROR"
    }

    src_dir="$STATE_DIR/$old_alias"
    dst_dir="$STATE_DIR/$new_alias"
    if [ -d "$src_dir" ]; then
        if [ -e "$dst_dir" ]; then
            ui_print "Target alias directory already exists: $dst_dir"
            rm -rf "$txn_dir"
            return "$RC_GENERIC_ERROR"
        fi
        mv "$src_dir" "$txn_dir/$new_alias" || {
            ui_print "Failed to stage alias state directory for rename."
            rm -rf "$txn_dir"
            return "$RC_GENERIC_ERROR"
        }
        staged_dir="$txn_dir/$new_alias"
    fi

    if [ -n "$staged_dir" ]; then
        mv "$staged_dir" "$dst_dir" || {
            ui_print "Failed to commit alias state rename."
            if [ -d "$staged_dir" ] && [ ! -e "$src_dir" ]; then
                mv "$staged_dir" "$src_dir" >/dev/null 2>&1 || true
            fi
            rm -rf "$txn_dir"
            return "$RC_GENERIC_ERROR"
        }
    fi

    if ! mv "$staged_map" "$ALIAS_MAP_FILE"; then
        ui_print "Failed to commit alias map update. Restore from: $checkpoint_dir"
        if [ -d "$dst_dir" ] && [ ! -e "$src_dir" ]; then
            mv "$dst_dir" "$src_dir" >/dev/null 2>&1 || true
        fi
        rm -rf "$txn_dir"
        return "$RC_GENERIC_ERROR"
    fi

    if ! mv "$staged_limit" "$ALIAS_BACKUP_LIMIT_FILE"; then
        ui_print "Alias renamed but failed to commit backup limit map. Restore from: $checkpoint_dir"
        rm -rf "$txn_dir"
        return "$RC_GENERIC_ERROR"
    fi

    rm -rf "$txn_dir"

    if [ "$CURRENT_ALIAS" = "$old_alias" ]; then
        CURRENT_ALIAS="$new_alias"
    fi

    ui_print "Alias renamed: $old_alias -> $new_alias"
    return "$RC_OK"
}

merge_alias_interactive() {
    local source_alias
    local target_alias
    local source_dir
    local target_dir
    local moved_count=0
    local checkpoint_dir
    local txn_dir
    local staged_map
    local staged_limit
    local staged_target_orig=""
    local staged_source_orig=""
    local merged_dir
    local before_count

    source_alias=$(select_alias_for_management "Select source alias (merge from): ")
    case $? in
        "$RC_CANCELLED") return "$RC_CANCELLED" ;;
        "$RC_OK") ;;
        *) return "$RC_GENERIC_ERROR" ;;
    esac

    target_alias=$(select_alias_for_management "Select target alias (merge to): " "$source_alias")
    case $? in
        "$RC_CANCELLED") return "$RC_CANCELLED" ;;
        "$RC_OK") ;;
        *) return "$RC_GENERIC_ERROR" ;;
    esac

    ui_header "Merge Alias Preview"
    show_alias_state_summary "$source_alias"
    ui_divider
    show_alias_state_summary "$target_alias"
    prompt_keyword_confirmation "MERGE" || return "$RC_CANCELLED"

    checkpoint_dir=$(create_alias_management_checkpoint "merge-$source_alias-to-$target_alias" "$source_alias" "$target_alias") || {
        ui_print "Failed to create rollback checkpoint."
        return "$RC_GENERIC_ERROR"
    }
    ui_print "Rollback checkpoint: $checkpoint_dir"

    source_dir="$STATE_DIR/$source_alias"
    target_dir="$STATE_DIR/$target_alias"
    before_count=$(count_snapshot_files_for_alias "$target_alias")

    txn_dir=$(prepare_alias_txn_dir "merge-$source_alias-to-$target_alias")
    [ -n "$txn_dir" ] || {
        ui_print "Failed to prepare transaction directory."
        return "$RC_GENERIC_ERROR"
    }

    staged_map="$txn_dir/device_alias_map.tsv"
    staged_limit="$txn_dir/alias_backup_limit.tsv"
    stage_alias_map_remove "$source_alias" "$staged_map" || {
        ui_print "Failed to stage alias map update."
        rm -rf "$txn_dir"
        return "$RC_GENERIC_ERROR"
    }
    stage_alias_limit_remove "$source_alias" "$staged_limit" || {
        ui_print "Failed to stage backup limit map update."
        rm -rf "$txn_dir"
        return "$RC_GENERIC_ERROR"
    }

    merged_dir="$txn_dir/${target_alias}.merged"
    mkdir -p "$merged_dir" || {
        ui_print "Failed to create merged transaction directory."
        rm -rf "$txn_dir"
        return "$RC_GENERIC_ERROR"
    }

    if [ -d "$target_dir" ]; then
        staged_target_orig="$txn_dir/${target_alias}.orig"
        mv "$target_dir" "$staged_target_orig" || {
            ui_print "Failed to stage target alias state."
            rm -rf "$txn_dir"
            return "$RC_GENERIC_ERROR"
        }
        move_dir_children_with_suffix "$staged_target_orig" "$merged_dir" || {
            ui_print "Failed to build merged state from target alias."
            [ -d "$staged_target_orig" ] && mv "$staged_target_orig" "$target_dir" >/dev/null 2>&1 || true
            rm -rf "$txn_dir"
            return "$RC_GENERIC_ERROR"
        }
    fi

    if [ -d "$source_dir" ]; then
        staged_source_orig="$txn_dir/${source_alias}.orig"
        mv "$source_dir" "$staged_source_orig" || {
            ui_print "Failed to stage source alias state."
            [ -d "$staged_target_orig" ] && mv "$staged_target_orig" "$target_dir" >/dev/null 2>&1 || true
            rm -rf "$txn_dir"
            return "$RC_GENERIC_ERROR"
        }
        move_dir_children_with_suffix "$staged_source_orig" "$merged_dir" || {
            ui_print "Failed to build merged state from source alias."
            [ -d "$staged_source_orig" ] && mv "$staged_source_orig" "$source_dir" >/dev/null 2>&1 || true
            [ -d "$staged_target_orig" ] && mv "$staged_target_orig" "$target_dir" >/dev/null 2>&1 || true
            rm -rf "$txn_dir"
            return "$RC_GENERIC_ERROR"
        }
    fi

    mv "$merged_dir" "$target_dir" || {
        ui_print "Failed to commit merged alias state."
        [ -d "$staged_source_orig" ] && mv "$staged_source_orig" "$source_dir" >/dev/null 2>&1 || true
        [ -d "$staged_target_orig" ] && mv "$staged_target_orig" "$target_dir" >/dev/null 2>&1 || true
        rm -rf "$txn_dir"
        return "$RC_GENERIC_ERROR"
    }

    if ! mv "$staged_map" "$ALIAS_MAP_FILE"; then
        ui_print "Merged alias state but failed to commit alias map. Restore from: $checkpoint_dir"
        rm -rf "$txn_dir"
        return "$RC_GENERIC_ERROR"
    fi

    if ! mv "$staged_limit" "$ALIAS_BACKUP_LIMIT_FILE"; then
        ui_print "Merged alias state but failed to commit backup limit map. Restore from: $checkpoint_dir"
        rm -rf "$txn_dir"
        return "$RC_GENERIC_ERROR"
    fi

    moved_count=$(( $(count_snapshot_files_for_alias "$target_alias") - before_count ))
    [ "$moved_count" -lt 0 ] && moved_count=0
    rm -rf "$txn_dir"

    if [ "$CURRENT_ALIAS" = "$source_alias" ]; then
        CURRENT_ALIAS="$target_alias"
    fi

    ui_print "Alias merged: $source_alias -> $target_alias (moved backups: $moved_count)"
    return "$RC_OK"
}

delete_alias_interactive() {
    local alias
    local action
    local prompt_rc
    local src_dir
    local archive_root
    local archive_name
    local archive_dst
    local checkpoint_dir
    local txn_dir
    local staged_map
    local staged_limit
    local staged_alias_dir=""

    alias=$(select_alias_for_management "Select alias to delete: ")
    case $? in
        "$RC_CANCELLED") return "$RC_CANCELLED" ;;
        "$RC_OK") ;;
        *) return "$RC_GENERIC_ERROR" ;;
    esac

    ui_header "Delete Alias: $alias"
    show_alias_state_summary "$alias"
    ui_divider
    ui_option "1" "Keep backups (archive)"
    ui_option "2" "Delete backups and state"
    ui_option "3" "Cancel"
    action=$(prompt_number_in_range "Select: " 1 3)
    prompt_rc=$?
    [ "$prompt_rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"
    [ "$action" -eq 3 ] && return "$RC_CANCELLED"
    prompt_keyword_confirmation "DELETE" || return "$RC_CANCELLED"

    src_dir="$STATE_DIR/$alias"
    checkpoint_dir=$(create_alias_management_checkpoint "delete-$alias" "$alias") || {
        ui_print "Failed to create rollback checkpoint."
        return "$RC_GENERIC_ERROR"
    }
    ui_print "Rollback checkpoint: $checkpoint_dir"

    txn_dir=$(prepare_alias_txn_dir "delete-$alias")
    [ -n "$txn_dir" ] || {
        ui_print "Failed to prepare transaction directory."
        return "$RC_GENERIC_ERROR"
    }

    staged_map="$txn_dir/device_alias_map.tsv"
    staged_limit="$txn_dir/alias_backup_limit.tsv"
    stage_alias_map_remove "$alias" "$staged_map" || {
        ui_print "Failed to stage alias map update."
        rm -rf "$txn_dir"
        return "$RC_GENERIC_ERROR"
    }
    stage_alias_limit_remove "$alias" "$staged_limit" || {
        ui_print "Failed to stage backup limit map update."
        rm -rf "$txn_dir"
        return "$RC_GENERIC_ERROR"
    }

    if [ -d "$src_dir" ]; then
        staged_alias_dir="$txn_dir/$alias.staged"
        mv "$src_dir" "$staged_alias_dir" || {
            ui_print "Failed to stage alias directory for delete."
            rm -rf "$txn_dir"
            return "$RC_GENERIC_ERROR"
        }

        if [ "$action" -eq 1 ]; then
            archive_root="$STATE_DIR/_archive"
            mkdir -p "$archive_root" || {
                ui_print "Failed to create archive directory."
                [ -d "$staged_alias_dir" ] && mv "$staged_alias_dir" "$src_dir" >/dev/null 2>&1 || true
                rm -rf "$txn_dir"
                return "$RC_GENERIC_ERROR"
            }
            archive_name="${alias}-$(date +"%Y%m%d_%H%M%S")"
            archive_dst=$(ensure_unique_path_with_index_suffix "$archive_root" "$archive_name")
            mv "$staged_alias_dir" "$archive_dst" || {
                ui_print "Failed to archive alias state. Restore from: $checkpoint_dir"
                [ -d "$staged_alias_dir" ] && mv "$staged_alias_dir" "$src_dir" >/dev/null 2>&1 || true
                rm -rf "$txn_dir"
                return "$RC_GENERIC_ERROR"
            }
            ui_print "Alias deleted and archived: $archive_dst"
        else
            rm -rf "$staged_alias_dir" || {
                ui_print "Failed to delete alias state directory. Restore from: $checkpoint_dir"
                [ -d "$staged_alias_dir" ] && mv "$staged_alias_dir" "$src_dir" >/dev/null 2>&1 || true
                rm -rf "$txn_dir"
                return "$RC_GENERIC_ERROR"
            }
            ui_print "Alias deleted with backups."
        fi
    else
        ui_print "Alias mapping deleted. No state directory found."
    fi

    if ! mv "$staged_map" "$ALIAS_MAP_FILE"; then
        ui_print "Alias state deleted but failed to commit alias map. Restore from: $checkpoint_dir"
        rm -rf "$txn_dir"
        return "$RC_GENERIC_ERROR"
    fi
    if ! mv "$staged_limit" "$ALIAS_BACKUP_LIMIT_FILE"; then
        ui_print "Alias state deleted but failed to commit backup limit map. Restore from: $checkpoint_dir"
        rm -rf "$txn_dir"
        return "$RC_GENERIC_ERROR"
    fi

    rm -rf "$txn_dir"

    if [ "$CURRENT_ALIAS" = "$alias" ]; then
        CURRENT_ALIAS=""
    fi

    return "$RC_OK"
}

set_alias_backup_limit_interactive() {
    local alias
    local current_effective
    local current_override
    local input
    local normalized

    alias=$(select_alias_for_management "Select alias: ")
    case $? in
        "$RC_CANCELLED") return "$RC_CANCELLED" ;;
        "$RC_OK") ;;
        *) return "$RC_GENERIC_ERROR" ;;
    esac

    current_effective=$(get_backup_limit_for_alias "$alias")
    current_override=$(get_configured_backup_limit_for_alias "$alias" 2>/dev/null || true)

    ui_header "Alias Backup Limit"
    ui_status_line "Alias:" "$alias"
    if [ -n "$current_override" ]; then
        ui_status_line "Current:" "$current_effective (override)"
    else
        ui_status_line "Current:" "$current_effective (default)"
    fi
    ui_print "Enter positive integer to set override."
    ui_print "Enter 0 to clear override and use default."
    ui_prompt_input "Backup limit: " input
    input=$(trim_output "$input")

    case "$input" in
        0)
            set_backup_limit_for_alias "$alias" "" || {
                ui_print "Failed to clear backup limit override."
                return "$RC_GENERIC_ERROR"
            }
            ui_print "Backup limit override cleared for alias: $alias"
            return "$RC_OK"
            ;;
    esac

    normalized=$(sanitize_positive_int_or_empty "$input" 2>/dev/null || true)
    [ -n "$normalized" ] || {
        ui_print "Invalid backup limit."
        return "$RC_GENERIC_ERROR"
    }

    set_backup_limit_for_alias "$alias" "$normalized" || {
        ui_print "Failed to set backup limit override."
        return "$RC_GENERIC_ERROR"
    }
    ui_print "Backup limit set: $alias -> $normalized"
    return "$RC_OK"
}

alias_menu() {
    local choice
    local rc
    local prompt_rc

    while true; do
        ui_header "Alias Menu"
        ui_option "1" "Rename"
        ui_option "2" "Merge"
        ui_option "3" "Delete"
        ui_option "4" "Backup Limit"
        ui_option "5" "Restore Checkpoint"
        ui_option "6" "Back"
        choice=$(prompt_number_in_range "Select: " 1 6)
        prompt_rc=$?
        [ "$prompt_rc" -eq "$RC_CANCELLED" ] && continue

        case "$choice" in
            1) run_menu_action rename_alias_interactive 1 ;;
            2) run_menu_action merge_alias_interactive 1 ;;
            3) run_menu_action delete_alias_interactive 1 ;;
            4) run_menu_action set_alias_backup_limit_interactive 1 ;;
            5) run_menu_action restore_checkpoint_interactive 1 ;;
            6) return "$RC_OK" ;;
        esac

        rc=$?
        if [ "$rc" -ne "$RC_OK" ] && [ "$rc" -ne "$RC_CANCELLED" ]; then
            ui_print "Alias operation failed (code: $rc)."
            ui_pause
        fi
    done
}

operation_menu() {
    local choice
    local rc
    local prompt_rc

    while true; do
        ui_header "Operation Menu"
        ui_option "1" "Execute"
        ui_option "2" "View Entries"
        ui_option "3" "Lint"
        ui_option "4" "Create"
        ui_option "5" "Delete"
        ui_option "6" "Back"
        choice=$(prompt_number_in_range "Select: " 1 6)
        prompt_rc=$?
        [ "$prompt_rc" -eq "$RC_CANCELLED" ] && continue

        case "$choice" in
            1) run_menu_action execute_operation 1 ;;
            2) run_menu_action show_operation_entries_interactive 0 ;;
            3) run_menu_action lint_operation_interactive 0 ;;
            4) run_menu_action create_operation_interactive 1 ;;
            5) run_menu_action delete_operation_interactive 1 ;;
            6) return "$RC_OK" ;;
        esac

        rc=$?
        if [ "$rc" -ne "$RC_OK" ] && [ "$rc" -ne "$RC_CANCELLED" ]; then
            ui_print "Operation failed (code: $rc)."
            ui_pause
        fi
    done
}

pairing_menu() {
    local pairing_choice
    local prompt_rc
    local rc

    ui_header "Pairing / Unpair"
    ui_option "1" "Pairing"
    ui_option "2" "Unpair"
    ui_option "3" "Back"
    pairing_choice=$(prompt_number_in_range "Select: " 1 3)
    prompt_rc=$?
    [ "$prompt_rc" -eq "$RC_CANCELLED" ] && return "$RC_CANCELLED"

    case "$pairing_choice" in
        1)
            pair_device
            rc=$?
            ui_pause
            return "$rc"
            ;;
        2)
            disconnect_active_pairing
            rc=$?
            ui_pause
            return "$rc"
            ;;
        3) return "$RC_OK" ;;
    esac
}

count_operation_files() {
    local -a operation_files

    mapfile -t operation_files < <(list_operation_files 2>/dev/null || true)
    ui_printf '%s' "${#operation_files[@]}"
}

count_snapshot_files_total() {
    local listed_alias
    local listed_count
    local total=0
    local -a aliases

    mapfile -t aliases < <(list_snapshot_aliases 2>/dev/null || true)
    for listed_alias in "${aliases[@]}"; do
        listed_count=$(list_snapshot_files_sorted "$listed_alias" 2>/dev/null | wc -l | tr -d ' ')
        total=$((total + ${listed_count:-0}))
    done

    ui_printf '%s' "$total"
}

count_snapshot_files_for_alias() {
    local alias="$1"
    local dir
    local count=0

    [ -n "$alias" ] || {
        count_snapshot_files_total
        return 0
    }

    dir="$STATE_DIR/$alias/backups"
    [ -d "$dir" ] || {
        ui_printf '0'
        return 0
    }

    count=$(list_snapshot_files_sorted "$alias" 2>/dev/null | wc -l | tr -d ' ')
    ui_printf '%s' "${count:-0}"
}

resolve_operation_file_for_cli() {
    local operation_input="$1"

    if [ -f "$operation_input" ]; then
        ui_printf '%s' "$operation_input"
        return "$RC_OK"
    fi

    if [ -f "$OPERATION_DIR/$operation_input" ]; then
        ui_printf '%s' "$OPERATION_DIR/$operation_input"
        return "$RC_OK"
    fi

    if [ -f "$OPERATION_DIR/$operation_input.op" ]; then
        ui_printf '%s' "$OPERATION_DIR/$operation_input.op"
        return "$RC_OK"
    fi

    return "$RC_GENERIC_ERROR"
}

resolve_snapshot_file_for_cli() {
    local alias="$1"
    local snapshot_input="$2"
    local dir="$STATE_DIR/$alias/backups"

    if [ -f "$snapshot_input" ]; then
        ui_printf '%s' "$snapshot_input"
        return "$RC_OK"
    fi

    if [ -f "$dir/$snapshot_input" ]; then
        ui_printf '%s' "$dir/$snapshot_input"
        return "$RC_OK"
    fi

    if [ -f "$dir/$snapshot_input.snapshot" ]; then
        ui_printf '%s' "$dir/$snapshot_input.snapshot"
        return "$RC_OK"
    fi

    return "$RC_GENERIC_ERROR"
}

resolve_connected_serial_for_alias() {
    local alias="$1"
    local mapped_device_id
    local device
    local serial
    local old_serial="$CURRENT_DEVICE_SERIAL"
    local old_device_id="$CURRENT_DEVICE_ID"
    local old_alias="$CURRENT_ALIAS"
    local -a devices

    mapfile -t devices < <(list_devices)
    [ "${#devices[@]}" -gt 0 ] || return "$RC_NO_DEVICE"

    for device in "${devices[@]}"; do
        if [ "$device" = "$alias" ]; then
            ui_printf '%s' "$device"
            return "$RC_OK"
        fi
    done

    mapped_device_id=$(lookup_device_id_by_alias "$alias")
    if [ -n "$mapped_device_id" ]; then
        for device in "${devices[@]}"; do
            CURRENT_DEVICE_SERIAL="$device"
            CURRENT_DEVICE_ID=""
            if update_current_device_identity >/dev/null 2>&1; then
                if [ "$CURRENT_DEVICE_ID" = "$mapped_device_id" ]; then
                    serial="$device"
                    CURRENT_DEVICE_SERIAL="$old_serial"
                    CURRENT_DEVICE_ID="$old_device_id"
                    CURRENT_ALIAS="$old_alias"
                    ui_printf '%s' "$serial"
                    return "$RC_OK"
                fi
            fi
        done
    fi

    if [ "${#devices[@]}" -eq 1 ]; then
        serial="${devices[0]}"
        CURRENT_DEVICE_SERIAL="$old_serial"
        CURRENT_DEVICE_ID="$old_device_id"
        CURRENT_ALIAS="$old_alias"
        ui_printf '%s' "$serial"
        return "$RC_OK"
    fi

    CURRENT_DEVICE_SERIAL="$old_serial"
    CURRENT_DEVICE_ID="$old_device_id"
    CURRENT_ALIAS="$old_alias"
    return "$RC_ALIAS_RESOLUTION_FAILED"
}

execute_operation_cli() {
    local operation_input="$1"
    local alias="$2"
    local run_mode="${3:-execute}"
    local operation_file
    local operation_name
    local mode_key
    local operation_spec
    local serial
    local -a operations

    ensure_adb_installed || {
        ui_print "ADB is not installed."
        return "$RC_ADB_NOT_INSTALLED"
    }

    serial=$(resolve_connected_serial_for_alias "$alias") || {
        ui_print "Failed to resolve connected serial for alias: $alias"
        return "$RC_ALIAS_RESOLUTION_FAILED"
    }

    operation_file=$(resolve_operation_file_for_cli "$operation_input") || {
        ui_print "Operation file not found: $operation_input"
        return "$RC_GENERIC_ERROR"
    }

    CURRENT_DEVICE_SERIAL="$serial"
    CURRENT_ALIAS="$alias"
    CURRENT_DEVICE_ID=""
    update_current_device_identity >/dev/null 2>&1 || true

    operation_name=$(basename "$operation_file" .op)
    mode_key=$(sanitize_operation_name "$operation_name")

    operation_spec=$(load_operation_spec "$operation_file" 2>&1) || {
        ui_print "Failed to read operation: $operation_file"
        ui_print "Reason: $operation_spec"
        return "$RC_GENERIC_ERROR"
    }
    mapfile -t operations <<< "$operation_spec"

    show_operation_preview "CLI Operation preview: $operation_name" operations
    if [ "$run_mode" = "execute" ]; then
        show_pre_execution_diff "CLI Pre-execution diff: $operation_name" operations || {
            ui_print "Pre-execution diff failed due to read errors."
            return "$RC_OPERATION_FAILED"
        }
    fi

    execute_transaction "OPERATION ($operation_name)" "$alias" "operation-$mode_key" operations "$run_mode"
    return $?
}

restore_snapshot_cli() {
    local snapshot_input="$1"
    local alias="$2"
    local run_mode="${3:-execute}"
    local serial
    local snapshot_file

    ensure_adb_installed || {
        ui_print "ADB is not installed."
        return "$RC_ADB_NOT_INSTALLED"
    }

    serial=$(resolve_connected_serial_for_alias "$alias") || {
        ui_print "Failed to resolve connected serial for alias: $alias"
        return "$RC_ALIAS_RESOLUTION_FAILED"
    }

    snapshot_file=$(resolve_snapshot_file_for_cli "$alias" "$snapshot_input") || {
        ui_print "Snapshot file not found: $snapshot_input"
        return "$RC_GENERIC_ERROR"
    }

    CURRENT_DEVICE_SERIAL="$serial"
    CURRENT_ALIAS="$alias"
    CURRENT_DEVICE_ID=""
    update_current_device_identity >/dev/null 2>&1 || true

    run_snapshot_restore_flow "$snapshot_file" "$alias" "normal" "$run_mode" "1"
    return $?
}

print_cli_usage() {
    ui_print "Usage:"
    ui_print "  $0 --execute <operation_name_or_path> --alias <alias> [--dry-run]"
    ui_print "  $0 --restore-snapshot <snapshot_name_or_path> --alias <alias> [--dry-run]"
    ui_print ""
    ui_print "Examples:"
    ui_print "  $0 --execute phantom_limit_off --alias my_phone"
    ui_print "  $0 --execute phantom_limit_off --alias my_phone --dry-run"
    ui_print "  $0 --restore-snapshot 20260305_101010-operation-foo.snapshot --alias my_phone"
}

run_cli_mode() {
    local execute_name=""
    local restore_snapshot_name=""
    local alias=""
    local run_mode="execute"

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --execute)
                [ "$#" -ge 2 ] || { ui_print "--execute requires a value."; return "$RC_GENERIC_ERROR"; }
                execute_name="$2"
                shift 2
                ;;
            --restore-snapshot)
                [ "$#" -ge 2 ] || { ui_print "--restore-snapshot requires a value."; return "$RC_GENERIC_ERROR"; }
                restore_snapshot_name="$2"
                shift 2
                ;;
            --alias)
                [ "$#" -ge 2 ] || { ui_print "--alias requires a value."; return "$RC_GENERIC_ERROR"; }
                alias="$2"
                shift 2
                ;;
            --dry-run)
                run_mode="dry-run"
                shift
                ;;
            -h|--help)
                print_cli_usage
                return "$RC_OK"
                ;;
            *)
                ui_print "Unknown argument: $1"
                print_cli_usage
                return "$RC_GENERIC_ERROR"
                ;;
        esac
    done

    if [ -n "$execute_name" ] && [ -n "$restore_snapshot_name" ]; then
        ui_print "Use either --execute or --restore-snapshot, not both."
        print_cli_usage
        return "$RC_GENERIC_ERROR"
    fi

    if [ -z "$execute_name" ] && [ -z "$restore_snapshot_name" ]; then
        ui_print "--execute or --restore-snapshot is required."
        print_cli_usage
        return "$RC_GENERIC_ERROR"
    fi
    [ -n "$alias" ] || {
        ui_print "--alias is required."
        print_cli_usage
        return "$RC_GENERIC_ERROR"
    }

    if [ -n "$execute_name" ]; then
        execute_operation_cli "$execute_name" "$alias" "$run_mode"
        return $?
    fi

    restore_snapshot_cli "$restore_snapshot_name" "$alias" "$run_mode"
    return $?
}

main_menu() {
    local choice
    local exit_choice
    local prompt_rc
    local operation_count
    local snapshot_count

    while true; do
        refresh_pairing_state
        refresh_context_for_selected_device >/dev/null 2>&1 || true

        ui_header "ADB Manager"
        ui_status_line "Target:" "${CURRENT_DEVICE_SERIAL:-<none>}"
        ui_status_line "Alias:" "${CURRENT_ALIAS:-<unmapped>}"
        ui_status_line "Device ID:" "${CURRENT_DEVICE_ID:-<unknown>}"
        operation_count=$(count_operation_files)
        snapshot_count=$(count_snapshot_files_for_alias "$CURRENT_ALIAS")
        ui_status_line "Counts:" "operations=$operation_count snapshots=$snapshot_count"
        if [ "$HAS_ACTIVE_PAIRING" -eq 1 ]; then
            ui_status_line "Pairing:" "connected"
        else
            ui_status_line "Pairing:" "disconnected"
        fi
        ui_divider
        ui_option "1" "ADB Install"
        ui_option "2" "Pairing/Unpair"
        ui_option "3" "Operation"
        ui_option "4" "Snapshot"
        ui_option "5" "Alias"
        ui_option "6" "Exit"

        choice=$(prompt_number_in_range "Select: " 1 6)
        prompt_rc=$?
        [ "$prompt_rc" -eq "$RC_CANCELLED" ] && continue

        case "$choice" in
            1) install_adb ;;
            2) pairing_menu ;;
            3) operation_menu ;;
            4) snapshot_menu ;;
            5) alias_menu ;;
            6)
                if [ "$HAS_ACTIVE_PAIRING" -eq 1 ]; then
                    if ! disconnect_active_pairing auto; then
                        ui_print "Auto unpair failed."
                        while true; do
                            ui_option "1" "Unpair now (select target)"
                            ui_option "2" "Exit anyway"
                            ui_option "3" "Cancel"
                            exit_choice=$(prompt_number_in_range "Select: " 1 3)
                            prompt_rc=$?
                            [ "$prompt_rc" -eq "$RC_CANCELLED" ] && continue 2
                            case "$exit_choice" in
                                1)
                                    if disconnect_active_pairing; then
                                        break
                                    fi
                                    ;;
                                2) break ;;
                                3) continue 2 ;;
                            esac
                        done
                    fi
                fi
                exit "$RC_OK"
                ;;
        esac
    done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    check_kernel
    if [ "$#" -gt 0 ]; then
        run_cli_mode "$@"
        exit $?
    fi
    init_tui_mode
    init_ui_theme
    enter_tui_alt_screen
    trap leave_tui_alt_screen EXIT
    main_menu
fi
