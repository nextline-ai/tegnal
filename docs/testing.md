# 필요한 테스트만 실행하기

작은 변경은 전체 회귀 테스트의 실행 사유가 아니다. 문구·문서·단순 스타일은 확인이나 빌드만으로 끝낼 수 있다. 로직 수정은 관련 메서드부터 선택하고, 통과하면 종료한다. 전체 단위/UI 테스트는 사용자가 명시적으로 요청할 때만 실행한다. 모든 AI 에이전트는 루트 `AGENTS.md`의 같은 정책을 따른다.

```sh
# 목록/도움말은 빌드나 시뮬레이터 부팅을 하지 않는다.
python3 script/test.py
python3 script/test.py --list

# 실행 범위를 먼저 확인한다.
python3 script/test.py --scope grid --dry-run

# 관련 메서드 하나 (괄호 생략 가능)
python3 script/test.py --only GridLayoutTests/testPreviewColumnsFollowTwiceTheResolvedArtworkColumnsOrAnExplicitChoice

# 필요한 경우 관련 클래스 하나
python3 script/test.py --scope catalog

# UI는 해당 동작의 메서드를 명시한다. 전체 클래스 선택은 거부한다.
python3 script/test.py --only TEGNALUITests/NativeContentUITests/testPreviewColumnSettingCreatesProportionalGridWithoutPageNumbers
```

`--only`는 반복할 수 있다. 기본 기기는 기존 iPhone 18 Pro이며 `--device UDID`로 다른 기존 기기를 지정한다. 기기가 없으면 오류로 종료하고 자동으로 만들지 않는다. 병렬 테스트/커버리지는 끄며, 성공 후 전체 테스트를 추가 실행하지 않는다. 스크립트는 변경 파일을 추측해 테스트 범위를 넓히지 않는다.

| 변경 영역 | 선택할 범위 |
| --- | --- |
| ID/공유 링크 파싱 | `parser` |
| 문서 목록·메타데이터·페이지 URL | `catalog` |
| 사이트 탐색·엔드포인트 | `backend` |
| 만화 콘텐츠·브라우저 설정 | `content` |
| 리더·페이지 이동·이미지 캐시 | `reader` |
| 카드·열 수·그리드 | `grid` |
| 다운로드 / 미디어 입력 | `downloads` / `media` |
| 이미지 서버 API / 수정 회귀 | `booru` / `booru-revision` |
| 이미지 보관함 / 썸네일 캐시 / 백업 | `booru-library` / `booru-cache` / `booru-backup` |
| 이미지 디코딩 큐·뷰어 다운로드 수명 | `image-cache` |
| 통합 백업 / 동기화 | `backup` / `sync` |
| 취향 분석 / 추천 피드 | `taste` / `taste-feed` |
| 챌린지 / 모달 표시 | `challenge` / `presentation` |

범위 하나도 큰 경우 관련 메서드를 지정한다. `reader`, `content`, `booru` 등은 클래스 단위로도 여러 테스트가 실행된다. UI 레이아웃 변경만으로 UI 클래스 전체나 모든 언어/기기 검증을 시작하지 않는다.

## Xcode 테스트 플랜

- `Smoke` (기본): URL 파싱·미리보기 열 수·리더 종료 제스처의 작은 테스트 3개. 필터 없는 기본 테스트 명령의 실행량을 제한하는 안전장치이며, 매 수정마다 실행할 의무는 없다.
- `Unit`: 단위 테스트 대상만 포함한다. 네트워크/iCloud 실검증 및 설치된 번역 엔진을 사용하는 두 테스트는 제외한다. 선택 실행 스크립트가 `-only-testing`으로 범위를 제한한다.
- `UI`: UI 대상만 포함한다. 일반 작업에서는 개별 메서드를 선택한다.

`Unit`이나 `UI` 플랜을 Xcode에서 필터 없이 실행하면 해당 플랜 전체가 실행된다. 전체 실행은 명시적인 요청이 있을 때만 한다. 실제 전체 회귀가 필요하면 요청 범위에 맞는 플랜을 직접 선택한다. 플랜은 [Xcode 공식 테스트 플랜 방식](https://developer.apple.com/documentation/xcode/organizing-tests-to-improve-feedback)을 사용하고 [XcodeGen의 testPlans 설정](https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md#test-plan)으로 스킴에 연결한다.

네트워크/iCloud/Apple 번역 실검증은 일반 선택 실행과 분리한다. 명시적으로 요청받았을 때 `NativeContentDeviceValidation` 또는 `BooruDeviceValidation` 스킴에 **대상 메서드의 `-only-testing` 필터**와 필요한 실기기 destination을 지정한다. 서버 설정과 계정 등 기존 환경이 필요하다. 이 스킴들은 실제 서비스에 연결하므로 일상적인 검사로 실행하지 않는다.

플랜 수정 후 `xcodegen generate --spec native-ios/project.yml`로 생성 스킴을 갱신한다. 생성 후 훅이 플랜의 타깃 ID도 자동으로 맞춘다. 테스트 클래스/메서드를 바꾸면 Smoke 선택 목록과 Unit 제외 목록도 확인한다.

## 시뮬레이터 보관 정책

일반 작업은 iPhone 18 Pro (iOS 27.0) 하나만 사용한다. iPad 전용 동작에는 iPad Pro 11-inch (M5, iOS 27.0), 접기/크기 변경 동작에는 iPhone Duo (iOS 27.1)를 선택한다. 세 기기를 매번 모두 검증하는 규칙은 없다.

Duo용 iOS 27.1 런타임은 Duo만 지원하므로 일반 iPhone/iPad용 iOS 27.0 런타임과 함께 보관한다. 기기·런타임을 자동으로 늘리지 않고 기존 기기를 재사용한다.
