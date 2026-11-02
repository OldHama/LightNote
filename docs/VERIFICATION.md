# 검증 범위

현재 확인한 환경: Apple Silicon Mac, Xcode 27.2에 포함된 Swift 6.4.2 및 macOS SDK. 배포 대상은 macOS 15 이상이며 macOS 15 실기기 실행은 별도 확인이 필요합니다.

## 자동 검사

- 모델 XCTest 14개: 파일 왕복 저장, 입력 검증, 이전 문서 호환성, 모눈 설정, 지우개 경계, 원형 궤적 보간, 입력점·시작점·끝점 보존.
- 네이티브 합성 이벤트 검사: 점 100개, 2,002개 샘플 획, 필기 중 저장, 입력 중단, 지우개 클릭·문지르기, 사각형 선택·이동·Undo/Redo, 저장·재열기.
- 확대 상태 좌표 검사: 50% / 200% 필기·지우기·선택 이동, 배율 초기화, 25% 뷰포트 확장, 기존 용지 바깥의 모눈·필기·저장 복원.
- 자동 저장 검사: 새 파일 배정, draft 해제, 경로 유지, 수정 상태 해제, 저장 후 정확한 모델 복원.
- Swift 6 컴파일, 로컬 앱 생성, ad-hoc 서명 검증, 설치 스크립트 실행.

## 실제 앱 UI 확인

마우스 입력, 색상 선택, Undo/Redo, 저장·재열기, 자동 저장, 저장 대화상자 없는 닫기·종료, 재실행 시 마지막 문서 복원을 확인했습니다. 응용 프로그램 폴더 설치와 Alfred 검색 결과, Spotlight 메타데이터 조회도 확인했습니다.

## 미검증 항목과 제한

- 실제 Sidecar / Apple Pencil 입력, 연결 해제·재연결, 물리 트랙패드 핀치.
- Instruments 입력 지연·CPU·메모리 측정, 장시간 누수 검사.
- 강제 종료 순간까지의 완전한 데이터 복구, 디스크 오류 상황의 전체 실사용 흐름.
- 외부 배포용 Developer ID 서명과 공증.

개발 Mac의 `xcodebuild`는 Xcode 내부 플러그인의 시스템 프레임워크 심볼 불일치로 소스 컴파일 전에 중단됐습니다. 같은 소스는 설치된 Swift 컴파일러를 사용하는 `scripts/build.sh`로 빌드하고 실행했습니다. Xcode 프로젝트의 실제 IDE 빌드는 정상적인 Xcode 설치 환경에서 추가 확인이 필요합니다.

자세한 재현 방법은 [TESTING.md](TESTING.md)를 참고하세요. 합성 이벤트 검사 결과는 실제 하드웨어 입력 전달이나 사용자가 체감하는 지연을 입증하지 않습니다.

아이콘 표시 갱신: 앱 버전 0.1.1(2)로 갱신하고 시작 시 번들 ICNS를 NSApplication.applicationIconImage에 직접 지정합니다. 설치 시 기존 설치본의 Launch Services 등록을 해제한 뒤 새 버전을 등록합니다. 실제 노트를 저장하고 앱을 종료·재실행하여 복원을 확인했고, NSWorkspace가 설치된 앱에 반환하는 아이콘을 이미지로 추출해 새 캐릭터 아이콘임을 확인했습니다. 빌드와 서명 검사가 통과했습니다.

문서 제목 정리: 새 파일은 중복을 피한 `새 노트.lightnote`, `새 노트 2.lightnote` 형태로 생성합니다. 창 제목은 확장자를 생략하고 기존 UUID 자동 이름을 짧게 표시합니다. 기존 파일 경로와 필기는 변경하지 않습니다. 제목 변환, 사용자 이름 유지, 파일 이름 충돌 회피 및 기존 네이티브 통합 검사가 통과했습니다.

레이저 도구: L 선택, 누르는 동안 궤적 유지, 손을 뗀 시점부터 1초 유지 + 2초 페이드아웃, 저장·Undo 기록 제외 및 만료 후 제거를 구현했습니다. 모델 테스트 11개와 네이티브 입력 회귀 검사, 빌드·설치가 통과했습니다. 실기기 레이저 조작감은 별도 확인 대상입니다.

자동 업데이트 추가: Sparkle 2.10.1 연결, Ed25519 공개키 고정, 서명된 feed/ZIP 검증, 자동 확인·다운로드·종료 시 적용, 수동 확인 메뉴 및 저장 실패 시 재시작 보류를 구현했습니다. Universal 배포 앱의 arm64/x86_64 아키텍처와 중첩 프레임워크 서명을 확인했고, 모델 테스트 11개 및 네이티브 회귀 검사가 통과했습니다. 개인 서명키는 배포 Mac 키체인에만 저장합니다. 실제 신규 버전으로 교체되는 전체 업데이트 사이클과 Developer ID 공증은 별도 확인 대상입니다.

0.2.1: 상단 저장 버튼 옆에 다운로드 아이콘을 추가하고 메뉴와 동일한 Sparkle 사용자 업데이트 흐름에 연결했습니다. Universal 빌드와 네이티브 회귀 검사, ZIP 및 appcast 서명 검증이 통과했습니다.

0.2.2: 레이저 종료를 공통 입력 종료 처리에서 분리했습니다. 홀드 중 저장/디스플레이 변경/L 재선택 이후에도 유지되는지, 새 홀드 중 이전 궤적도 유지되는지, 실제 해제 이후 만료되는지 합성 이벤트 검사로 확인했습니다. Universal 빌드, 네이티브 회귀 검사와 배포 서명 검증이 통과했습니다. 실제 하드웨어 홀드 동작은 별도 실사용 확인 대상입니다.

0.3.0: C 원·타원, R 사각형, ⌘ 정원·정사각형 제한, V 선택의 네 모서리 크기 변경을 추가했습니다. 도형 벡터 저장과 선 두께·식별자 보존, 확대/축소·Undo/Redo를 모델 테스트 13개 및 네이티브 합성 입력 검사로 확인했습니다. 실제 장치 조작감은 별도 실사용 확인 대상입니다.

0.3.1: A 화살표 도구를 추가했습니다. 수평·수직·역방향·대각선의 끝점·화살촉 방향, 벡터 저장과 지우개 판정을 모델 검사에 추가했습니다. 선택·이동·모서리 크기 변경을 기존 객체 흐름에 연결했습니다.

0.3.2: ⌘Z/⌘⇧Z 메뉴 액션을 명시적으로 문서 Undo/Redo에 연결했습니다. 키 윈도우·메인 윈도우·문서 컨트롤러 순서로 문서를 찾고, 텍스트 편집기는 자체 기록을 사용합니다. 네이티브 메뉴 키 이벤트로 한 획 취소와 정확한 복원이 확인됐습니다.

0.3.3: / 키 및 물음표 버튼으로 여는 단축키 도움말을 추가했습니다. 기본 도구, 도형 제한, 편집/문서 키, 10색 키와 제스처를 안내하고 Esc/닫기 버튼을 제공합니다. 네이티브 검사에서 / 도움말 상태와 문서 데이터 보존을 확인했습니다.

0.4.0: ⌘, 환경설정 창을 추가했습니다. 펜 기본값, 숫자키 팔레트, 새 노트 기본 용지, 모눈 배경·선·간격, 자동 업데이트 옵션을 저장하고 적용합니다. 네이티브 검사에서 격리된 설정 도메인의 저장·복원과 실제 메뉴 키 이벤트의 환경설정 창 생성을 확인했습니다.

0.4.1: 사라지는 중 재클릭하면 아직 남은 레이저를 완전한 밝기로 복원하고 홀드 동안 유지하도록 변경했습니다. 해제 시 대기 없이 2초 페이드를 시작합니다. 모델 테스트 14개와 재클릭 밝기 복원·홀드 유지·만료·노트 비저장 네이티브 검사가 통과했습니다.

0.4.2: Sparkle의 유효한 새 업데이트 발견/없음 이벤트를 앱 공용 상태에 연결하고, 새 버전이 있을 때만 오른쪽에 파란 다운로드 버튼을 표시하도록 변경했습니다. 기존 메뉴·환경설정의 수동 확인은 유지합니다.

0.5.0: 선택한 획·도형의 ⌘C/⌘V/⌘D 재사용을 추가했습니다. 모델 테스트 15개와 네이티브 합성 입력 검사에서 독립 식별자·메타데이터 보존, 반복 배치, 문서 간 붙여넣기, 묶음 Undo/Redo 및 실제 복제 메뉴 경로를 확인했습니다. 시스템 키보드 실사용 확인은 별도입니다.

0.6.0: 클립보드 이미지 붙여넣기와 선택 이동·크기 변경·복제·삭제·저장을 추가했습니다. PNG를 노트 안에 내장하고 기존 벡터 클립보드를 우선 처리합니다. 모델 테스트 15개 및 PNG 붙여넣기·저장·Undo/Redo·크기 변경의 네이티브 검사를 실행합니다. 외부 앱별 클립보드 실사용과 실제 업데이트 설치는 별도 확인 대상입니다.

0.7.0: AppKit 비동기 쓰기와 편집 모델의 잠금 기반 값 스냅샷을 연결했습니다. 인코딩 전에 입력을 재개하고, 모델 변경을 명시적으로 추적하며, 안전한 파일 교체와 저장 순서는 NSDocument에 맡깁니다. 네이티브 검사에서 새 필기·이동과 스냅샷 보존, 오래된 저장의 dirty 토큰, 저장 순서, Undo/Redo dirty 복원, 창 닫기, 다중 문서 종료 flush, 쓰기 실패·원본 보존·재시도, 실제 타이머 자동 저장이 통과했습니다. 별도 실제 NSApplication 종료 프로세스에서 최신 저장 후 종료와 오류 시 종료 취소·메모리 편집 보존도 통과했습니다. Sparkle 실제 설치 및 iCloud 충돌·강제 종료 복구는 별도 확인 대상입니다.

0.8.0: 변경 기록과 기준 데이터를 기반으로 한 강제 종료 복구, 활성 세션 잠금, 손상 꼬리의 정상 부분 재생, 원본·기존 복구 사본 보존을 추가했습니다. 외부 변경 시 로컬 편집의 자동 충돌 사본과 늦게 감지한 외부 버전 보존, 사본 경로·마지막 문서 참조 갱신을 구현했습니다. 기존 저장/종료 검사에 외부 변경·손상 원본 보존 검사를 추가하고, 실제 SIGKILL 자식 프로세스 재시작 검사를 제공합니다. 실제 기기 간 iCloud 동기화와 전원 차단은 검증 범위에 포함하지 않습니다.

0.9.0: Q 자유 화살표를 추가했습니다. 기존 펜의 보간 몸통에 끝 방향을 따라 화살촉을 붙이고, 미리보기의 이전 화살촉 영역도 다시 그립니다. 화살촉을 저장 후 경로·범위·선택·지우개 판정에 포함했습니다. 코어 28개와 네이티브 Q 곡선·화살촉 선택·삭제·단일 Undo/Redo·저장 검사를 통과했으며, 강제 종료 재현 문서에 자유 화살표를 포함합니다. A 직선 화살표는 유지합니다.

0.10.0: 펜(P)의 Shift 임시 직선 제한을 추가했습니다. 원래 입력은 미리보기 동안 유지하고, Shift 상태로 획을 끝내면 첫·마지막 좌표만 일반 펜으로 저장합니다. Shift 해제 시 원래 경로가 복원됩니다. 코어 30개 및 네이티브 수정키 전환·중간 전환·해제·저장·Undo/Redo 검사 통과. 직선은 기존 노트 형식과 호환되며, 강제 종료 검사 문서에도 포함합니다.

0.10.1: 첫 mouseDown에서 앱 활성화, 대상 문서의 키 창·메인 창 선택, 캔버스 first responder 지정을 함께 수행하도록 수정했습니다. acceptsFirstMouse는 유지해 첫 획을 받습니다. 같은 앱의 다른 창과 실제 Finder 활성 상태에서 필기를 시작하는 네이티브 검사에서 첫 획 좌표 보존과 NSApplication 키 이벤트 라우팅을 확인했습니다. 기존 필기·저장·종료·강제 종료 복구 검사도 통과했습니다.

0.10.2: 필기 도구 8개의 버튼 레이블에 고정 44×44pt 프레임과 사각형 contentShape를 적용하고, 도구 사이 간격을 없앴습니다. 실제 NSHostingView/SwiftUI 버튼에 아이콘 밖의 모서리 down/up 이벤트를 전달한 16회 클릭 검사를 통과했습니다.

0.10.3: 캔버스에서 Command 홀드로 임시 객체 선택, 해제 시 이전 도구 복귀를 추가했습니다. 선택 드래그 도중 해제는 mouseUp까지 복귀를 미루고, V 선택과 C/R/A의 기존 Command 도형 제한은 유지합니다. 네이티브 합성 이벤트로 임시 선택·드래그 중 해제·획 추가 없음·펜/지우개 복귀·V 유지·도형 도구 유지를 검사했고 기존 입력 통합 검사도 통과했습니다. Universal 빌드와 배포 서명을 검증했습니다.

0.10.4: 8개 그리기 도구에 호버 시 옅은 둥근 배경, 누르는 동안 더 진한 배경을 추가했습니다. 44pt 전체 클릭 영역을 유지하며 접근성 동작 줄이기 설정에서는 전환 애니메이션을 생략합니다. Universal 빌드·배포 서명 검증과 16개 버튼 모서리 클릭 검사가 통과했습니다. 호버 색감은 자동 픽셀 검사 범위에 포함하지 않았습니다.

0.10.5: Command를 떼어도 객체 선택 도구와 선택 획이 유지되도록 자동 복귀를 제거했습니다. 네이티브 합성 이벤트로 드래그 도중 해제·mouseUp 후 선택 및 선택 영역 유지·지우개에서 전환 후 유지·V 유지·P 전환·도형 Command 제한 보존을 검사했고 통합 검사가 통과했습니다. Universal 배포 빌드와 서명 검증도 통과했습니다.

0.10.6: 요청에 따라 외부 변경 배너·충돌 사본 생성을 제거하고 현재 열린 문서를 같은 경로에 덮어쓰도록 변경했습니다. AppKit이 외부 수정으로 선행 거부하면 같은 경로 Save As로 재시도하며 일반 저장 오류는 그대로 반환합니다. 네이티브 백그라운드 저장·외부 변경/손상 바이트 덮어쓰기 검사, 실제 앱 종료 성공/실패 검사, 7개 강제 종료/정상 닫기 시나리오가 통과했습니다. 강제 종료 복구 기록은 유지합니다.

0.10.7: 레이저 해제 후 페이드 시간을 2초에서 1.3초로 단축했습니다. 코어 30개 테스트와 네이티브 입력 통합 검사(홀드 유지·재클릭 복원·1.4초 후 만료)가 통과했습니다.

0.10.8: Command 객체 선택에서 선택 획이 없으면 이전 도구로 복귀합니다. 키 해제 또는 빈 영역 드래그 완료 시 판정하며 진행 중 드래그는 중단하지 않습니다. 실제 객체가 선택되면 선택 도구를 유지하고 V 직접 선택은 복귀 대상에서 제외합니다. 네이티브 통합 검사에서 객체 선택 유지·빈 선택 펜/지우개 복귀·V 유지·P 전환·도형 제한 회귀 검사를 통과했습니다.

0.10.9: 펜/자유 화살표에서 태블릿 양압 입력을 확인한 획은 압력 0인 후속 좌표와 mouseUp 좌표를 추가하지 않고 마지막 접촉 좌표에서 끝냅니다. 일반 마우스 획은 기존 mouseUp 끝점을 유지합니다. CGEvent 태블릿 subtype/압력 fixture로 압력 0 및 release 꼬리 제외·다음 마우스 획의 정상 끝점 보존을 네이티브 통합 검사에 추가했고 통과했습니다. Apple Pencil/Sidecar 실기기 입력과 양압 상태에서 발생하는 끝부분 흔들림은 별도 확인 대상입니다.

0.10.10: 색상 프리셋 10개를 연속 44×44pt 버튼으로 구성하고 그리기 도구와 같은 호버/누름 배경을 적용했습니다. 선택 테두리를 유지하며 원 바깥 여백도 클릭됩니다. 네이티브 도구 모서리 16개 + 색상 모서리 20개 클릭 검사는 첫 실행에서 기존 선택 도구 검사 1회 실패 후 재실행 2회 모두 통과했습니다. 호버 색감 자동 픽셀 검사는 하지 않았습니다. Universal 빌드·배포 서명 검증을 통과했습니다.

0.10.11: 상단 도구/색상 및 편집 컨트롤의 툴팁을 컨트롤 위쪽 child NSPanel로 표시합니다. 시스템 help와 중복하지 않으며 스크롤 클리핑을 피하고 마우스 이벤트/포커스를 가로채지 않습니다. 마우스 이탈·창 비활성화·닫기·스크롤 레이아웃 변경 시 닫습니다. 네이티브 검사에서 버튼 모서리 36개 클릭, 툴팁 실제 표시·상단 배치·이벤트 통과·포커스 유지·해제를 확인했습니다. 첫 배포 빌드 검사는 창 교체 직후 툴팁 검사에서 실패했습니다. 창 활성화·레이아웃 안정화 대기를 추가하고 mouseEntered/mouseExited 합성 이벤트로 확인해 통과했습니다. 물리 마우스 이동에 의한 OS tracking 전달은 별도 실사용 확인 대상입니다.

0.11.0: 선택 영역 PNG 복사(⌘⇧C)·파일 내보내기(⌘⇧E), 상단 버튼과 편집 메뉴를 추가했습니다. 선택 객체의 경계에 8pt 여백, 2배 해상도, 종이/그리드 배경, 문서 순서 합성을 사용하고 선택 UI·레이저·미선택 획은 제외합니다. 16,384px 변 길이/3,200만 픽셀 한도를 초과하면 안내합니다. PNG 붙여넣기는 원본 PNG 바이트를 유지합니다. 네이티브 검사에서 빨강/파랑 이미지 방향·겹친 녹색 필기·미선택 자홍 획 제외·픽셀 크기·클립보드/파일 일치·문서/Undo/선택 유지와 기존 통합 검사가 통과했습니다. macOS 테스트 fixture의 setColor 실패로 생성된 투명 이미지를 원시 RGBA 픽셀 fixture로 교체한 뒤 확인했습니다. 저장 패널 클릭 및 학생 공유 대상 앱에 실제 붙여넣기는 별도 실사용 확인 대상입니다.

0.11.1: 상단 저장 버튼을 클래식 플로피디스크 벡터 아이콘으로 변경했습니다. SwiftUI ImageRenderer로 실제 아이콘을 PNG로 렌더링해 모양을 확인했습니다. 저장 액션·접근성 이름·⌘S 안내는 유지합니다.

0.12.0: 선택 상자 아래 자물쇠 NSButton으로 객체 잠금/해제를 추가했습니다. 선택은 허용하되 잠긴 객체의 이동·크기 변경·삭제·지우개를 막으며 혼합 선택은 이동/크기 변경 미리보기와 핸들을 막습니다. 선택 전체가 잠겼으면 해제, 혼합/미잠금 선택이면 전체 잠금입니다. optional locked 필드를 사용해 기존 문서를 읽고 저장·복구·Undo/Redo 경로에 포함합니다. 코어 31개 및 네이티브 통합 검사에서 실제 버튼 액션·이동/변형/삭제 차단·저장 복원·Undo/Redo·해제를 확인했습니다.

0.12.1: 어두운 모드의 기본 NSButton/template 아이콘이 밝은 종이에서 흰색으로 묻히는 문제를 해결했습니다. 선택 잠금 버튼을 흰색 불투명 배경·파란 테두리·파란 벡터 자물쇠로 직접 그려 테마에 의존하지 않도록 했습니다. 확대 배율과 무관한 44×32 화면 크기, 호버/누름 강조를 유지합니다. 버튼을 실제 bitmap으로 렌더링해 모양과 방향을 확인했고 불투명 배경·버튼 액션·잠금/해제·저장·Undo/Redo 네이티브 검사를 통과했습니다.

0.12.2: 자물쇠 버튼 위치에 selectionTransform을 적용하고 매 선택 드래그 이벤트에서 위치를 갱신해 이동·크기 조절 중에도 선택 상자를 따라갑니다. 화면 크기를 44×32에서 36×26pt로 줄였습니다. 네이티브 통합 검사에서 이동 도중 40×25pt 오프셋 일치·드롭 후 위치 유지·버튼 크기 및 기존 잠금 동작 검사가 통과했습니다.

0.12.3: PNG 클립보드 복사 단축키를 ⌘⇧C에서 ⌃⌘C(Control+Command+C)로 변경하고 메뉴·툴팁·도움말·README를 맞췄습니다. PNG 내보내기는 ⌘⇧E, 일반 객체 복사는 ⌘C를 유지합니다.

0.13.0: 세로 캔버스를 문서 pageHeight의 정수 배 단위로 확장하고 페이지 경계선/번호와 하단 현재/전체 페이지 표시를 추가했습니다. 경계 넘어 필기는 같은 획으로 이어지고 저장 필기 범위로 재열기 시 페이지를 복원합니다. 기존 좌표·가로 확장·줌아웃 전체 영역 입력은 유지하며 페이지 가이드는 PNG에 포함하지 않습니다. 저장 복원 시 여백 때문에 빈 페이지가 더 생기지 않도록 필기 경계를 사용하고, 획 두께가 하단 경계를 넘는 경우도 확장합니다. 네이티브 검사에서 빈 문서 1페이지·하단 경계 통과 시 2페이지·획 연속성·저장/재열기 복원·경계 직전 필기의 재열기 시 불필요한 페이지 제외 및 기존 입력/선택/줌/이미지/잠금 검사를 통과했습니다. 최초 합성 경계 테스트의 좌표 변환 누락을 수정해 캔버스 좌표로 검사했습니다.

0.14.0: 상단 스티커함에서 파일 다중 등록·클립보드 등록·선택 PNG 등록·그리드 클릭 삽입·우클릭 삭제를 추가했습니다. Library/Application Support/LightNote/Stickers 아래 독립 PNG 파일로 보관하며 이름이 같아도 UUID 파일로 덮어쓰지 않습니다. 50MB/3,200만 픽셀 제한과 이미지 검증·ImageIO 200px 썸네일·사진 방향 보정·PNG 원본 투명도 보존을 적용합니다. 삽입은 220pt 이하 이미지 객체로 복제되어 이동/크기/잠금/PNG/저장/Undo/Redo 기존 경로를 사용합니다. 스티커함 삭제는 이미 노트에 삽입된 PNG를 건드리지 않습니다. 네이티브 검사에서 재열기·중복 이름·불량 입력·반복 삽입 독립 ID·Undo/Redo·노트 저장·삭제 독립성·EXIF 회전·투명도를 통과했습니다. 테스트 라이브러리 3개로 NSHostingView 화면을 렌더링해 제목/버튼/썸네일/안내를 확인했습니다. 레이아웃 영역이 변하지 않은 tracking area 갱신이 툴팁을 닫지 않도록 보완한 뒤 기존 버튼/툴팁 검사도 통과했습니다. 파일 패널의 실사용 클릭과 실제 외부 클립보드 앱 연동은 별도 확인 대상입니다.

0.14.1: 선택 상자 안의 우클릭 메뉴에 복사 → PNG 클립보드 복사/PNG 파일 저장…, 생성 → 스티커 생성을 추가하고 상단 PNG 복사/내보내기 버튼을 제거했습니다. 선택이 없거나 선택 밖에서 우클릭하면 메뉴를 표시하지 않습니다. 생성 후 스티커함을 열어 결과를 보여줍니다. 네이티브 검사에서 메뉴 항목·PNG 액션 연결·선택 밖 미표시·실제 생성 액션·PNG 바이트 일치·문서 유지 및 기존 PNG/스티커/선택 회귀 검사가 통과했습니다. 파일 저장 패널 실클릭은 별도 확인 대상입니다.

0.15.0: 별도 노트 보관함 창과 상단/파일 메뉴 진입을 추가했습니다. 미리보기 카드·검색·정렬·즐겨찾기·폴더 생성/탐색·새 노트·열기·이름 변경·복제·폴더 이동·Finder 보기·휴지통 이동을 지원합니다. 기본 Notes 폴더 하위 문서와 최근/열린 외부 문서를 모으며 첫 페이지 미리보기는 detached task에서 순차 생성하고 열린 노트는 메모리 스냅샷을 사용합니다. 기존 UUID 자동 이름과 복구/충돌 파일 표시는 문서 창과 같은 readableTitle을 사용합니다. 이름/경로 충돌 시 덮어쓰지 않고, 열린 문서는 persistLatest 후 NSDocument.move 또는 close로 처리하며 복구 journal·즐겨찾기·마지막 문서 경로를 갱신합니다. 별도 창에 포커스가 있을 때 배경 문서 편집 메뉴를 차단합니다. --library-self-test에서 임시 Notes/Trash와 분리된 UserDefaults로 스캔·미리보기·손상 파일·검색·정렬·즐겨찾기 유지·폴더·이동·이름 변경·충돌 거부·복제 내용·신규 노트 생성/열기·열린 노트 미저장 편집 보존·휴지통 내용·메타데이터 갱신을 확인했습니다. 폴더 복귀 시 URL 표현 차이로 비던 화면을 경로 비교/표준화로 수정하고 재검사했으며 NSHostingView 화면을 렌더링해 확인했습니다. 테스트 휴지통은 주입한 임시 폴더를 사용하므로 개인 휴지통을 건드리지 않습니다. 실제 Finder 휴지통 통합 및 이름 변경/삭제 대화상자의 실사용 클릭은 별도 확인 대상입니다.

0.15.1: 신규 학생 상담 A4 세로 양식을 보관함 신규 메뉴에 추가했습니다. 210×297mm(72pt/in) 페이지, 3배 PNG 잠금 배경으로 학생/보호자 정보·학습 경험/관심·상담·수업 계획을 구성했습니다. 실제 PNG를 렌더링해 한글/칸/여백을 확인했습니다. 이미지 bounds에서 필기용 padding을 제외해 A4 배경만으로 빈 2페이지가 생기지 않도록 했고, 잠긴 배경과 필기가 겹치면 편집 가능 획을 우선 선택합니다. 새 노트는 지정 폴더에 먼저 저장한 후 창을 만들어 production의 무제 자동 저장이 루트 경로를 선점하지 않게 했습니다. 코어 32개, 네이티브 입력/이미지/선택/PNG/잠금 회귀 검사, 보관함 검사에서 A4 치수·1페이지·배경 잠금·필기/선택·Undo/Redo·저장/독립 복수 생성·현재 폴더 경로를 확인했습니다. 실제 종이 인쇄는 별도 확인 대상입니다.

## v0.15.2 — editor shortcut focus

- Editor windows route unmodified physical tool/color/selection keys to their own canvas when a toolbar control or hosting root owns the responder. Command menu shortcuts retain AppKit routing; text editors, attached sheets, and modal windows are excluded.
- Native focus regression sends events through NSApp after another-window and Finder activation, then with toolbar/root responders; text editing still receives `e` without changing tools.
- Debug and signed universal release on arm64: DRAWING_FOCUS_TEST_PASSED and APP_SELF_TEST_PASSED. Intel compiled but not run. No real Apple Pencil/Sidecar reconnection test was performed.

## v0.15.3 — return to pen after selection deletion

- Backspace/Delete switches to pen after removing an editable selection. Empty or entirely locked selections do not switch tools.
- Signed universal release on arm64: APP_SELF_TEST_PASSED, including return-to-pen/selection cleared assertion, exact deletion Undo/Redo, and locked-object protection.

## v0.15.4 — activate the app from background drawing

- Drawing now requests running-app activation as well as app activation, then reapplies the owning window/responder after 0/80/250 ms. Active drag and pressure-positive tablet events also recover focus. Retries are bounded and scoped to the initiating app/document, skip text editors, sheets, modal dialogs and switches to a third app/another LightNote window.
- Signed universal release on arm64: CHROME_DRAWING_ACTIVATION_PASSED, DRAWING_FOCUS_TEST_PASSED and APP_SELF_TEST_PASSED. The focus test activates real running Chrome/Finder, delivers synthetic canvas input, checks frontmost process/key window/responder, simulates a responder reset during activation and verifies text retains focus beyond the retry period.
- No physical Apple Pencil/Sidecar test; OS event delivery from that hardware remains a manual check. No user app was terminated or restarted.

## v0.15.5 — Command selection modifier routing

- Editor windows explicitly dispatch flagsChanged once to the canvas, including when it already owns first responder. Text fields, sheets and modal dialogs retain their own modifiers. Existing shape constraints and successful-selection persistence are preserved.
- Cancel pending background-focus retries on app/window resignation.
- Added NSApp.sendEvent Command down/up assertions with canvas and window responders; wait for initial activation and include timeout call-site diagnostics.
- Signed universal release on arm64 launched through Launch Services (`open -n -W`): CHROME_DRAWING_ACTIVATION_PASSED, DRAWING_FOCUS_TEST_PASSED. Direct executable launches intermittently failed initial app activation before the modifier assertions; normal application launch passed. APP_SELF_TEST_PASSED covers successful/empty Command selections, constrained shapes, deletion/Undo/Redo. No physical Sidecar test.

## v0.15.6 — F pen shortcut

- F and P select pen. Physical F works with Korean input; editor window routing and tooltip/help include the alias.
- Signed universal release on arm64: APP_SELF_TEST_PASSED (P and Korean physical F), CHROME_DRAWING_ACTIVATION_PASSED and DRAWING_FOCUS_TEST_PASSED (F through toolbar/window responders).

## v0.15.7 — simplify editor file controls

- Removed the editor toolbar New/Open buttons; Library, Save and Help remain. File menu and Command-N/O are unchanged.
- Universal release build, installation and Sparkle signature verification passed. This UI-only removal did not add tests or change document logic.

## v0.15.8 — new-note card in library

- Added a final full-cell clickable plus card to the library grid, including empty/search/favorite views. It uses the existing busy-guarded createNote operation for the current folder. Hover tint, tooltip and accessibility label are provided.
- Signed universal release on arm64: NOTE_LIBRARY_TEST_PASSED (including current-folder note creation). Inspected /tmp/lightnote-library-preview.png: plus card matches note thumbnail dimensions and aligns with labels. No automated physical card-click test added.

## v0.15.9 — glass library scope control

- Replaced the separate scope title/favorite toggle with a single capsule containing All Notes and Favorites buttons. Uses native SwiftUI glassEffect on macOS 26+, regularMaterial on macOS 15, and opaque control background when Reduce Transparency is enabled. A matched-geometry selected capsule slides with spring animation unless Reduce Motion is enabled. Explicit light/dark text colors preserve contrast; hover and full segment hit areas are provided.
- Subfolder breadcrumb/back navigation and favorites filtering remain connected to the existing library state.
- Signed universal release on arm64: NOTE_LIBRARY_TEST_PASSED. Rendered and visually inspected dark/all, dark/favorites and light/all views; light/favorites also rendered. Legacy OS/material fallback and accessibility system settings were compiled but not run on a separate system. Screenshot rendering is static, not proof of live animation timing.
- Apple API reference: https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views

## v0.15.10 — relocate New menu into library card

- Removed the top-right New menu. The grid's plus card now opens its three existing actions: new blank note, portrait A4 student consultation, and new folder. Uses button menu style so the full custom card label remains visible; native borderless menu style collapsed it to text during visual QA and was corrected.
- Debug and signed universal release on arm64: NOTE_LIBRARY_TEST_PASSED; inspected rendered library with upper control absent and full-size card retained. Document/template/folder creation operations are unchanged. Menu pop-up interaction was not independently automated.

## v0.15.11 — native tab interaction and liquid lens

- Replaced the simulated SwiftUI glass/gradient/matched-geometry scope picker with an AppKit NSSegmentedControl bridge. macOS 27 uses the public tabs role; macOS 26 uses capsule/extra-large sizing and native older-system controls remain available. Disabled state, selected segment, binding updates and accessibility are delegated to AppKit. Compact hosting metrics are explicitly disabled on supported systems.
- Signed universal release on arm64: NOTE_LIBRARY_TEST_PASSED. A separately identified isolated preview bundle was inspected with live computer-use capture. Click changed the selection and filtered the list from 2 notes to 1 favorite; dragging from the selected All Notes segment onto Favorites also changed the selected accessibility value and list to the favorite. Personal notes were not used.
- NSView.cacheDisplay renders the native composited selection layer black; this is an offscreen capture limitation. Live window capture showed the selected label and native material correctly. Native animation/optics vary by macOS; no pixel-identical GIF claim. Intel/older macOS compiled but not run.
- Optional --glass-preview with --self-test --library-self-test retains the isolated fixture for 90 seconds for live UI inspection.
- References: https://developer.apple.com/documentation/appkit/nssegmentedcontrol and the macOS 27.2 SDK role/compact-metrics declarations.
