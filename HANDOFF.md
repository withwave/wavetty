# 작업 인계 — 2026-10-30

## 현재 상태
- **v1.4.12-withwave 릴리즈 완료.** `main == origin/main`, 태그와 GitHub
  Release(공증된 `Wavetty.dmg`) 업로드까지 끝남. upstream/main
  `b2c78c9bd`(2026-10-28)까지 반영.
- 빌드 도구: **Zig 0.17**(brew `zig`), Xcode 27 / macOS 27 SDK.
  `build-wavetty.sh`가 `/opt/homebrew/opt/zig/bin`을 PATH 앞에 둔다.
- 교체 전 main 백업: 로컬 브랜치 `backup/main-pre-sync-2026-10`(v1.4.11 +
  push 안 했던 3커밋).

## 1.4.12에 들어간 것 (1.4.11 대비)
1. **upstream 동기화** — 5/14 → 10/28, 약 2,350커밋. 9월에 rebase로 1차
   (Zig 0.16), 10월에 merge로 2차(Zig 0.17). 포크 커밋 중 진단/되돌리기
   9개는 제외(`src/` 순효과 0).
2. **세션 히스토리 불일치 수정** — 최근 창을 폴더 구성이 아닌 surface UUID로
   식별(`WAVETTY.md` §4.4). macOS 상태 복원 스크롤백도 번들 ID 경로 + 컬러.
3. **창 제목 = "폴더 — 프로그램 제목"** — Dock 열린 창 목록·Recent Windows
   공통. 폴더명은 열린 창 전체 기준 유일(`KEA`, `MEDI/KEA`, `KEA ②`,
   `ssh nas`). 프로그램 제목이 폴더와 중복이면 생략(§4.5).
4. **종료 확인 시트를 띄울 때 창을 앞으로** — Dock에서 종료 시 시트가 다른
   모니터 창에 붙어 안 보이고 앱이 `.terminateLater`로 무기한 대기하던 문제.
   그 동안 기본 모드 타이머가 멈춰 창 제목 갱신도 멈췄다.

## Zig 0.17 전환 시 고친 곳 (다음 upstream 동기화 때 참고)
- `src/os/process.zig`: `@cImport` 제거됨 → `tcgetpgrp`를 extern 선언.
  libproc도 translate-c 문제로 수동 선언.
- `src/apprt/embedded.zig`: `Allocator.dupeZ` → `dupeSentinel(…, 0)`.
- 9월 동기화(0.16) 때: mutex API(`lockUncancelable(global.io())`).

## 다음 할 일
- [ ] 사용 테스트: 창 닫기/복원(upstream 창 복원 변경 3건과 겹침),
      Dock 「폴더 — 제목」, 한글 붙여넣기, SSH
- [ ] 정리: `git worktree remove ../ghostty-sync ../ghostty-trial`,
      브랜치 `sync/upstream-2026-09`, `trial/merge-2026-10` 삭제

## 주의
- 이제 main은 rebase가 아닌 **merge로 upstream을 따라간다**(force push 불필요).
  `release-wavetty.sh`는 기본으로 rebase하므로 `--skip-rebase`로 쓰고,
  동기화는 `git merge upstream/main`으로 따로 할 것.
- brew `zig`가 upstream 요구 버전보다 앞서가면(0.18 등) 빌드 실패 →
  upstream `build.zig.zon`의 `minimum_zig_version`에 맞춰 설치.
- 셸이 macOS 기본 `/bin/bash`(3.2)면 셸 통합이 안 붙어 모든 창이 "실행 중
  프로세스"로 간주 → 종료 때마다 확인 시트가 뜬다.
- `recent-windows.json` 기존 항목은 `.ansi` 파일명으로 식별되므로
  마이그레이션 불필요.
