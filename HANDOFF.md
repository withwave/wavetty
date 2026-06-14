# 작업 인계 — 2026-06-14 04:30

## 현재 작업
Wavetty(Ghostty 포크) v1.4.3 — 최근 접속 기록(Recent Windows) 관리 개선.
스크롤백 잘못된 복원 버그 수정 + Dock 메뉴에 x 삭제 버튼 추가가 완료되어 모두 커밋됨.
**아직 빌드/설치 검증 + push 가 남음.**

## 최근 결정
- **스크롤백 파일 키를 host/dir → surface UUID로 변경**: 같은 디렉토리의 여러 탭이 한 .ansi 파일을 공유해 다른 탭 내용이 복원되던 버그 때문. orphan 파일은 `cleanupOrphanScrollback`이 save() 때 정리.
- **restore() 재진입 가드(`restoringIDs`)**: 같은 항목 더블클릭/연속클릭 시 중복 복원 방지. async 복원 완료 후 ID 제거.
- **별도 "Recent Sessions 관리 창"은 만들었다가 제거함**: 사용자가 "있는 기능(Dock 메뉴)에 버튼만 추가하면 되는데 왜 창을 만드냐"고 지적 → RecentSessionsView.swift 삭제하고 Dock 메뉴 항목에 커스텀 NSView(x버튼)만 남김.
- **x 삭제 버튼은 서브메뉴가 아닌 커스텀 NSMenuItem 뷰로 구현**: 사용자가 "클릭=복원, x=삭제가 UI상 깔끔"하다고 요청. `RecentWindowMenuItemView`(NSView) — 클릭=복원, 호버 시 우측 × 페이드인=삭제.

## 변경 파일 (origin/main 대비, 모두 커밋됨)
- `VERSION` — 1.4.2 → 1.4.3-withwave
- `macos/Sources/Features/Sessions/SessionHistoryStore.swift` — surface-UUID 스크롤백 키잉, `remove(id:)`, `cleanupOrphanScrollback`, `restoringIDs` 재진입 가드
- `macos/Sources/Features/Sessions/RecentWindowMenuItem.swift` (신규) — Dock 메뉴용 커스텀 NSView(x 삭제 버튼)
- `macos/Sources/App/macOS/AppDelegate.swift` — Dock 메뉴 최근 항목을 `RecentWindowMenuItemView`로 교체, `restoreRecentWindow(_:)`/`removeRecentWindow(_:)` fileprivate 헬퍼

## 다음 할 일
- [ ] **`build-wavetty.sh`에 `--debug` 플래그 추가 작업이 중단됨** — 디버그로 컴파일하되 Wavetty 리브랜딩까지 입히는 빌드용. 인자 파싱부에 `OPTIMIZE` 변수 추가하고 `zig build -Doptimize=$OPTIMIZE`로 바꾸려던 참(아래 미해결 참고). 사용자가 "디버깅 테스트 해보자"고 한 직후 중단됨.
- [ ] 빌드(`./scripts/build-wavetty.sh`) → `/Applications/Wavetty.app` 설치 → 실행
- [ ] 검증: Dock 아이콘 우클릭 → 최근 항목 호버 시 × 버튼 표시, 클릭=복원, ×=삭제
- [ ] 검증: 스크롤백이 올바른 세션 내용으로 복원되는지 (다른 디렉토리/SSH 섞임 없는지)
- [ ] `git push` (origin/main에 로컬 4커밋 푸시)

## 미해결 / 막힌 곳
- **`build-wavetty.sh --debug` 작업 미완**: 의도는 `--debug` 시 `zig build -Doptimize=Debug`로 빌드 + 동일하게 리브랜딩. 수정 위치는 `scripts/build-wavetty.sh:40-48`(args 파싱), `scripts/build-wavetty.sh:111-112`(zig build 명령). 이유: 순수 `xcodebuild -configuration Debug` 디버그 빌드는 upstream "Ghostty"로 떠서(리브랜딩이 build-wavetty.sh 후처리에만 있음) 혼동 + AppleScript 접근성 막힘.
- **이 세션 자동화 한계**: 터미널에서 osascript/cliclick 접근성 권한이 막혀(-1719) 메뉴 자동 클릭 검증이 불가했음. UI 검증은 사용자 직접 클릭 필요.
- **도구 호출이 자주 malformed로 깨짐** (Opus 4.8/Sonnet 4.6 모두). 재시도하면 통과됨.

## 참고
- 브랜딩 메커니즘: Xcode 프로젝트 소스는 전부 upstream 값(`project.pbxproj`: `INFOPLIST_KEY_CFBundleDisplayName = Ghostty`). Wavetty 리브랜딩은 100% `build-wavetty.sh` Step 2 후처리(plutil). → **디버그 빌드는 브랜딩 안 됨이 정상.**
- 스크롤백 캡처/복원: `SessionHistoryStore.swift` — `captureNode`(캡처), `processPendingRestores`/`injectRestore`(복원), `restore(_:)` (창 재생성)
- 커스텀 메뉴뷰: `RecentWindowMenuItem.swift` — `mouseEntered/Exited`로 x버튼 페이드, `mouseUp`=복원, `removeTapped`=삭제
- Zig 코어 신규 API: `src/apprt/embedded.zig` — `ghostty_surface_dump_scrollback_styled`(VT/SGR 컬러), `ghostty_surface_write_styled_to_screen`(ANSI 해석 주입). 헤더: `include/ghostty.h`
- Golden Rule: Wavetty 코드는 `macos/Sources/Features/` 하위에 격리, upstream `src/` 수정 최소화(`// Wavetty:` 주석)
- 빌드 제약: build.zig 패닉 방지 위해 HEAD가 버전 태그 커밋보다 앞서야 함
