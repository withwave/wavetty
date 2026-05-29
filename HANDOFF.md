# 작업 인계 — 2026-05-29

## 현재 작업
**Wavetty 1.3.7-withwave 릴리즈 완료, 후속 작업 대기 중.** 이번 사이클은 창 단위 세션 복구, SSH 자동 감지/Keychain 암호 자동입력, 메뉴바/Dock SSH 진입점, 매니저 UX 다듬기(빠른 오픈·전체행 클릭·알리아스 편집)까지 마치고 모든 변경을 `withwave/wavetty:main`에 푸시·릴리즈한 상태. 새 지시 없으면 정지.

## 최근 결정
- **저장소 이름 `withwave/ghostty` → `withwave/wavetty`로 변경** (`gh repo rename` 사용). 제품명과 일치, fork 관계는 유지. GitHub 301 리다이렉트로 기존 설치본 업데이트 체크도 계속 동작.
- **세션 복구는 macOS 네이티브가 아니라 자체 구현** — `window-save-state=default` 유지하고 Wavetty 자체 LRU(최대 16, 내용 시그니처 dedup). 정상 종료/강제 킬 모두에서 디스크에 살아남도록 15초 주기 스윕 + termination/resign-key 훅 + ssh connect 직후 즉시 스냅샷.
- **세션 복구 = 창 단위(탭+분할+위치+ssh 재접속)**. 디렉토리 평면 리스트가 아닌 `TerminalController(withSurfaceTree:)` + `addTabbedWindowSafely` 사용해 전체 구조 재현. ssh 탭은 포그라운드 PID로 감지(`ghostty_surface_pwd` 폴백 + `KERN_PROCARGS2`).
- **명령 팔레트 스크롤 먹통 원인 = 호버 폭주** — `@State hoveredOptionID`가 `CommandPaletteView` 최상위에 있어 휠 스크롤 시 호버 변화마다 팔레트 전체 body 재평가(3556회/세션 측정). `CommandTable`로 호버 상태를 내려서 해결.
- **SSH 매니저 첫 오픈이 3~5초 걸리던 원인 = `NavigationSplitView`**. `HSplitView`로 교체 → ~60ms (계측 확인). 컨트롤러 strong-ref로 재오픈도 즉시.
- **SSH 암호 자동입력은 `SSH_ASKPASS` + Keychain**. `security` CLI 일관 사용(저장도 읽기도) → ACL 추가 인증 팝업 회피. `-T /usr/bin/security`로 신뢰. 헬퍼 스크립트가 `$WAVETTY_SSH_ALIAS`로 항목 식별.
- **타이틀바 버튼은 의도적으로 채택 안 함** — 업스트림 타이틀바(TitlebarTabsTahoe/Ventura/Hidden/Transparent)가 복잡해 rebase 충돌 위험 큼. 메뉴바 + Dock으로 발견성 확보.
- **About에 ghostty 포크 명시·원본 링크·MIT 크레딧 추가**. Ghostty가 MIT라 fork·리브랜딩 OK, 가시적 attribution까지 넣어 라이선스 의무 충족.

## 변경 파일 (전체 이번 사이클)
신규 (Wavetty 격리 디렉토리 — rebase 안전):
- `macos/Sources/Features/Sessions/SessionHistoryStore.swift` — 세션 캡처·복구·저장(`recent-windows.json`)
- `macos/Sources/Features/Hosts/SSHProcessInspector.swift` — sysctl(KERN_PROCARGS2)로 포그라운드 ssh 감지
- `macos/Sources/Features/Hosts/SSHKeychain.swift` — `security` CLI 래핑한 호스트별 암호 저장/조회
- `macos/Sources/Features/Hosts/SSHAskpass.swift` — askpass 헬퍼 스크립트 + ssh 환경변수
- `macos/Sources/Features/Hosts/SSHMenuController.swift` — 메뉴바 "SSH" 메뉴(코드로 삽입, xib 미수정)

수정 (소량, Wavetty 마커):
- `macos/Sources/App/macOS/AppDelegate.swift` — 런치 워머(`SessionHistoryStore`, `SSHMenuController.install()`), `reloadDockMenu()`에 Recent Windows + SSH Hosts 섹션 추가
- `macos/Sources/Features/Command Palette/CommandPalette.swift` — `dynamicOptions:` 파라미터(이전) + `hoveredOptionID`를 `CommandTable`로 이동(폭주 수정)
- `macos/Sources/Features/Hosts/SSHHostStore.swift` — `open(_:inNewWindow:)` 추가, `renameHost(from:to:)` 추가, `connect()`에 SessionHistoryStore captureNow
- `macos/Sources/Features/Hosts/SSHHostManagerView.swift` — `NavigationSplitView→HSplitView`, strong-ref 윈도우 컨트롤러, 전체행 클릭, 단/더블 분리, Authentication 섹션(암호 저장), 알리아스 편집(`onRename` 콜백)
- `macos/Sources/Features/About/AboutView.swift` — 제목 "Wavetty", `githubURL`→withwave/wavetty, `ghosttyURL` 추가, 포크 attribution + MIT 크레딧
- `macos/Sources/Features/Update/WavettyUpdateChecker.swift` — `releaseAPI`/`releasesPage`를 withwave/wavetty로
- `scripts/build-wavetty.sh`, `scripts/release-wavetty.sh` — `GITHUB_REPO="withwave/wavetty"`
- `WAVETTY.md`, `RELEASING-WITHWAVE.md` — 리포명 갱신, 신규 기능 문서화

## 다음 할 일
- [ ] **업스트림 rebase 한 번 돌리기** — 1.3.5~1.3.7 모두 `--skip-rebase`로 릴리즈했음. 너무 오래 미루면 충돌 면적 커짐
- [ ] (옵션) **SSH 매니저: User/Port/HostName도 편집 가능**하게 — 지금은 Alias만 편집됨, 나머지는 "edit ~/.ssh/config" 안내만
- [ ] (옵션) **SSH 키 인증 도우미** 추가 — 키 생성 + `ssh-copy-id` 버튼 (대화에서 권장했으나 미구현)
- [ ] (옵션) **WAVETTY.md 업데이트** — 알리아스 편집 기능 + 1.3.6/1.3.7 변경점 반영
- [ ] (옵션) **git author email 변경** — 현재 공개 저장소에 개인 gmail 노출. 향후 커밋은 `id+nick@users.noreply.github.com`로 가릴 수 있음

## 참고

**현재 상태**
- 작업 트리 clean, HEAD = `14957b56b` = `v1.3.7-withwave` 태그 위치
- 원격 `origin` = `https://github.com/withwave/wavetty.git`
- 로컬 설치본 `/Applications/Wavetty.app` 실행 중

**자주 부딪히는 함정 (시간 낭비 방지)**
1. **HEAD가 정확히 태그 커밋에 있으면 빌드 패닉** — `src/build/Config.zig:278` ("tagged releases must be in vX.Y.Z format")가 `-withwave` 접미사를 거부. **반드시 새 커밋을 만들어 HEAD를 태그 너머로** 이동시킨 뒤 빌드. 보통 코드 변경 커밋이 그 역할을 하지만, 빈 변경만 있을 땐 의도적으로 한 줄 커밋 필요
2. **DerivedData 캐시가 소스 변경을 가릴 수 있음** — 빌드해도 바뀐 코드가 안 박히면 `rm -rf ~/Library/Developer/Xcode/DerivedData/Ghostty-*` 후 재빌드. 의심되면 `strings zig-out/Wavetty.app/Contents/MacOS/wavetty | grep <기대 문자열>`로 직접 검증
3. **강제 킬 직후 `open -a Wavetty`가 LaunchServices 스로틀로 안 뜸** — 직접 실행 `"/Applications/Wavetty.app/Contents/MacOS/wavetty" >/tmp/x.log 2>&1 &` 사용
4. **`sed`로 4바이트 UTF-8 이모지(🌊 등) 치환 실패** — Python `str.replace()` 사용
5. **macOS sed의 `-i ''`** — Linux 호환성 잃지만 이 프로젝트는 macOS-only라 OK
6. **Xcode 동기화 그룹** — `macos/Sources/Features/<NewDir>/<NewFile>.swift` 추가만 하면 자동 인식. `project.pbxproj` 수정 불필요

**릴리즈 파이프라인** (`scripts/release-wavetty.sh`)
- 표준 호출: `./scripts/release-wavetty.sh --skip-rebase --bump X.Y.Z-withwave`
- 흐름: clean 체크 → (rebase 옵션) → VERSION 커밋 → DMG 빌드 → 공증 → 푸시 → `gh release create`
- **태그·릴리즈는 푸시 후에 생성**되도록 순서 잡혀 있음(`scripts/release-wavetty.sh:117-150`)
- 서명 ID `MODIN COMPANY (8AC9KUZJ5P)`, notary profile `modin-notary`(로컬 키체인에만 존재)

**핵심 코드 위치**
- 세션 캡처 시작점: `SessionHistoryStore.swift:121` (`sweepAllWindows`) → 그룹별 `snapshotGroup` → leaf 노드 빌드
- 세션 복구: `SessionHistoryStore.swift:285` (`restore(_:)`) — 첫 컨트롤러는 `showWindow` 명시 호출, 추가 탭은 `addTabbedWindowSafely`
- ssh 라이브 감지: `SessionHistoryStore.swift:198` (`sshAlias(of:)`) → `SSHProcessInspector.arguments` → `sshURI`
- 명령 팔레트 호버 스코프 수정: `CommandPalette.swift:297` 부근 (`CommandTable` 내부 `@State hoveredOptionID`)
- 매니저 단일/더블 분리: `SSHHostManagerView.swift` ForEach 내부 `.onTapGesture(count:2)` then `.onTapGesture(count:1)`
- 알리아스 rename: `SSHHostStore.swift:201` (`renameHost`) — config 블록 교체 + 메타데이터/키체인/세션 마이그레이션
- About fork attribution: `AboutView.swift:140` 부근(`ghosttyURL` Link + MIT 크레딧)

**Golden Rule (재인식)**
- Zig core(`src/`), C ABI(`include/ghostty.h`), 매크로 브리지(`macos/Sources/Ghostty/Ghostty.*.swift`) **수정 금지**
- 업스트림 Swift 파일 수정 시 **`// Wavetty:` 마커 + 10줄 이하** 유지
- 새 기능은 `macos/Sources/Features/<NewDir>/`에 격리
- 자세한 정책: `WAVETTY.md` §3 참고
