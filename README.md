# ADB Manager

`adb-manager`는 ADB 연결/페어링과 operation 파일 기반 설정 실행을 제공하는 스크립트입니다.

## 구성

- `adb-manager.sh`: 메인 스크립트
- `operations/*.op`: 실행 가능한 operation 정의 파일
- `tests/adb-manager.bats`: operation/백업/트랜잭션 회귀 테스트
- `device_profiles/`: 프로필 관련 파일 저장 디렉터리
- `device_states/`: alias 매핑, snapshot, lock 파일 저장 디렉터리 (실행 시 자동 생성)

## 실행

```bash
cd /home/dev/workspace/projects/scripts/adb-manager
chmod +x ./adb-manager.sh
./adb-manager.sh
```

기본 interactive 모드는 TUI(alt screen + 화면 refresh)로 동작합니다. 이전 출력 누적이 싫다면 기본값 그대로 사용하면 됩니다.
필요하면 아래처럼 비활성화할 수 있습니다.

```bash
ADB_MANAGER_TUI=0 ./adb-manager.sh
```

환경변수로 경로를 override 할 수 있습니다.

```bash
STATE_DIR=/path/to/custom-state OPERATION_DIR=/path/to/ops ./adb-manager.sh
```

## 메뉴

1. ADB Install
2. Pairing/Unpair
3. Operation
4. Snapshot
5. Alias
6. Exit

## Operation 메뉴

1. Execute
2. View Entries
3. Lint
4. Create
5. Delete
6. Back

## Snapshot 메뉴

1. Restore Snapshot
2. View Entries
3. Restore Last Auto Backup
4. Restore Checkpoint
5. Back

- `View Entries`는 로컬 snapshot 파일 조회 기능이라 ADB 연결/Pairing 없이 사용 가능
- `View Entries` 필터 기본값은 `Recent 10`

## Alias 메뉴

1. Rename
2. Merge
3. Delete (백업 archive 보존/완전삭제 선택)
4. Backup Limit
5. Restore Checkpoint
6. Back

## Operation 파일 포맷

`operations/*.op` 파일은 아래 포맷을 사용합니다.

```txt
# operation=<name>
# version=2
# format=kind|namespace|key|value_type|target
device_config|global|sync_disabled_for_tests|string|persistent
settings|global|settings_enable_monitor_phantom_procs|bool|false
```

- `kind`: `device_config` 또는 `settings`
- `value_type`: `string`, `int`, `bool`, `delete`
- `target`: `delete`일 때 `__DELETE__` 또는 `-`
- `version`: `1`(legacy), `2`(typed) 지원

## 동작 요약

- Execute 진입 후 `Execution mode (Execute/Dry-run/Cancel)` 선택
- Execute/Restore 실행 전 현재값 기준 `Pre-execution diff` 요약 출력
- Execute/Restore 전 선택된 operation의 key만 자동 snapshot 백업
- snapshot 정렬은 파일 수정시간이 아닌 snapshot metadata `created_at` 기준 최신순
- backup 보관 개수는 기본 `BACKUP_LIMIT`(기본 5), alias별 override 가능(`Alias > Backup Limit`)
- Restore Snapshot은 alias 백업 목록에서 `All/Keyword/Recent N` 필터 후 선택 복원
- Snapshot 메뉴에서 최신 자동 백업(`operation-*`, `auto-pre-restore`) 즉시 복원 지원
- Snapshot/Alias 메뉴에서 checkpoint 목록 선택 복원 지원
- Restore에서 자동 생성된 pre-restore snapshot 복원 시 경고/확인
- Restore Snapshot 실행 전 snapshot 무결성(`version=2`, `operations_checksum`) 검증
- transaction 실패 시 자동 rollback
- alias 단위 lock으로 동시 실행 충돌 방지
- Alias `Rename/Merge/Delete`는 실행 전 2단계 확인 + rollback checkpoint(`device_states/_checkpoints`) 생성
- Alias `Rename/Merge/Delete`는 임시 transaction 디렉터리(`device_states/_txn`)에서 staging 후 commit

## 비대화형 실행

```bash
./adb-manager.sh --execute <operation_name_or_path> --alias <alias> [--dry-run]
./adb-manager.sh --restore-snapshot <snapshot_name_or_path> --alias <alias> [--dry-run]
```

예시:

```bash
./adb-manager.sh --execute phantom_limit_off --alias my_phone
./adb-manager.sh --execute phantom_limit_off --alias my_phone --dry-run
./adb-manager.sh --restore-snapshot 20260305_101010-operation-foo.snapshot --alias my_phone
```

## 기본 operation

- `operations/phantom_limit_off.op`
- `operations/phantom_default_restore.op`

## 테스트

`bats`가 설치되어 있으면 아래로 실행:

```bash
cd /home/dev/workspace/projects/scripts/adb-manager
bash tests/run-tests.sh
```

스모크 테스트만 빠르게 확인:

```bash
cd /home/dev/workspace/projects/scripts/adb-manager
bash tests/run-tests.sh --filter "smoke"
```
