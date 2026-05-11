# Releasing Wavetty (withwave fork)

withwave/ghostty 포크는 **Wavetty**라는 별개의 앱으로 빌드/배포됩니다. Apple Developer ID 서명 + 공증 + GitHub Release 전체 파이프라인이 `scripts/build-wavetty.sh` 스크립트로 자동화되어 있습니다.

## 결과물

- **앱 이름**: Wavetty
- **번들 ID**: `com.modincompany.wavetty` (upstream `com.mitchellh.ghostty`와 분리)
- **데이터 위치**: `~/Library/Application Support/com.modincompany.wavetty/`
- **자동 업데이트**: 비활성 — GitHub Releases에서 수동 체크
- **아이콘**: 커스텀 wave 디자인 (`scripts/icon.icns`)
- **서명**: Apple Developer ID Application: MODIN COMPANY (8AC9KUZJ5P)

## 빠른 빌드

```bash
# 빌드만
./scripts/build-wavetty.sh

# 빌드 + DMG 생성 + 공증 + Stapler
./scripts/build-wavetty.sh --dmg

# 빌드 + DMG + 공증 + 기존 GitHub Release에 자산 업로드
./scripts/build-wavetty.sh --release
```

## End-to-End 릴리즈 (rebase → 빌드 → 공증 → 릴리즈 → 푸시)

```bash
# 동일 버전 재빌드 (rebase + build + DMG + 공증 + release + tag + push)
./scripts/release-wavetty.sh

# 새 버전 (VERSION을 1.3.3-withwave로 올리고 새 릴리즈)
./scripts/release-wavetty.sh --bump 1.3.3-withwave

# upstream rebase 건너뛰기 (충돌 해결 후 이어서 진행)
./scripts/release-wavetty.sh --skip-rebase
```

전제: working tree 깨끗, `upstream` remote 설정됨, `gh` 인증 완료, notarytool keychain profile 등록됨.

## 사전 준비 (최초 1회)

### 1. Apple Developer 계정

- Apple Developer Program 가입 ($99/년)
- 팀 ID: `8AC9KUZJ5P` (MODIN COMPANY)
- Apple ID: 메인 계정 이메일

### 2. App-Specific Password 생성

Notarization용 앱 전용 비밀번호:
1. https://account.apple.com/sign-in 접속
2. **로그인 및 보안** → **앱 암호** → `+`
3. 라벨 입력 후 16자리 암호 복사

### 3. Developer ID Application 인증서

#### CSR 생성 (터미널)

```bash
openssl req -new -newkey rsa:2048 -nodes \
  -keyout ~/MODIN_developer.key \
  -out ~/MODIN_developer.certSigningRequest \
  -subj "/emailAddress=YOUR_EMAIL/CN=COMPANY_NAME/C=KR"
```

#### 인증서 발급

1. https://developer.apple.com/account/resources/certificates 접속
2. `+` → `Software` > `Developer ID Application`
3. **Profile Type**: `G2 Sub-CA (Xcode 11.4.1 or later)`
4. CSR 업로드 → `.cer` 다운로드

#### Keychain 등록

```bash
# DER → PEM 변환
openssl x509 -inform der -in ~/developerID_application.cer -out ~/developerID_application.pem

# .p12 묶음 (legacy 포맷 필수, macOS keychain 호환)
openssl pkcs12 -export -legacy \
  -inkey ~/MODIN_developer.key \
  -in ~/developerID_application.pem \
  -out ~/MODIN_developerID.p12 \
  -name "Developer ID Application: COMPANY_NAME" \
  -password pass:PASSWORD

# Keychain import
security import ~/MODIN_developerID.p12 \
  -k ~/Library/Keychains/login.keychain-db \
  -P "PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security

# 확인
security find-identity -v -p codesigning
```

### 4. Notarytool 자격증명 등록

```bash
xcrun notarytool store-credentials "modin-notary" \
  --apple-id "APPLE_ID_EMAIL" \
  --team-id "8AC9KUZJ5P" \
  --password "APP_SPECIFIC_PASSWORD"
```

### 5. Patched Zig 설치 (Xcode 26.4 호환)

```bash
brew install zig@0.15
```

표준 Zig 0.15.2는 Xcode 26.4와 링크 에러가 발생하므로 brew bottle (패치 버전) 사용 필수.

### 6. Metal Toolchain (Xcode 업데이트 후 필요시)

```bash
xcodebuild -downloadComponent MetalToolchain
```

## 스크립트 동작 원리

`scripts/build-wavetty.sh`는 **upstream 파일을 전혀 건드리지 않습니다**. 모든 리브랜딩은 `zig build` 결과물에 후처리로 적용:

1. `zig build -Doptimize=ReleaseFast` 실행
2. 빌드된 `Ghostty.app` 의 `Info.plist` 를 `plutil` 로 수정:
   - `CFBundleName` / `CFBundleDisplayName` → `Wavetty`
   - `CFBundleIdentifier` → `com.modincompany.wavetty`
   - `CFBundleShortVersionString` → `VERSION` 파일 내용
   - `SUPublicEDKey` 제거, `SUEnableAutomaticChecks = false`
3. `scripts/icon.icns` 가 있으면 `Ghostty.icns` 교체
4. Developer ID 서명 (hardened runtime + timestamp)
5. (`--dmg`) DMG 생성 + 서명
6. (`--dmg`) Apple Notarization 제출 → Stapler
7. (`--release`) GitHub Release 자산 업로드

→ `git rebase upstream/main` 시 충돌 가능성 0.

## 트러블슈팅

### `MAC verification failed during PKCS12 import`
→ openssl이 신형 포맷으로 묶어서 macOS keychain이 못 읽음. `-legacy` 옵션 추가.

### `undefined symbol: __availability_version_check` 등 링크 에러
→ Xcode 26.4 + 표준 Zig 0.15.2 비호환. `brew install zig@0.15` 사용.

### `cannot execute tool 'metal' due to missing Metal Toolchain`
→ Xcode 업데이트 직후. `xcodebuild -downloadComponent MetalToolchain` 재설치.

### Notarization `Invalid` 응답
→ `xcrun notarytool log <SUBMISSION_ID> --keychain-profile modin-notary` 로 상세 확인. 흔한 원인:
- Hardened runtime 미적용 → `--options runtime`
- Timestamp 누락 → `--timestamp`
- 일부 바이너리 미서명 → `--deep`

### 사용자 측 Gatekeeper 경고
공증 + Stapler가 제대로 됐다면 발생 안 함. 만약 경고가 보이면:
```bash
xattr -cr /Applications/Wavetty.app
```
또는 우클릭 → 열기.

## 향후 개선 후보

- **Sparkle 자동 업데이트**: 별도 EdDSA 키 생성 + appcast.xml 호스팅 + Swift `UpdateDelegate` 분기 처리 필요. 작업량 큼.
- **더 정교한 아이콘**: 현재는 ImageMagick 패스로 그린 단순 디자인. 디자이너 개입 시 교체.
- **데이터 마이그레이션**: 기존 `com.mitchellh.ghostty` 디렉토리에서 자동 복사하는 옵션.

## 데이터 위치 변경 안내

기존 Ghostty 사용자가 Wavetty로 전환할 경우:

```bash
# 설정 복사
cp ~/Library/Application\ Support/com.mitchellh.ghostty/config \
   ~/Library/Application\ Support/com.modincompany.wavetty/config
```

스크롤백/세션 상태는 자동 복원되지 않습니다 (별개의 앱이므로).
