# Releasing (withwave fork)

withwave/ghostty 포크의 릴리즈 빌드, 코드 서명, Apple 공증, GitHub Release 배포 절차.

## 사전 준비

### 1. Apple Developer 계정

- Apple Developer Program 가입 ($99/년)
- 팀 ID 확인: 예) `8AC9KUZJ5P` (MODIN COMPANY)
- Apple ID 이메일: 예) `sspark.modin@gmail.com`

### 2. App-Specific Password

Notarization용 앱 전용 비밀번호 생성:
1. https://account.apple.com/sign-in 접속
2. **로그인 및 보안** → **앱 암호** → `+`
3. 라벨 입력 (예: `Ghostty Notarization`) → 16자리 암호 복사

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
4. 위에서 생성한 `.certSigningRequest` 업로드
5. `.cer` 다운로드

#### Keychain 등록

```bash
# DER → PEM 변환
openssl x509 -inform der -in ~/developerID_application.cer -out ~/developerID_application.pem

# .p12 묶음 생성 (legacy 포맷 필수, macOS keychain 호환)
openssl pkcs12 -export -legacy \
  -inkey ~/MODIN_developer.key \
  -in ~/developerID_application.pem \
  -out ~/MODIN_developerID.p12 \
  -name "Developer ID Application: COMPANY_NAME" \
  -password pass:PASSWORD

# Keychain에 import
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
  --team-id "TEAM_ID" \
  --password "APP_SPECIFIC_PASSWORD"
```

이후 `--keychain-profile "modin-notary"` 로 재사용.

## 릴리즈 빌드 절차

### 1. 릴리즈 빌드

```bash
# Xcode 26.4 호환을 위해 patched zig 사용
PATH=/opt/homebrew/opt/zig@0.15/bin:$PATH \
  zig build -Doptimize=ReleaseFast
```

> **Note**: Xcode 26.4 + 표준 Zig 0.15.2는 링크 에러 발생.
> `brew install zig@0.15` 로 패치된 버전 사용 필수.

### 2. 코드 서명 (Developer ID + Hardened Runtime + Timestamp)

```bash
codesign --force --deep --sign "Developer ID Application: MODIN COMPANY (8AC9KUZJ5P)" \
  --options runtime \
  --entitlements macos/GhosttyReleaseLocal.entitlements \
  --timestamp \
  zig-out/Ghostty.app

# 검증
codesign --verify --deep --strict --verbose=2 zig-out/Ghostty.app
```

### 3. DMG 패키징

```bash
hdiutil create -volname "Ghostty" \
  -srcfolder zig-out/Ghostty.app \
  -ov -format UDZO \
  zig-out/Ghostty.dmg

# DMG도 서명
codesign --force --sign "Developer ID Application: MODIN COMPANY (8AC9KUZJ5P)" \
  --timestamp \
  zig-out/Ghostty.dmg
```

### 4. Notarization 제출

```bash
xcrun notarytool submit zig-out/Ghostty.dmg \
  --keychain-profile "modin-notary" \
  --wait
```

`status: Accepted` 가 떠야 성공. 보통 1-5분 소요.

거절되면:
```bash
xcrun notarytool log <SUBMISSION_ID> --keychain-profile "modin-notary"
```

### 5. Stapler (공증 영구 첨부)

```bash
xcrun stapler staple zig-out/Ghostty.dmg

# 검증
xcrun stapler validate zig-out/Ghostty.dmg
spctl -a -t open --context context:primary-signature -v zig-out/Ghostty.dmg
# → "source=Notarized Developer ID" 표시되면 OK
```

### 6. GitHub Release 업로드

```bash
gh release create vX.Y.Z-withwave \
  zig-out/Ghostty.dmg \
  --repo withwave/ghostty \
  --target main \
  --title "vX.Y.Z-withwave: ..." \
  --notes "..."

# 또는 기존 릴리즈에 자산 교체
gh release upload vX.Y.Z-withwave zig-out/Ghostty.dmg \
  --repo withwave/ghostty --clobber
```

## 한 번에 빌드+서명+공증+배포

전체 절차를 자동화하려면 `scripts/release-withwave.sh` 같은 스크립트 작성을 권장.

핵심 변수:
- `IDENTITY="Developer ID Application: MODIN COMPANY (8AC9KUZJ5P)"`
- `NOTARY_PROFILE="modin-notary"`
- `ENTITLEMENTS="macos/GhosttyReleaseLocal.entitlements"`

## 트러블슈팅

### `MAC verification failed during PKCS12 import`
→ openssl이 신형 포맷으로 묶어서 macOS keychain이 못 읽음. `-legacy` 옵션 추가.

### `undefined symbol: __availability_version_check` 등 링크 에러
→ Xcode 26.4 + 표준 Zig 0.15.2 비호환. `brew install zig@0.15` 사용.

### `cannot execute tool 'metal' due to missing Metal Toolchain`
→ Xcode 업데이트 직후. 다음 명령어로 재설치:
```bash
xcodebuild -downloadComponent MetalToolchain
```

### Notarization `Invalid` 응답
→ `notarytool log` 로 상세 에러 확인. 흔한 원인:
- Hardened runtime 미적용 → `--options runtime` 빠짐
- Timestamp 누락 → `--timestamp` 빠짐
- 일부 바이너리 미서명 → `--deep` 옵션 빠짐

### Gatekeeper 계속 차단
→ Stapler 누락 가능성. 네트워크 없는 환경에서는 stapler 필수.
