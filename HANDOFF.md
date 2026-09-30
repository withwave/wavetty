# 작업 인계 — 2026-09-30

## 현재 상태
- **main** (origin과 동일 + 로컬 커밋 3개, push 전): v1.4.11 기반.
- **`sync/upstream-2026-09`** (worktree `../ghostty-sync`, push 전): upstream/main
  `cc2f7ee4d`(2026-09-29) 위에 Wavetty 커밋을 다시 쌓은 브랜치. **최종 후보.**
  - 5/14 이후 upstream 1,875커밋 반영.
  - 포크 커밋 71개 중 진단/되돌리기 3쌍(9개, `src/` 순효과 0)은 제외하고 62개
    적용 + 이번 작업 커밋.
  - Zig 0.16 필요(upstream `minimum_zig_version`). `build-wavetty.sh`가
    `zig@0.16`을 PATH에 고정.

## 이번 작업 (2026-09-30)
1. **세션 히스토리 불일치 수정** — 최근 창 기록이 창을 "폴더 구성"으로 식별해
   같은 폴더의 다른 창이 한 항목으로 합쳐지고, 복원 시 엉뚱한 창으로 포커스가
   갔다. surface UUID 기반 식별로 교체(`WAVETTY.md` §4.4). macOS 상태 복원
   경로의 스크롤백도 `com.mitchellh.ghostty` 하드코딩 → 번들 ID, 평문 → 컬러.
2. **upstream 동기화** — 위 브랜치. 충돌 해결 원칙: upstream 구조 채택 + Wavetty
   추가분 재적용. 주요 변화: `AppDelegate`가 `Sources/App/`으로 이동, iOS
   `SurfaceView_UIKit.swift` 삭제, 종료 확인이 `terminate()`/`reviewWindows`로
   분리(문자열만 리브랜딩), PTY 쓰기 버퍼가 `Write.buf`로 이동(4096 재적용).
3. **Dock 열린 창 = 폴더명** — `WavettyWindowTitles`가 창 제목을 전체 창 기준
   유일한 폴더명으로 지정(`KEA`, `MEDI/KEA`, `KEA ②`, `ssh nas`). §4.5.

## 환경 변화 (중요)
- Xcode 27 / macOS 27 SDK로 업데이트됨.
  - Zig 0.15.2로는 lib-vt의 libcxx가 컴파일 안 됨(`INFINITY` 미정의) → **main은
    더 이상 그대로 빌드 불가**. 동기화 브랜치(Zig 0.16)는 정상.
  - Metal Toolchain이 빠져 있어 `xcodebuild -downloadComponent MetalToolchain`
    으로 재설치함.

## 다음 할 일
- [ ] 동기화 브랜치 빌드(`zig-out/Wavetty.app`) 설치 후 사용자 테스트
      (Dock 열린 창 이름, 같은 폴더 창 두 개 닫고 각각 복원 시 히스토리 일치)
- [ ] 승인 후: main을 동기화 브랜치로 교체(`git branch -f main sync/...` 또는
      reset) → `release-wavetty.sh --skip-rebase --bump 1.4.12-withwave`
      (force-with-lease push 포함)
- [ ] worktree 정리: `git worktree remove ../ghostty-sync`

## 주의
- `recent-windows.json`의 기존 항목은 surfaceID가 없어도 `.ansi` 파일명으로
  식별되므로 마이그레이션 불필요. 폴더 기준 dedup이 없어져 같은 폴더의 항목이
  여러 개 보일 수 있음(메뉴에 시각 표시로 구분).
- 창 제목이 폴더명으로 고정되므로 셸/프로그램이 설정하는 제목(예: Claude Code의
  작업 표시)은 탭에 보이지 않음. 필요하면 `prompt_tab_title`로 수동 지정.
