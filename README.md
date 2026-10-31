# LightNote — 가벼운 macOS 필기 앱

<img src="Resources/AppIcon.png" alt="연필을 든 명호쌤 LightNote 아이콘" width="128">

macOS 15 이상에서 실행하는 Swift / SwiftUI / AppKit 앱입니다. 외부 패키지, Electron, 웹뷰를 사용하지 않습니다. 벡터 필기, 모눈 용지, 획 지우개, 사각형 선택 이동, 핀치 확대·축소와 자동 저장을 지원하는 개발 중인 앱입니다.

## 구조와 설계

```text
LightNote.xcodeproj/              Xcode 앱 프로젝트와 공유 Scheme
Sources/LightNoteCore/Ink.swift   벡터 획·좌표·색상·파일 버전·입력 검증
Sources/LightNote/AppMain.swift   네이티브 앱 수명 주기·메뉴·단축키
Sources/LightNote/NoteDocument.swift
                                 NSDocument 저장·불러오기·UndoManager
Sources/LightNote/EditorView.swift
                                 SwiftUI 도구 모음·색상·두께·상태 표시
Sources/LightNote/InkCanvasView.swift
                                 NSView 입력·Core Graphics 렌더링·스크롤
Sources/LightNote/AppSelfTest.swift
                                 네이티브 이벤트 통합 검사 진입점
Tests/LightNoteCoreTests/         Swift Package 모델 테스트
scripts/build.sh                 Xcode IDE 없이 로컬 .app 빌드
```

SwiftUI는 도구 모음을 구성하고 실제 입력은 `NSView`가 직접 받습니다. 진행 중인 획은 입력 좌표 배열과 가변 CGPath에 추가합니다. 입력 루프에서는 파일 쓰기나 SwiftUI 상태 발행을 하지 않습니다. 선분 주변만 무효화하고, 완료한 획은 CGPath와 경계를 캐시해 다시 구성하지 않습니다. 겹치는 획을 원래 순서로 다시 그려 겹침과 안티앨리어싱을 유지합니다. 경로는 주변 입력점의 방향을 이용한 형태 보존 3차 곡선으로 잇습니다. 축 방향 극값과 급한 반전에서는 접선을 제한해 원본 좌표 범위 밖으로 튀는 현상을 방지하고, 약 0.5pt 간격으로 곡선을 분할합니다. 매우 긴 구간은 계산량 제한을 둡니다. 새 입력마다 한 구간만 확정하고, 아직 다음 점이 없는 마지막 구간은 최신 입력까지 즉시 표시합니다. 따라서 전체 경로를 매 이벤트마다 다시 계산하거나 다음 입력이 올 때까지 펜 끝 표시를 기다리지 않습니다. 모든 원본 입력점과 타임스탬프·압력을 보존하며, 보간점은 추가 하드웨어 샘플이 아닙니다. 표시·지우개·선택은 동일한 보간 경로를 사용하고 완료 경로는 캐시합니다.

좌표는 용지의 논리 포인트 기준이며, Retina 픽셀 배율을 곱해 저장하지 않습니다. 표시 배율은 AppKit/Core Graphics가 처리합니다. 클릭만 한 입력도 원으로 표시하고 벡터 획으로 보존합니다. 앱/창 비활성화, 디스플레이 배율 변경, 다음 mouseDown 시 미완료 획을 확정해 끊어진 입력을 이어 붙이지 않습니다.

## 실행 및 Xcode 빌드

1. `LightNote.xcodeproj`를 Xcode에서 엽니다.
2. Scheme **LightNote**, 실행 대상 **My Mac**을 선택합니다.
3. **⌘R**로 실행합니다. 배포 대상은 macOS 15.0입니다.
4. 기본 로컬 빌드는 ad-hoc 서명입니다. 외부 배포용 개발자 서명 및 공증은 별도입니다.

터미널에서도 빌드할 수 있습니다.

```sh
xcodebuild -project LightNote.xcodeproj -scheme LightNote \
  -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/LightNote.app
```

현재 개발 Mac에서는 Xcode 27.2의 `IDESimulatorFoundation`이 시스템 `DVTDownloads` 심볼을 찾지 못해 `xcodebuild` 자체가 소스 컴파일 전에 중단되었습니다. 시스템 Xcode 설치는 변경하지 않았습니다. 아래 대체 경로는 같은 소스를 설치된 Swift 컴파일러와 macOS SDK로 컴파일해 실제 `.app`을 만듭니다.

```sh
./scripts/build.sh
open build/LightNote.app
# 최적화 빌드
./scripts/build.sh release
```

빌드 스크립트는 iCloud의 Finder 속성이 서명을 다시 무효화하지 않도록 앱을 `~/Library/Caches/LightNote/Build/LightNote.app`에 빌드한 뒤 `/Applications/LightNote.app`에 설치하고, `build/LightNote.app`을 설치된 앱의 심볼릭 링크로 연결합니다. 디버그 심볼도 앱 번들 외부에 둡니다. 생성한 앱만 확장 속성 정리와 ad-hoc 서명을 수행하며, 소스 파일의 속성은 변경하지 않습니다. `LIGHTNOTE_BUILD_DIR` 환경 변수로 로컬 출력 폴더를 변경할 수 있습니다. Xcode 프로젝트를 여는 경우와 Swift Package를 여는 경우를 구분하세요. `Package.swift`는 모델 테스트용이며 앱 실행은 `.xcodeproj` 또는 빌드 스크립트를 사용합니다.

## 설치와 검색

최신 앱은 `/Applications/LightNote.app`에 설치됩니다. Spotlight 또는 Alfred에서 **LightNote**로 검색해 실행합니다. 빌드 스크립트는 캐시에서 컴파일한 뒤 `scripts/install.sh`로 설치·Launch Services 등록·Spotlight 인덱싱 요청까지 수행합니다. `/Applications` 쓰기 권한이 없으면 `~/Applications`를 사용합니다. `build/LightNote.app`은 설치된 앱을 가리킵니다. 이전 앱은 캐시의 Previous 폴더에 보존하며 노트 파일은 옮기지 않습니다.

## 사용법

- A4를 기본 크기로 하는 확장 캔버스에 마우스/트랙패드 클릭·드래그로 필기합니다. 두 손가락 스크롤로 페이지를 이동하고, 트랙패드에서 두 손가락을 벌리거나 오므리는 핀치로 25~400% 확대·축소합니다. 하단 배율 표시를 누르면 100%로 복원됩니다. 배율은 화면 보기 설정이며 저장된 벡터 좌표와 펜 두께는 바뀌지 않습니다. 줌아웃하거나 창을 넓히면 보이는 영역 전체를 덮도록 필기 공간이 확장되며, 모눈도 같은 영역에 이어집니다. 바깥 영역에 쓴 필기는 저장하고 다시 열어도 유지됩니다.
- 도구 모음에서 기본 색상 10가지 또는 사용자 지정 색상을 선택합니다.
- 새 노트의 기본 용지는 **모눈**입니다. 도구 모음 오른쪽 **용지**에서 **무지 / 모눈**을 선택합니다. 모눈은 아주 옅은 크림색 종이에 20pt 간격의 옅은 파란색 선이며 필기 아래에 표시됩니다. 설정은 문서에 저장되고 용지 변경도 실행 취소·다시 실행할 수 있습니다. 창이 좁으면 도구 모음을 가로로 스크롤합니다.
- 두께는 **0.5 / 1.0 / 1.5 / 2.0 / 3.0 pt**이며 일정한 굵기로 그립니다.
- **1 / 2 / 3 / 4 / 5 / 6 / 7 / 8 / 9 / 0**: 검정 / 파랑 / 빨강 / 초록 / 주황 / 노랑 / 보라 / 분홍 / 갈색 / 회색 선택. 캔버스에 포커스가 있을 때만 작동하며, 색상 버튼의 도움말에도 단축키를 표시합니다.
- **V**: 사각형 선택 도구. 드래그 영역에 닿은 획을 선택한 뒤 선택 상자 안쪽을 드래그하여 함께 이동합니다. 빈 곳에서 새 영역을 선택하거나 Esc로 해제합니다. 이동은 ⌘Z / ⌘⇧Z로 취소·복원됩니다. 텍스트 입력 중에는 작동하지 않습니다.
- **E / P**: 캔버스에서 획 지우개 / 펜 선택. 도구 모음 버튼으로도 선택할 수 있습니다. 획을 클릭하거나 문지르면 닿은 획 전체를 삭제합니다. 지우개 커서는 실제 판정 반경을 원으로 표시하며, 화면 배율에 따라 함께 커지거나 작아집니다. 한 번 문질러 지운 여러 획은 ⌘Z 한 번으로 원래 순서와 모양 그대로 복원됩니다. 텍스트 입력 중에는 도구 단축키를 처리하지 않습니다.
- **[ / ]**: 캔버스에 포커스가 있을 때 펜 두께를 한 단계 얇게 / 두껍게 변경합니다 (0.5–3.0pt). 텍스트 입력 중에는 작동하지 않습니다.
- **⌘Z / ⌘⇧Z**: 획 단위 실행 취소 / 다시 실행.
- **⌘N / ⌘O / ⌘S / ⌘⇧S**: 새 문서 / 열기 / 저장 / 다른 이름으로 저장.
- **⌃⌘F**: 전체 화면. `P`는 캔버스에 포커스가 있을 때만 처리합니다.
- `.lightnote` 파일은 버전, 용지 크기, 획 ID, 도구 종류, RGBA, 두께, 모든 좌표·타임스탬프·가능한 압력을 담는 JSON입니다.
- macOS 문서 창에서 문서 이름을 변경할 수 있습니다.

## 저장 범위와 한계

NSDocument의 안전 저장 및 자동 저장을 사용합니다. 앱의 별도 직접 덮어쓰기 대신 macOS 문서 저장 경로를 사용하며 저장 오류는 표준 오류 창으로 알립니다. 자동 저장 지연은 2초로 설정하지만 실제 실행 시점은 macOS가 정합니다. 수동 저장으로 완료한 획을 즉시 저장할 수 있습니다. 자동 저장이 필기 도중 실행되어도 진행 중인 획을 끊지 않으며, 그 획은 입력이 끝난 뒤 다음 저장에 포함됩니다. 지우개로 문지르는 중에는 삭제를 미리 표시하고 손을 떼면 한 작업으로 확정합니다. 저장 시 아직 진행 중인 지우개 작업은 확정 이전 상태로 저장됩니다. 새 노트는 `~/Library/Application Support/LightNote/Notes`에 자동으로 파일을 배정하므로 이름·위치를 고르는 저장 창이 뜨지 않습니다. 창 닫기와 정상 종료 시 진행 중인 작업을 확정해 저장하고, 마지막으로 사용한 파일 경로를 기록하여 다음 실행 때 다시 엽니다. 기존 파일을 직접 연 경우 그 위치에 계속 저장합니다. 저장 오류가 나면 안내하고 종료를 중단하며, 강제 종료 직전의 미저장 작업까지 보장하지는 않습니다.

**입력 이벤트마다 또는 획마다 전체 파일을 직렬화하지 않습니다.** 다만 이 MVP는 저장 시 문서 전체 JSON을 메인 스레드에서 인코딩하는 방식입니다. 대형 문서의 비동기 스냅샷/증분 저널은 이후 단계입니다. 강제 종료 직전의 미저장 입력까지 보장하지 않으며, 자동 저장·강제 종료 복구는 별도 실사용 검증 대상입니다.

## Sidecar와 성능 검증 범위

AppKit mouse down/drag/up, 독립 tablet-point 및 proximity 이벤트를 처리합니다. 이벤트가 tablet-point 유형/하위 유형일 때만 압력을 읽고 기록하며, 압력이 없어도 일정한 굵기로 필기합니다. 실제 Sidecar 장치에서 Apple Pencil의 이벤트 유형, 이벤트 빈도, 압력 전달 및 재연결은 아직 검증하지 않았습니다. OS가 앱에 전달하지 않은 하드웨어 샘플을 복구하거나 무손실 입력을 보장하지 않습니다.

Apple 공식 참고:

- [AppKit 태블릿 이벤트 처리](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/HandlingTabletEvents/HandlingTabletEvents.html)
- [WWDC19 AppKit: Sidecar와 태블릿 입력](https://developer.apple.com/videos/play/wwdc2019/210/)
- [NSDocument 자동 저장](https://developer.apple.com/documentation/appkit/nsdocument/autosavesinplace)

CPU·메모리·필기 지연에 대한 Instruments 측정값은 아직 없습니다. 빠르다는 수치적 성능 주장을 하지 않습니다. [테스트 절차](docs/TESTING.md)에 실제 장치 및 Instruments 측정 절차를 정리했습니다.

## 이후 단계

현재 미구현: 형광펜, 부분 지우개, 올가미, 다중 페이지, 추가 용지 유형 및 모눈 간격 변경, PDF, 노트/폴더 사이드바, 사용자 지정 단축키, 증분·백그라운드 저장. 다음 단계는 실제 Sidecar 입력 확인과 필기 엔진 계측입니다.

아이콘 PNG와 macOS ICNS는 `Resources/`에 포함되어 있습니다. PNG를 변경한 후 `./scripts/make-icon.sh`로 다시 생성할 수 있습니다. [아이콘 제작 안내](docs/APP_ICON.md)
