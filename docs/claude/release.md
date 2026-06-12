> **언제 읽나**: 새 버전을 배포할 때(릴리스). 버전 bump·`make dist`·GitHub Release·Homebrew cask 갱신의 전체 순서와 함정. 한 단계라도 빠지면 일부 사용자가 업데이트를 못 받는다.

# 릴리스 (Release)

DockPeek 의 "릴리스" 는 **GitHub Release zip 업로드 + Homebrew cask 갱신** 둘 다를 끝내는 것이다. 둘 중 하나만 하면 절반의 사용자만 업데이트를 받는다:

- **앱 내장 자동 업데이트(`UpdateChecker`)** → GitHub Release zip 을 본다.
- **`brew upgrade --cask dockpeek`** → `zerry-lab/homebrew-tap` 의 cask 를 본다.

> **릴리스 = 즉시 전체 배포다.** `UpdateChecker` 가 기존 사용자 앱을 자동 교체하므로, 반드시 **`make dev` 로 동작 확인을 끝낸 뒤** 올린다. 잘못 올리면 self-update 로 전 사용자에게 즉시 퍼진다.

## 자동 업데이트 메커니즘 (`UpdateChecker.swift`)

릴리스 절차를 이해하려면 사용자 쪽에서 무슨 일이 벌어지는지부터 알아야 한다.

1. **폴링** — `https://api.github.com/repos/ongjin/dockpeek/releases/latest` 를 GET (기본 `daily`, 설정에서 `weekly` 가능). 태그(`v1.5.22`)에서 `v` 를 떼고 로컬 `CFBundleShortVersionString` 과 semver 비교(`compareVersions`).
2. **다운로드/설치(`downloadAndInstall`)** — release asset zip 다운로드 → `/usr/bin/unzip -o` 로 temp 에 풀고 → **`codesign --verify --deep --strict` 로 검증**(`verifyCodeSignature`) → 통과하면 `/Applications/DockPeek.app` 교체 → `relaunchApp`(`sleep 0.5 && open /Applications/DockPeek.app` 후 현재 인스턴스 `terminate`).

함의:
- **self-signed 라도 `codesign --verify` 가 valid 면 통과**한다. 그래서 배포 zip 도 반드시 유효 서명이어야 한다 — `make dist`(→`make release`)가 `SIGN_ID="DockPeek Development"` 로 재서명하므로 정상 경로로 만들면 자동 충족.
- 서명이 깨진 zip 을 올리면 사용자 쪽 self-update 가 조용히 실패한다(`--strict`).
- repo 는 코드에 **하드코딩**(`ongjin/dockpeek`). repo 이름을 바꾸면 `UpdateChecker.swift:21` 도 고쳐야 한다.

## 사전 조건

- `make dev` 로 변경 동작을 실제 확인 완료.
- 깨끗한 working tree(또는 의도한 변경만 커밋됨).
- `gh` 가 `ongjin` 계정으로 인증됨(`gh auth status`).
- `zerry-lab/homebrew-tap` 이 로컬에 체크아웃돼 있음(보통 `../homebrew-tap`).

## 단계별 절차

### 1. 버전 bump (두 곳 동시)

**반드시 두 파일을 같은 값으로 맞춘다:**

| 파일 | 키 | 비고 |
|---|---|---|
| `Makefile` | `VERSION := X.Y.Z` (4번째 줄) | swiftc 빌드/zip 파일명 등에 쓰임 |
| `DockPeek/Info.plist` | `CFBundleShortVersionString` | **사용자에게 보이는 실제 버전**. self-update 비교 기준 |

- `CFBundleVersion` 은 `1` 로 **고정**(빌드 번호, 안 올린다).
- `project.yml` 의 `MARKETING_VERSION`(`1.0.0`)은 **stale 이며 안 쓰인다** — swiftc 빌드는 `Info.plist` 를 그대로 복사하기 때문(XcodeGen 경로에서만 의미 있음). 건드리지 말 것.
- 커밋 메시지 관례: **`Bump version to X.Y.Z`** (버전 bump 는 보통 기능/버그픽스 커밋과 분리).

```bash
# Makefile 4줄, Info.plist CFBundleShortVersionString 수정 후
git add Makefile DockPeek/Info.plist
git commit -m "Bump version to X.Y.Z"
```

### 2. `make dist` — 빌드 + zip + sha256

```bash
make dist
```

- `make release`(swiftc `-O -whole-module-optimization`) → `build/Release/DockPeek.app` 생성 + `SIGN_ID` 로 재서명.
- `build/Release` 에서 `zip -r DockPeek.zip DockPeek.app` → **`DockPeek.zip`** (레포 루트, **gitignore 됨**).
- 마지막 줄에 `shasum -a 256 DockPeek.zip` 출력 → **이 해시를 메모**(4단계 cask 에 들어간다).

검증(선택이지만 권장):
```bash
/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/Release/DockPeek.app/Contents/Info.plist  # X.Y.Z 확인
codesign --verify --strict build/Release/DockPeek.app && echo valid                                          # self-update 통과 보장
```

### 3. push + GitHub Release 생성

```bash
git push origin main
gh release create vX.Y.Z DockPeek.zip --repo ongjin/dockpeek \
  --title "vX.Y.Z" \
  --notes "- 사용자 관점 변경점 1
- 변경점 2"
```

- 태그는 **`vX.Y.Z`** (앞에 `v`). asset 이름은 **반드시 `DockPeek.zip`** — cask 의 `url` 템플릿(`…/v#{version}/DockPeek.zip`)과 self-update 가 이 이름에 의존한다.
- `--notes` 는 사용자에게 보이는 changelog(앱 내 업데이트 안내에도 `releaseBody` 로 노출). 내부 구현 용어 말고 동작 변화로.

### 4. Homebrew cask 갱신 (릴리스의 실제 종착점)

별도 repo `github.com/zerry-lab/homebrew-tap` 의 `Casks/dockpeek.rb`. `url` 이 `…/v#{version}/DockPeek.zip` 템플릿이라 **`version`·`sha256` 두 줄만** 바꾼다.

```bash
git -C ../homebrew-tap pull --ff-only      # 최신화 (push 거절 방지)
# Casks/dockpeek.rb 의 version "X.Y.Z" 와 sha256 "..." 수정
#   sha256 = 2단계 make dist 출력값 = 업로드된 asset 해시
git -C ../homebrew-tap add Casks/dockpeek.rb
git -C ../homebrew-tap commit -m "Update dockpeek to X.Y.Z"
git -C ../homebrew-tap push origin main
```

> **sha256 불일치 = brew 설치 실패.** cask 의 sha256 은 GitHub 에 올라간 asset 의 해시와 정확히 같아야 한다. `make dist` 출력 = 업로드한 zip = asset 이므로 정상 경로면 일치하지만, 의심되면 5단계로 확인.

### 5. 최종 해시 검증 (권장)

업로드된 asset 을 실제로 받아 cask sha256 과 대조 — brew 사용자가 checksum mismatch 를 안 겪게:

```bash
gh release download vX.Y.Z --repo ongjin/dockpeek --pattern DockPeek.zip --output /tmp/verify.zip
shasum -a 256 /tmp/verify.zip    # cask 의 sha256 과 동일해야 함
```

## 함정

- **① cask 가 stale 되기 쉽다** — 과거 cask 가 1.5.13 에 멈춰 brew 사용자가 1.5.14~1.5.20 을 통째로 놓친 적 있음. **릴리스마다 4단계를 빼먹지 말 것.** (GitHub Release 만 올리고 cask 를 안 올리는 게 가장 흔한 실수.)
- **② 개발 머신에서 `brew upgrade` 금지** — `make dev` 는 `/Applications/DockPeek.app` 번들 안 바이너리만 교체하지만, `brew upgrade --cask dockpeek` 는 번들을 통째로 갈아끼워 **손쉬운 사용/화면 기록 권한이 날아간다**. 코드는 같으니 개발 머신에선 그냥 둔다.
- **③ self-signed → Gatekeeper 경고 + 일부 백신 false-positive** — Apple Developer ID 미서명 + system-wide event tap + private SkyLight API 조합. **의도된 트레이드오프**다(고치려고 private API 를 들어내면 그게 곧 기능 상실). cask 의 `postflight` 가 `xattr -dr com.apple.quarantine` 로 quarantine 을 떼고, `caveats` 가 첫 실행/권한 안내를 한다. 자세한 배경은 [private-apis.md](private-apis.md).

## 워크드 예시 — v1.5.22 (2026-06)

hover 미리보기 dismiss 2건 수정 후 릴리스한 실제 기록:

```bash
# 1. 픽스 커밋 + 버전 bump (1.5.21 → 1.5.22)
git commit -m "Fix lingering hover previews when leaving the Dock"
#   Makefile VERSION, Info.plist CFBundleShortVersionString 수정
git commit -m "Bump version to 1.5.22"

# 2. dist → sha256: ab48e66ed7bf6be2771ccfabbc3afb5541121bcdd10b0e28a7d25cfadb9291a4
make dist

# 3. push + release
git push origin main
gh release create v1.5.22 DockPeek.zip --repo ongjin/dockpeek --title "v1.5.22" --notes "..."

# 4. cask: version 1.5.22 + 위 sha256 → zerry-lab/homebrew-tap 커밋/푸시
# 5. gh release download 로 재해시 → 일치 확인
```

## 체크리스트

- [ ] `make dev` 로 동작 확인 완료
- [ ] `Makefile VERSION` == `Info.plist CFBundleShortVersionString` == `X.Y.Z`
- [ ] `Bump version to X.Y.Z` 커밋
- [ ] `make dist` → sha256 메모, 번들 버전·codesign 확인
- [ ] `git push origin main`
- [ ] `gh release create vX.Y.Z DockPeek.zip`(asset 이름 `DockPeek.zip`)
- [ ] `homebrew-tap/Casks/dockpeek.rb` 의 `version`+`sha256` 갱신 후 커밋/푸시
- [ ] asset 재다운로드 해시 == cask sha256
