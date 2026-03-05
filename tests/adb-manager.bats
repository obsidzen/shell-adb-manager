#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT_PATH="$PROJECT_ROOT/adb-manager.sh"
    TEST_TMP_ROOT="$PROJECT_ROOT/tests/.tmp"
    mkdir -p "$TEST_TMP_ROOT"
    TEST_TMPDIR="$(mktemp -d "$TEST_TMP_ROOT/case.XXXXXX")"
    source "$SCRIPT_PATH"
    STATE_DIR="$TEST_TMPDIR/state"
    OPERATION_DIR="$TEST_TMPDIR/operations"
    ALIAS_MAP_FILE="$STATE_DIR/device_alias_map.tsv"
    ALIAS_MAP_LOCK_FILE="$STATE_DIR/device_alias_map.lock"
    ALIAS_BACKUP_LIMIT_FILE="$STATE_DIR/alias_backup_limit.tsv"
    mkdir -p "$STATE_DIR" "$OPERATION_DIR"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "load_operation_spec parses valid operation file" {
    local op_file="$OPERATION_DIR/test.op"
    cat > "$op_file" <<'EOF'
# operation=test
# version=1
# format=kind|namespace|key|target
device_config|global|sync_disabled_for_tests|persistent
settings|global|settings_enable_monitor_phantom_procs|false
EOF

    run load_operation_spec "$op_file"

    [ "$status" -eq "$RC_OK" ]
    [[ "$output" == *"device_config|global|sync_disabled_for_tests|persistent"* ]]
    [[ "$output" == *"settings|global|settings_enable_monitor_phantom_procs|false"* ]]
}

@test "load_operation_spec parses typed version 2 file" {
    local op_file="$OPERATION_DIR/typed.op"
    cat > "$op_file" <<'EOF'
# operation=typed
# version=2
# format=kind|namespace|key|value_type|target
settings|global|settings_enable_monitor_phantom_procs|bool|TRUE
device_config|activity_manager|max_phantom_processes|int|2147483647
device_config|activity_manager|other_key|delete|-
EOF

    run load_operation_spec "$op_file"

    [ "$status" -eq "$RC_OK" ]
    [[ "$output" == *"settings|global|settings_enable_monitor_phantom_procs|true"* ]]
    [[ "$output" == *"device_config|activity_manager|max_phantom_processes|2147483647"* ]]
    [[ "$output" == *"device_config|activity_manager|other_key|__DELETE__"* ]]
}

@test "load_operation_spec rejects invalid typed target" {
    local op_file="$OPERATION_DIR/typed-invalid.op"
    cat > "$op_file" <<'EOF'
# operation=typed_invalid
# version=2
settings|global|settings_enable_monitor_phantom_procs|bool|not_bool
EOF

    run load_operation_spec "$op_file"

    [ "$status" -eq "$RC_GENERIC_ERROR" ]
    [[ "$output" == *"Invalid typed target"* ]]
}

@test "load_operation_spec rejects invalid kind" {
    local op_file="$OPERATION_DIR/invalid.op"
    cat > "$op_file" <<'EOF'
# version=1
bad_kind|global|k|v
EOF

    run load_operation_spec "$op_file"

    [ "$status" -eq "$RC_GENERIC_ERROR" ]
    [[ "$output" == *"Unsupported operation kind"* ]]
}

@test "load_operation_spec rejects missing version" {
    local op_file="$OPERATION_DIR/no-version.op"
    cat > "$op_file" <<'EOF'
# operation=test
device_config|global|sync_disabled_for_tests|persistent
EOF

    run load_operation_spec "$op_file"

    [ "$status" -eq "$RC_GENERIC_ERROR" ]
    [[ "$output" == *"Unsupported or missing operation version"* ]]
}

@test "backup_snapshot backs up only operation keys" {
    local alias="test-device"
    local -a operations
    local backup_file

    operations=(
        "device_config|global|sync_disabled_for_tests|persistent"
        "settings|global|settings_enable_monitor_phantom_procs|false"
    )

    get_current_value() {
        case "$3" in
            sync_disabled_for_tests) printf '%s' "none" ;;
            settings_enable_monitor_phantom_procs) printf '%s' "true" ;;
            *) printf '%s' "__UNSET__" ;;
        esac
    }

    backup_file=$(backup_snapshot "$alias" "operation-test" operations)
    [ -f "$backup_file" ]
    run grep -E '^(device_config|settings)\|' "$backup_file"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l)" -eq 2 ]
}

@test "execute_transaction returns operation error and rolls back on failure" {
    local -a operations

    operations=(
        "device_config|global|sync_disabled_for_tests|none"
        "device_config|activity_manager|max_phantom_processes|2147483647"
    )
    ROLLBACK_KEYS=()

    backup_snapshot() { printf '%s' "$TEST_TMPDIR/backup.snapshot"; }
    get_current_value() { printf '%s' "old-$3"; }
    set_remote_value() {
        if [ "$3" = "max_phantom_processes" ]; then
            return 1
        fi
        return 0
    }
    verify_remote_value() { printf '%s' "ok"; }
    restore_original_value() {
        ROLLBACK_KEYS+=("$3")
        return 0
    }

    run execute_transaction "OPERATION(test)" "alias-a" "operation-test" operations "execute"

    [ "$status" -eq "$RC_OPERATION_FAILED" ]
    [ "${#ROLLBACK_KEYS[@]}" -eq 2 ]
}

@test "create_operation_interactive creates operation file with version" {
    run bash -c '
        source "$1"
        STATE_DIR="$2"
        OPERATION_DIR="$3"
        mkdir -p "$STATE_DIR" "$OPERATION_DIR"
        printf "sample_op\n1\nglobal\nmy_key\n1\nmy value\n3\n" | create_operation_interactive
        rc=$?
        [ "$rc" -eq 0 ] || exit "$rc"
        [ -f "$OPERATION_DIR/sample_op.op" ] || exit 1
        grep -q "^# version=2$" "$OPERATION_DIR/sample_op.op" || exit 1
        grep -q "^device_config|global|my_key|string|my value$" "$OPERATION_DIR/sample_op.op" || exit 1
    ' _ "$SCRIPT_PATH" "$STATE_DIR" "$OPERATION_DIR"

    [ "$status" -eq 0 ]
}

@test "delete_operation_interactive removes selected operation file" {
    local op_file="$OPERATION_DIR/delete_me.op"
    cat > "$op_file" <<'EOF'
# operation=delete_me
# version=1
# format=kind|namespace|key|target
settings|global|k|v
EOF

    run bash -c '
        source "$1"
        STATE_DIR="$2"
        OPERATION_DIR="$3"
        mkdir -p "$STATE_DIR" "$OPERATION_DIR"
        printf "1\ny\n" | delete_operation_interactive
        rc=$?
        [ "$rc" -eq 0 ] || exit "$rc"
        [ ! -f "$OPERATION_DIR/delete_me.op" ] || exit 1
    ' _ "$SCRIPT_PATH" "$STATE_DIR" "$OPERATION_DIR"

    [ "$status" -eq 0 ]
}

@test "confirm_snapshot_target_compatibility cancels on mismatch when user declines" {
    local snapshot_file="$TEST_TMPDIR/mismatch.snapshot"
    cat > "$snapshot_file" <<'EOF'
# version=2
# created_at=2026-03-05T00:00:00+0900
# alias=test
# target_serial=127.0.0.1:5555
# device_id=serial:other
# operations_checksum=sha256:dummy
device_config|global|sync_disabled_for_tests|none
EOF

    run bash -c '
        source "$1"
        CURRENT_DEVICE_ID="serial:current"
        CURRENT_DEVICE_SERIAL="127.0.0.1:5555"
        printf "n\n" | confirm_snapshot_target_compatibility "$2"
        exit $?
    ' _ "$SCRIPT_PATH" "$snapshot_file"

    [ "$status" -eq "$RC_CANCELLED" ]
}

@test "guard_restore_snapshot_loop cancels auto pre-restore snapshot when user declines" {
    local snapshot_file="$TEST_TMPDIR/auto-pre-restore.snapshot"
    cat > "$snapshot_file" <<'EOF'
# version=2
# snapshot=auto-pre-restore
# source_snapshot=20260305_090000-operation-test.snapshot
# created_at=2026-03-05T00:00:00+0900
# alias=test
# target_serial=127.0.0.1:5555
# device_id=serial:other
# operations_checksum=sha256:dummy
device_config|global|sync_disabled_for_tests|none
EOF

    run bash -c '
        source "$1"
        printf "n\n" | guard_restore_snapshot_loop "$2"
        exit $?
    ' _ "$SCRIPT_PATH" "$snapshot_file"

    [ "$status" -eq "$RC_CANCELLED" ]
}

@test "acquire_alias_lock returns lock busy when another process holds lock" {
    run bash -c '
        source "$1"
        STATE_DIR="$2"
        mkdir -p "$STATE_DIR"
        alias_name="lock_test"
        lock_file="$STATE_DIR/$alias_name/.transaction.lock"
        mkdir -p "$STATE_DIR/$alias_name"

        if command -v flock >/dev/null 2>&1; then
            (
                exec 9>"$lock_file"
                flock -n 9 || exit 1
                sleep 2
            ) &
            holder_pid=$!
            sleep 0.2
            acquire_alias_lock "$alias_name"
            rc=$?
            kill "$holder_pid" 2>/dev/null || true
            wait "$holder_pid" 2>/dev/null || true
            [ "$rc" -eq "$RC_LOCK_BUSY" ] || exit 1
        else
            mkdir "$lock_file.d"
            acquire_alias_lock "$alias_name"
            rc=$?
            [ "$rc" -eq "$RC_LOCK_BUSY" ] || exit 1
        fi
    ' _ "$SCRIPT_PATH" "$STATE_DIR"

    [ "$status" -eq 0 ]
}

@test "list_snapshot_files_sorted uses snapshot created_at metadata order" {
    local alias="sort-test"
    local backups_dir="$STATE_DIR/$alias/backups"
    mkdir -p "$backups_dir"

    cat > "$backups_dir/old.snapshot" <<'EOF'
# version=2
# created_at=2026-03-05T00:00:00+0900
EOF
    cat > "$backups_dir/new.snapshot" <<'EOF'
# version=2
# created_at=2026-03-05T00:00:10+0900
EOF

    run bash -c '
        source "$1"
        STATE_DIR="$2"
        list_snapshot_files_sorted "sort-test" | head -n 1
    ' _ "$SCRIPT_PATH" "$STATE_DIR"

    [ "$status" -eq 0 ]
    [ "$output" = "new.snapshot" ]
}

@test "backup_snapshot applies alias-specific backup limit override" {
    local alias="limit-test"
    local -a operations

    operations=("settings|global|k|v")
    get_current_value() { printf '%s' "old"; }

    set_backup_limit_for_alias "$alias" "1"
    backup_snapshot "$alias" "op-a" operations >/dev/null
    backup_snapshot "$alias" "op-b" operations >/dev/null

    run bash -c '
        ls -1 "$1/$2/backups"/*.snapshot 2>/dev/null | wc -l | tr -d " "
    ' _ "$STATE_DIR" "$alias"

    [ "$status" -eq 0 ]
    [ "$output" = "1" ]
}

@test "create_alias_management_checkpoint stores map, limit and alias state" {
    local alias="cp-test"
    local checkpoint

    mkdir -p "$STATE_DIR/$alias/backups"
    echo "data" > "$STATE_DIR/$alias/backups/file.snapshot"
    echo -e "device:1\t$alias" > "$STATE_DIR/device_alias_map.tsv"
    echo -e "$alias\t7" > "$STATE_DIR/alias_backup_limit.tsv"

    checkpoint=$(create_alias_management_checkpoint "unit-checkpoint" "$alias")
    [ -d "$checkpoint" ]
    [ -f "$checkpoint/device_alias_map.tsv" ]
    [ -f "$checkpoint/alias_backup_limit.tsv" ]
    [ -f "$checkpoint/aliases/$alias/backups/file.snapshot" ]
}

@test "run_cli_mode parses execute alias dry-run and delegates" {
    run bash -c '
        source "$1"
        execute_operation_cli() {
            printf "EXEC:%s:%s:%s\n" "$1" "$2" "$3"
            return 0
        }
        run_cli_mode --execute phantom_limit_off --alias my_phone --dry-run
    ' _ "$SCRIPT_PATH"

    [ "$status" -eq 0 ]
    [[ "$output" == *"EXEC:phantom_limit_off:my_phone:dry-run"* ]]
}

@test "run_cli_mode parses restore-snapshot alias dry-run and delegates" {
    run bash -c '
        source "$1"
        restore_snapshot_cli() {
            printf "RESTORE:%s:%s:%s\n" "$1" "$2" "$3"
            return 0
        }
        run_cli_mode --restore-snapshot snap-a --alias my_phone --dry-run
    ' _ "$SCRIPT_PATH"

    [ "$status" -eq 0 ]
    [[ "$output" == *"RESTORE:snap-a:my_phone:dry-run"* ]]
}

@test "confirm_snapshot_target_compatibility_non_interactive fails on mismatch" {
    local snapshot_file="$TEST_TMPDIR/mismatch-noninteractive.snapshot"
    cat > "$snapshot_file" <<'EOF'
# version=2
# created_at=2026-03-05T00:00:00+0900
# alias=test
# target_serial=127.0.0.1:5555
# device_id=serial:other
# operations_checksum=sha256:dummy
device_config|global|sync_disabled_for_tests|none
EOF

    run bash -c '
        source "$1"
        CURRENT_DEVICE_ID="serial:current"
        CURRENT_DEVICE_SERIAL="127.0.0.1:5555"
        confirm_snapshot_target_compatibility_non_interactive "$2"
    ' _ "$SCRIPT_PATH" "$snapshot_file"

    [ "$status" -ne 0 ]
    [[ "$output" == *"mismatch"* ]]
}

@test "restore_checkpoint_dir restores alias state and map files" {
    local alias="restore-cp"
    local checkpoint_root="$STATE_DIR/_checkpoints"
    local checkpoint_dir="$checkpoint_root/test-checkpoint"

    mkdir -p "$STATE_DIR/$alias"
    echo "before" > "$STATE_DIR/$alias/state.txt"
    echo -e "device:1\t$alias" > "$ALIAS_MAP_FILE"
    echo -e "$alias\t9" > "$ALIAS_BACKUP_LIMIT_FILE"

    mkdir -p "$checkpoint_dir/aliases/$alias"
    echo "after" > "$checkpoint_dir/aliases/$alias/state.txt"
    echo -e "device:1\t$alias" > "$checkpoint_dir/device_alias_map.tsv"
    echo -e "$alias\t3" > "$checkpoint_dir/alias_backup_limit.tsv"

    run restore_checkpoint_dir "$checkpoint_dir"

    [ "$status" -eq 0 ]
    run cat "$STATE_DIR/$alias/state.txt"
    [ "$status" -eq 0 ]
    [ "$output" = "after" ]
    run awk -F '\t' -v a="$alias" '$1==a {print $2}' "$ALIAS_BACKUP_LIMIT_FILE"
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]
}

@test "lint_operation_spec fails when duplicate keys exist" {
    local op_file="$OPERATION_DIR/dup.op"
    cat > "$op_file" <<'EOF'
# operation=dup
# version=2
settings|global|dup_key|bool|true
settings|global|dup_key|bool|false
EOF

    run lint_operation_spec "$op_file"

    [ "$status" -eq "$RC_GENERIC_ERROR" ]
    [[ "$output" == *"[LINT][WARN]"* ]]
    [[ "$output" == *"[LINT][FAIL]"* ]]
}

@test "lint_operation_interactive propagates lint failure status" {
    local op_file="$OPERATION_DIR/dup.op"
    cat > "$op_file" <<'EOF'
# operation=dup
# version=2
settings|global|dup_key|bool|true
settings|global|dup_key|bool|false
EOF

    run bash -c '
        source "$1"
        STATE_DIR="$2"
        OPERATION_DIR="$3"
        mkdir -p "$STATE_DIR" "$OPERATION_DIR"
        printf "1\n" | lint_operation_interactive
        exit $?
    ' _ "$SCRIPT_PATH" "$STATE_DIR" "$OPERATION_DIR"

    [ "$status" -eq "$RC_GENERIC_ERROR" ]
    [[ "$output" == *"[LINT][FAIL]"* ]]
}

@test "[smoke] count_snapshot_files_for_alias returns total when alias is empty" {
    mkdir -p "$STATE_DIR/a1/backups" "$STATE_DIR/a2/backups"
    : > "$STATE_DIR/a1/backups/one.snapshot"
    : > "$STATE_DIR/a2/backups/two.snapshot"

    run bash -c '
        source "$1"
        STATE_DIR="$2"
        count_snapshot_files_for_alias ""
    ' _ "$SCRIPT_PATH" "$STATE_DIR"

    [ "$status" -eq 0 ]
    [ "$output" = "2" ]
}

@test "[smoke] run_menu_action pauses only for success when enabled" {
    run bash -c '
        source "$1"
        pause_calls=0
        ui_pause() { pause_calls=$((pause_calls + 1)); }
        ok_action() { return "$RC_OK"; }
        fail_action() { return "$RC_GENERIC_ERROR"; }

        run_menu_action ok_action 1
        rc_ok_pause=$?
        run_menu_action ok_action 0
        rc_ok_no_pause=$?
        run_menu_action fail_action 1
        rc_fail=$?
        printf "%s|%s|%s|%s" "$rc_ok_pause" "$rc_ok_no_pause" "$rc_fail" "$pause_calls"
    ' _ "$SCRIPT_PATH"

    [ "$status" -eq 0 ]
    [ "$output" = "0|0|1|1" ]
}

@test "[smoke] select_operation_file returns generic error when no operation files" {
    run bash -c '
        source "$1"
        OPERATION_DIR="$2"
        mkdir -p "$OPERATION_DIR"
        select_operation_file >/dev/null
    ' _ "$SCRIPT_PATH" "$OPERATION_DIR"

    [ "$status" -eq 1 ]
    [[ "$output" == *"No operation files found"* ]]
}
