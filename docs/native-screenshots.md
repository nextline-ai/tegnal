# 네이티브 스크린샷 촬영

```sh
# 소스 복제와 빌드는 한 번만 하고, 기존 세 기기에서 촬영합니다.
scripts/capture-native-screenshots.sh all

# 기기 하나만 촬영하거나, 기존 시뮬레이터 ID를 지정합니다.
scripts/capture-native-screenshots.sh iphone
scripts/capture-native-screenshots.sh ipad-13 EXISTING-SIMULATOR-UDID
```

Xcode, XcodeGen, Python 3와 Pillow가 필요합니다. 기본 Python에 Pillow가 없으면 설치된 Codex 번들 Python을 사용합니다. `MARKETING_PYTHON`으로 Python을 지정할 수 있습니다. 촬영은 사용자의 요청이 있을 때 실행하며, 회귀 테스트를 함께 실행하지 않습니다.

원본 이미지와 `asset-manifest.json`은 Git에서 제외된 `user_data/marketing/generated`에 있어야 합니다. 다른 위치는 `TEGNAL_CAPTURE_ASSETS=/absolute/path`로 지정합니다. 원본 이미지는 저장소나 일반 앱 빌드에 추가하지 않습니다.

도구는 최신 `native-ios`를 `/tmp/tegnal-marketing-<시각>`에 복사하고, 복사본에만 로컬 이미지 공급자와 촬영 테스트를 추가합니다. `work.nextline.tegnal.capture` 앱과 메모리 보관함을 사용하며, 실제 사이트 접속과 iCloud 동기화를 하지 않습니다. 일반 앱의 설치·설정·보관함을 덮어쓰거나 시뮬레이터를 지우지 않습니다. 기기와 런타임도 새로 만들지 않습니다.

실패 시 자동 재시도나 전체 시스템 진단 수집을 하지 않고 촬영 로그와 화면 구조로 원인을 확인합니다. `build-for-testing`으로 arm64 시뮬레이터 제품을 한 번 빌드하고 각 기기에서 `test-without-building`으로 `MarketingScreenshotsTests/testScreenshots`만 실행합니다. 기본 대상은 기존 iPhone 18 Pro, iPad Pro 13-inch (M5), iPhone Duo이며, `capture-profile.json`의 `capture_devices`에 지정된 ID가 실제로 있는지 확인합니다.

현재 촬영 범위는 한국어·다크 모드이며, 기기당 다음 11장입니다.

- 저장 첫 화면과 폴더 목록
- 탐색, 이미지 뷰어와 뷰어 메뉴
- 태그·저장한 검색, 다중 선택, 통합 백업
- 키보드가 열린 검색 기록, 더보기 최상단 배너, 세이프 모드 설정

결과는 원본 폴더의 `screenshots/ko`, `screenshots/ipad-13/ko`, `screenshots/iphone-duo/ko`와 기기별 `tegnal-*-screenshots-ko.zip`에 저장합니다. `runs/<시각>`에는 소스 지문, XCTest 원본·화면 구조·로그를 보존합니다. 각 스크린샷 폴더의 `manifest.json`에는 실제 촬영일·해상도·앱/빌드 버전·파일 SHA-256이 들어갑니다.

원본 이미지 24장의 SHA-256과 촬영 중 소스 변경 여부를 확인합니다. PNG는 크기나 RGB 픽셀을 바꾸지 않고 불투명 알파만 제거합니다. 검수용 `contact-sheet.jpg`는 제출 ZIP에 포함하지 않습니다. 촬영 후 기기별 미리보기와 개별 화면을 열어 로딩·키보드·잘림·선택 강조가 의도한 상태인지 확인하세요. 제공된 홍보용 합성 이미지와 배너는 이 도구가 덮어쓰지 않습니다.
