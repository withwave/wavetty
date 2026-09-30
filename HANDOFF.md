# 작업 인계 — 2026-08-28

## 현재 상태
Wavetty(Ghostty 포크) **v1.4.11-withwave 릴리즈 완료**.
`HEAD == origin/main == 태그 v1.4.11-withwave`, GitHub Release에 `Wavetty.dmg`
업로드까지 끝난 상태. (로컬 태그가 v1.4.2까지만 있으면 `git fetch --tags`)

이번 세션 작업: **문서 최신화 + 코드 결함 3건 수정 + Dock 열린 창 표시 개선**.
아래 "이번 세션 변경"은 아직 **커밋/빌드검증 전**일 수 있으니 확인할 것.

## 이번 세션 변경 (커밋 전)

### 코드
- `macos/Sources/Features/Sessions/SessionHistoryStore.swift`
  - `restore(_:)`의 `restoringIDs.insert`를 `guard let primaryWindow` **뒤로 이동**.
    이전에는 창 생성 실패 시 ID가 영구히 남아 그 항목의 복원과 모든 sweep이
    앱 종료 시까지 막혔다.
  - `scheduleShrinkReeval`의 생존 창 판정에 **`w.isVisible` 추가**. 닫혔지만 아직
    해제되지 않은 NSWindow를 생존으로 오판하면 "창 전체 닫기"를 "탭 하나 닫기"로
    처리해 기록이 잘린다.
  - `windowWillClose`의 stale 주석(1.4.10의 "don't shrink" 설명)을 1.4.11의
    지연 재평가 방식으로 갱신.
- `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`
  - `effectivePwd()` 추출 + `pwdDisplayPath()`(틸드 축약 경로) 추가.
- `macos/Sources/Features/Terminal/BaseTerminalController.swift`
  - **창 제목 = 작업 디렉토리 경로**(`~/AI/ghostty`). `wavettyTitleSurface`(weak)로
    제목 소스 surface를 추적하고 `applyTitleToWindow`에서 pwd 우선 적용,
    `pwdDidChange`에서 재적용. 사용자 title override > pwd > 셸 제목 순.
  - **의도**: Dock 메뉴 최상단의 열린 창 목록은 AppKit이 `NSWindow.title`로
    자동 생성하며 커스터마이즈 API가 없다. 제목 자체를 경로로 만드는 것이
    그 목록을 Recent Windows 섹션과 같은 표기로 맞추는 유일한 방법.

### 문서
- `WAVETTY.md`: §3.1 Sessions 파일 목록, §3.3(Zig 코어 수정 금지 → **실제 예외
  3곳 표로 명시**), §4.4 세션 복구 전체 신설, §4.5 pwd 창 제목 신설, §5.2
  `--debug`, §8 파일 목록/기능 목록, §10 Keychain 항목 삭제(구현 완료), §12 읽기 순서
- `RELEASING-WITHWAVE.md`: `--debug` 빌드 설명 추가
- `HANDOFF.md`: 이 문서(v1.4.3 시점 내용 폐기 후 재작성)

## 다음 할 일
- [ ] `PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH" zig build -Doptimize=ReleaseFast`
      로 컴파일 확인 (기본 PATH의 zig는 0.16이라 build.zig에서 실패함)
- [ ] `./scripts/build-wavetty.sh` → `/Applications/Wavetty.app` 설치 → 실행
- [ ] 검증: Dock 아이콘 우클릭 → **상단 열린 창 목록이 `~/경로`로 표시**되는지
- [ ] 검증: 탭 하나 닫기 → 기록 탭 수 감소 / 창 전체 닫기 → 전체 탭 보존·복원
- [ ] 커밋 + `./scripts/release-wavetty.sh --bump 1.4.12-withwave` (릴리즈는 요청 시)

## 미해결 / 주의
- **`collapseTabGrowth` 부작용**: 로드 시 "탭 시그니처가 다른 항목의 prefix"인
  엔트리를 제거하므로, `~/a` 1탭 창과 `~/a + ~/b` 2탭 창을 함께 쓰면 1탭 항목이
  재시작 때 사라진다. 의도된 정리이지만 사용자가 불편해하면 재검토 대상.
- **탭 닫고 0.6초 내 앱 종료**하면 `scheduleShrinkReeval`이 못 돌아 닫은 탭이
  기록에 남는다(경미).
- **UI 자동화 제약**: 터미널에서 osascript/cliclick 접근성 권한이 막히면(-1719)
  메뉴 자동 클릭 검증 불가 → 사용자 직접 클릭 필요.

## 참고
- 브랜딩은 100% `scripts/build-wavetty.sh` Step 2 후처리(plutil/sed). Xcode 소스는
  전부 upstream 값이라 **디버그/일반 xcodebuild 빌드는 "Ghostty"로 뜨는 게 정상**.
  리브랜딩된 디버그 빌드가 필요하면 `./scripts/build-wavetty.sh --debug`.
- 세션 복구 상세 설명은 `WAVETTY.md` §4.4에 정리됨(캡처 시점, surface-UUID
  스크롤백 키잉, 탭/창 닫기 구분, 복원 순서).
- Zig 코어 신규 API: `ghostty_surface_dump_scrollback_styled`,
  `ghostty_surface_write_styled_to_screen` (`src/apprt/embedded.zig`,
  `include/ghostty.h`) + `src/termio/Exec.zig` write 버퍼 64→4096.
  리베이스 시 유실되면 색상 스크롤백 복원이 깨진다.
- Golden Rule: Wavetty 코드는 `macos/Sources/Features/` 하위에 격리,
  upstream 파일 수정은 `// Wavetty:` 주석 + 최소 diff.
- 빌드 제약: build.zig 패닉 방지 위해 HEAD가 버전 태그 커밋보다 앞서야 함.
