# GitHub Release 자동 업데이트

배포판은 Sparkle 2.10.1을 사용합니다. 앱 시작 후 자동 확인을 예약하고 이후 약 1시간 간격으로 새 Release를 확인합니다. 기본값은 자동 다운로드·설치이며, 조용한 적용은 종료 시 이루어집니다. 업데이트를 즉시 확인하려면 **LightNote → 업데이트 확인…**을 사용합니다. 권한이 필요한 위치에서는 macOS 인증이 필요할 수 있습니다.

## 신뢰와 저장

- 업데이트 주소: `https://github.com/OldHama/LightNote/releases/latest/download/appcast.xml`
- 배포 ZIP과 appcast는 Ed25519 서명을 검증합니다.
- 공개키는 Info.plist에 들어 있고 비밀키는 배포 담당 Mac의 로그인 키체인에만 보관합니다.
- `SUVerifyUpdateBeforeExtraction`과 `SURequireSignedFeed`를 활성화합니다.
- 키체인 계정은 `com.lightnote.app`이며 비밀키를 저장소나 Release에 올리지 않습니다.
- 업데이트를 재시작하기 전 열려 있는 노트를 저장합니다. 실패하면 설치 재시작을 보류하며, 오류를 해결한 뒤 업데이트 확인 메뉴로 다시 진행할 수 있습니다.
- 노트 파일은 앱 번들 밖의 Application Support/LightNote/Notes에 있어 앱 교체 대상에 포함되지 않습니다.

## 새 버전 배포

키체인에 해당 서명키가 있는 Mac에서 실행합니다.

1. `CFBundleShortVersionString`을 새 버전으로, `CFBundleVersion`을 이전보다 큰 정수로 변경합니다.
2. 모델 테스트·앱 통합 검사를 수행하고 코드를 커밋·푸시합니다.
3. 아래 스크립트로 공용 앱과 서명된 배포 파일을 생성합니다.

```sh
./scripts/release.sh
```

결과는 `~/Library/Caches/LightNote/Releases/<version>/`에 생성됩니다. `LIGHTNOTE_ARCHS='arm64 x86_64'`로 두 아키텍처를 컴파일하고 ZIP, 서명된 appcast.xml, SHA256SUMS.txt를 만듭니다. 프레임워크는 공식 배포 URL에서 받고 고정된 SHA-256 체크섬을 확인합니다.

게시까지 진행하려면 다음을 실행합니다.

```sh
./scripts/release.sh --publish
```

기존 같은 태그를 덮어쓰지 않습니다. GitHub에 로그인된 gh CLI가 필요합니다. 서명 도구는 키체인 사용 승인을 요청할 수 있습니다. 비밀키는 출력·내보내기하지 않습니다. 새 Mac으로 배포 환경을 옮길 때는 키체인 서명키를 별도로 안전하게 이전해야 합니다.

소스의 일반 커밋은 업데이트 배포가 아닙니다. 앱은 서명된 안정판 Release만 받습니다. 이전 버전 앱에는 업데이트 코드가 없으므로 v0.2.0 배포판을 한 번 직접 설치한 뒤부터 자동 업데이트가 적용됩니다.

## 빌드와 의존성

- Xcode: 정확한 버전의 Sparkle Swift Package를 연결합니다.
- 터미널: `scripts/fetch-sparkle.sh`가 공식 프레임워크를 로컬 캐시에 받아 링크·임베드합니다.
- 테스트 실행(`--self-test`)에서는 업데이트 확인을 시작하지 않습니다.
- Sparkle 라이선스는 `ThirdPartyNotices/Sparkle-LICENSE`에 있으며 앱 리소스에도 포함됩니다.

현재 배포 앱은 ad-hoc 서명이며 Apple Developer ID 서명·공증은 아직 없습니다. Ed25519는 업데이트 무결성 검증을 제공하며, 최초 다운로드 시 macOS가 요구하는 보안 확인을 대신하지 않습니다.

참고: [Sparkle 설정](https://sparkle-project.org/documentation/customization/), [프로그램 방식 연결](https://sparkle-project.org/documentation/programmatic-setup/), [서명과 게시](https://sparkle-project.org/documentation/publishing/).

새 버전이 확인되면 상단 오른쪽의 파란 다운로드 버튼을 표시합니다. 버튼은 도구 모음 스크롤과 분리해 고정하며, 새 버전이 없다는 확인을 받으면 숨깁니다. 수동 확인은 LightNote 메뉴 또는 환경설정의 업데이트 탭에서 수행합니다.
