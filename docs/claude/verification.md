> **언제 읽나**: 프리뷰·hover·클릭 경로를 고쳤거나 릴리스 직전일 때. `make test`·`make e2e` 가 무엇을 검증하고 무엇을 못 하는지, e2e 를 안전하게 돌리는 법.

# 검증 (make test / make e2e)

자동 검증은 두 층이다. 둘 다 SwiftPM 없이 `Makefile` 이 `swiftc` 로 빌드한다. 산출물은 `build/` 아래라 git 에 안 잡힌다.

## make test: 순수 로직

`Tests/Checks.swift` 를 앱 소스 전체(진입점 `DockPeekApp.swift` 제외)와 함께 컴파일해 실행한다. 권한·UI·커서 없이 수 초에 끝난다.

| 검사 | 대상 |
|---|---|
| 버전 비교 | `UpdateChecker.compareVersions` (자가 업데이트 안내 여부를 결정) |
| 썸네일 축소 | `WindowManager.downscale` (픽셀·포인트 크기, 업스케일 금지, 색공간 유지, fallback) |
| 카드 줄 맞춤 | `PreviewMetrics.rowWidth` / `fittedThumbnailSize` |
| L10n 키 일치 | `en`·`ko` dict 키 집합과 `s("…")` 접근자 키 |

- L10n 검사는 dict 가 `private` 이라 **소스 파일을 읽어서** 한다. 그래서 레포 루트에서 실행해야 한다(`make test` 는 그렇게 돈다).
- 새 순수 함수를 만들면 여기에 검사를 더한다. Dock·권한·창이 필요한 건 e2e 로 보낸다.

## make e2e: 실제 앱

`scripts/e2e.swift` 가 **실제 커서를 움직이고 클릭**하면서, `/Applications/DockPeek.app` 에서 돌고 있는 DockPeek 을 밖에서 관찰한다. 프리뷰 패널(`popUpMenu` 레벨)과 오버레이(그 한 단계 아래)를 `CGWindowListCopyWindowInfo` 로 보고, 창 전환은 창 z-순서로 확인한다. 스크린샷은 `build/e2e/` 에 남는다.

기본 대상은 **stand-in 앱**(`scripts/e2e-target.swift`)이다. 창 N개를 띄우는 더미 앱을 실행 때 띄우고 끝나면 종료한다. 카드 클릭이 사용자의 실제 창에 가지 않게 하려는 것이다. 창마다 위치가 달라 카드↔창 대응도 분명하다.

```bash
make e2e                               # 전체: hover, 카드 오버레이, 카드 클릭, 닫힘, 앱 전환, 클릭 프리뷰, Esc
make e2e E2E_ARGS=--hover-only         # hover 프리뷰만 (클릭·포커스 변화 없음)
make e2e E2E_ARGS=--plan               # Dock 앱 목록만 출력 (입력 안 보냄)
make e2e E2E_ARGS=--dock-restart       # 전체 + Dock 재시작 후 복구 확인
make e2e E2E_ARGS="--hover-only --windows=12"   # 창 12개: 화면 폭 넘침 검사
make e2e E2E_ARGS="--hover-only --app=Chrome"   # stand-in 대신 실제 앱에 hover
```

전제: DockPeek 실행 중, 실행하는 터미널에 손쉬운 사용 권한(스크린샷은 화면 기록 권한).

### 릴리스 빌드를 검증하려면

e2e 는 설치본에서 돌고 있는 바이너리를 본다. `make dev` 는 디버그 바이너리를 넣으므로, 배포할 릴리스 빌드를 검증할 땐 같은 방식으로 릴리스 바이너리를 넣는다(권한 유지).

```bash
make release
pkill -x DockPeek
cp build/Release/DockPeek.app/Contents/MacOS/DockPeek /Applications/DockPeek.app/Contents/MacOS/DockPeek
cp DockPeek/Info.plist /Applications/DockPeek.app/Contents/Info.plist
codesign --force --sign "DockPeek Development" /Applications/DockPeek.app
open /Applications/DockPeek.app
make e2e
```

검증이 끝난 `build/Release` 번들을 그대로 zip 하면 검증한 바이너리가 곧 배포본이 된다(`make dist` 는 다시 빌드한다).

### 손을 떼야 한다

실행 중엔 마우스·키보드를 쓰면 안 된다. 스크립트가 지키는 것:

- 시작 전 입력이 2초 이상 없을 때까지 최대 30초 기다리고, 안 되면 아무것도 보내지 않고 끝낸다.
- 실행 중 커서가 스크립트가 세워 둔 자리에서 벗어났거나 키 입력이 있었으면 `ABORT` 하고 커서·앞 앱을 되돌린다.
- 합성 마우스 이벤트도 `hidSystemState` 시계를 갱신한다(private event source 로 보내도 마찬가지). 그래서 실제 마우스 사용은 시계가 아니라 **커서 위치**로 잡는다.

사용자가 도중에 마우스를 쓰면 프리뷰가 옆 앱으로 넘어가 엉뚱한 실패가 난다. 실패가 나오면 앱을 의심하기 전에 `/usr/bin/log show --last 2m --info --predicate 'subsystem == "com.dockpeek.app"'` 에 스크립트가 보내지 않은 클릭(`Will show preview`, `Activated window`)이 있는지 본다.

### 다루지 않는 것

- 카드의 **닫기·스냅 버튼**(실제 창에 작용한다. stand-in 대상으로 넣을 수는 있으나 아직 없다).
- **권한 회수 시 입력 freeze**. [event-tap-safety.md](event-tap-safety.md) 의 수동 절차 그대로다.
- Dock 이 좌·우에 있거나 보조 모니터에 있는 배치, 자동 숨김 Dock.
- 설정·온보딩 창, 자가 업데이트.

### 만질 때

- 스크립트의 `Layout` 상수는 `PreviewMetrics`(카드 패딩·간격·비율)와 `PreviewPanel.dockGap` 을 **복사한 값**이다. 그쪽을 바꾸면 여기도 맞춘다. 안 맞으면 "panel laid out for N cards" 가 먼저 실패한다.
- 카드↔창 대응은 DockPeek 이 저장한 `windowOrderByBundle`(`com.dockpeek.app` defaults)로 구한다. 창 bounds 로 맞추면 최대화 창 두 개처럼 bounds 가 같은 경우에 틀린다.
- Dock 아이콘에서 패널로 올라갈 땐 **수직으로** 나간다. 대각선으로 가면 옆 아이콘을 스치며 프리뷰가 바뀐다.
- 최종 접근 속도는 hover 속도 게이트(1200pt/s)보다 충분히 느려야 한다(`Pace.settle`).
- 카드 클릭 지점은 썸네일 상단 38% 높이다. 좌상단 닫기 버튼과 하단 스냅 바를 피한 자리다.

## 이력

- 2026-11-11 도입. 첫 실행들에서 기존 버그 두 건을 잡았다: 창이 많은 앱의 프리뷰가 화면 밖으로 넘치던 것, 창을 고르거나 Esc 로 닫은 뒤 같은 아이콘의 hover 프리뷰가 안 뜨던 것([preview-ux.md](preview-ux.md)).
