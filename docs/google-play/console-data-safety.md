# Play Console 입력 워크시트 — Android beta4

검토일: 2026-10-29. 대상: `work.nextline.tegnal`, `1.0.0-beta.4`, versionCode `6`, minSdk `24`, targetSdk `37`. 코드·release 병합 Manifest·잠긴 의존성을 확인한 **입력 후보**이며, Console에 저장하거나 제출한 답변이 아닙니다. 최종 책임자가 아래 운영 확인을 마친 뒤 확정합니다. 상세 데이터 흐름 목록은 [기존 조사표](data-safety-draft.md)를 참조하고, 실제 답변 선택에는 이 문서를 우선 사용합니다.

표기: **코드 확인**은 이 빌드에서 확인한 사실, **운영 확인**은 사이트/SDK의 처리 또는 최종 사업자 판단이 필요한 부분입니다. 분류와 예외 적용은 단순히 권한 개수로 결정하지 않습니다. 개인 DB, 사용자 기록, 서명키는 읽지 않았습니다.

## 먼저 입력할 항목

| Console 질문 | 권장 후보 | 근거 / 확정 조건 |
| --- | --- | --- |
| 사용자 데이터를 수집하거나 공유합니까? | **예** | 앱이 제어하는 검색/API·작품 ID·미디어·DNS 요청이 기기 밖으로 나갑니다. 개발자 서버가 없다는 이유로 아니오를 선택하지 않습니다. |
| 전송되는 모든 사용자 데이터가 암호화됩니까? | **예 후보, 운영 확인 후 확정** | 앱 소유의 API·이미지·브라우저·DoH 경로는 HTTPS와 인증서 검증을 요구합니다. 출시 의존성의 추가 통신과 실제 외부 전달 범위를 확인해야 전역 답변을 확정할 수 있습니다. ECH를 종단간 암호화나 익명화의 근거로 사용하지 않습니다. |
| 앱에서 계정 생성을 지원합니까? | **TEGNAL 계정은 아니오** | 자체 계정·계정 생성·활성 Drive 로그인이 없습니다. 독립 웹사이트 계정 입력과 브라우저는 존재합니다. Console 질문의 범위를 검토하고, 웹사이트 계정을 TEGNAL 계정으로 허위 설명하지 않습니다. |
| 데이터 삭제 요청 방법을 제공합니까? | **전역 삭제 가능: 아니오 후보** | 앱의 로컬 기록/분석/인증 삭제와 별개로 임의 사이트·DNS·외부 앱의 기록까지 개발자가 지울 수 없습니다. 이메일 문의만으로 모든 수신자 데이터 삭제를 보장하지 않습니다. 자동 90일 삭제도 주장하지 않습니다. |
| 독립 보안 심사를 받았습니까? | **아니오** | 별도 인증/심사 증거가 제공되지 않았습니다. 단위검사·앱 실행검사는 독립 보안 심사 인증이 아닙니다. |

Google의 수집 범위에는 앱 제어 코드/SDK의 외부 전송이 포함됩니다. 다른 앱으로 보내는 전송도 공유 검토 대상이며, 사용자가 예상한 특정 동작은 공유 예외가 될 수 있습니다. 그 예외가 수집 항목 전체를 없애지는 않습니다. 공식 기준: [Data safety 작성 안내](https://support.google.com/googleplay/android-developer/answer/10787469?hl=en-GB).

## 데이터 유형별 선택 후보

공통 후보: 아래에서 **수집 예**인 행은 **일시적 처리 아니오**로 작성합니다. 연결 사이트 전체의 서버 보관 정책을 확인하지 못했으며, 로컬 앱이 응답을 버린다는 사실은 수신 서버가 메모리에서만 처리한다는 증거가 아닙니다. **공유 예**는 독립 수신자에 대한 처리 대행 계약이나 구체적 공유 예외가 확인되지 않은 경로를 포함한 보수적 후보입니다. 실제 예외를 확인하면 그 경로만 조정합니다.

| Console 데이터 유형 | 수집 / 공유 후보 | 필수·선택 / 목적 후보 | 코드 확인 및 운영 확인 |
| --- | --- | --- | --- |
| **App activity → In-app search history** | 수집 **예** / 공유 **예 후보** | **선택 후보** / App functionality, Personalization | 검색어·사용자 기본 태그·추천 태그가 사이트 API로 전송됩니다. 검색 기록 전체 DB를 업로드하는 것은 아닙니다. 사용자가 검색/추천을 사용하지 않고도 라이브러리를 이용할 수 있지만, 모든 사용자에게 동일한 선택권이 있는지 최종 확인합니다. 직접 요청한 검색에 공유 예외를 적용하려면 대상/전송에 대한 기대를 검토합니다. |
| **App activity → App interactions** | 수집 **예 후보** / 공유 **예 후보** | **필수 후보** / App functionality | 열람·상세 조회·미리보기와 관련된 요청이 사이트에 도달합니다. 앱의 주요 원격 콘텐츠 기능을 기준으로 필수 후보입니다. 기기에만 남는 클릭 통계를 별도로 업로드하는 코드는 확인되지 않았습니다. 실제 요청/접근 기록의 유형 매핑을 최종 확인합니다. |
| **App activity → Other actions** | 수집 **예 후보** / 공유 **예 후보** | **필수 후보** / App functionality | 가져온 저장 작품의 ID로 자동 정보 보강을 요청합니다. 열람하지 않은 저장 작품도 요청 대상이므로 단순 사용자 페이지 방문과 구분합니다. 이 행과 App interactions 중 해당 활동을 정확히 표현하는 행을 최종 결정하되, 자동 ID 전송 자체를 누락하지 않습니다. |
| **Web browsing → Web browsing history** | 수집 **예 후보** / 공유 **예 후보** | **필수 후보** / App functionality | 앱 소유 API·미디어 URL과 DoH 대상 호스트명이 독립 수신자에게 전달됩니다. 앱의 URL/호스트 요청을 이 유형에 포함하는 보수적 후보입니다. 일반 오픈웹 브라우징 예외를 앱 제어 API 재시도에 일괄 적용하지 않습니다. |
| **Personal info → User IDs** | 수집 **예** / 공유 **예 후보** | **선택** / App functionality | 사용자가 입력한 사이트 계정명/사용자 ID를 인증 요청에 사용합니다. 공개 검수 경로는 계정 없이 이용할 수 있습니다. API 비밀키도 인증 정보로 정책에 공개하되 별도의 존재하지 않는 Console 유형을 만들지 않습니다. 인증 목적의 특정 공유 예외 적용 여부는 운영 확인입니다. |
| **Device or other IDs** | 수집 **예 후보** / 공유 **예 후보** | **필수 후보** / App functionality; 보안 목적은 수신자 확인 후 추가 | 사이트 세션/검증 쿠키가 앱 제어 요청에 재사용될 수 있습니다. 광고 ID·IMEI를 읽는 코드는 확인되지 않았습니다. IP는 실제 이용 목적에 따라 판단하며, 모든 IP를 자동으로 광고 식별자나 위치로 분류하지 않습니다. 익명 세션 쿠키의 실제 사용과 선택권을 확인하기 전 필수 후보를 유지합니다. |
| **Location → Approximate location** | **운영 확인**, 보수적 포함 검토 | 포함 시 수집·공유 **예 후보**, 필수 후보 / 목적은 수신자 확인 | 위치 권한/좌표 조회는 없지만, 아래 Cloudflare 공식 설명에는 출처 국가 메타데이터가 있습니다. IP에서 추론한 지역 처리 여부와 익명화 범위를 확인해야 하므로 GPS 권한이 없다는 이유만으로 아니오를 확정하지 않습니다. Precise location 증거는 없습니다. |
| **App info and performance → Diagnostics** | **운영 확인**, 현재 미선택 후보 | 실제 SDK/수신자의 진단 전송 확인 시 수정 | 앱 전용 진단/오류 업로드 코드나 Firebase/Crashlytics가 확인되지 않았습니다. 외부 사이트의 브라우저/기기 분석 및 묶인 Google 인증 SDK 동작은 별도 확인합니다. 사이트의 방문자 집계를 곧바로 TEGNAL 자체 분석 SDK라고 설명하지 않습니다. |

**선택의 의미 확인:** 주요 원격 기능에 필요한 데이터를 단순히 “앱을 안 쓰면 안 보냄”이라는 이유로 선택으로 낮추지 않습니다. 반대로 사용자가 실제로 제공 여부를 고를 수 있는 계정명 같은 항목은 필수로 과장하지 않습니다. 공유/수집 목적에 Analytics 또는 Advertising or marketing을 일괄 추가하지 말고 실제 수신자 용도와 계약을 확인합니다.

## 로컬 처리와 사용자가 선택한 전달

| 유형 / 기능 | 현재 후보 및 경계 |
| --- | --- |
| **Installed apps** | **수집/공유 아니오 후보.** Google 번역의 지정 패키지 지원 여부만 기기에서 확인하며 설치 앱 목록/지원 여부를 서버로 보내는 코드는 없습니다. `QUERY_ALL_PACKAGES`도 없습니다. |
| **Photos and videos → Photos** / 번역 | TEGNAL의 직접 이미지 업로드는 확인되지 않았습니다. 사용자가 번역을 누르면 이미지가 Google 번역 앱에 전달되므로 **공유 예외 검토**가 필요합니다. 명시적 선택과 수신자에 대한 합리적 기대가 확인되면 이 전달은 공유 미표시 후보입니다. Google 번역 앱 자체의 네트워크/보관을 오프라인·무보관이라고 약속하지 않습니다. |
| **Files and docs** / 백업 | SQLite/JSON 파일을 선택해 로컬로 읽습니다. 전체 원본 파일을 자체 서버로 업로드하지 않습니다. 내보내기 대상이 외부 문서 제공자이면 그 명시적 전달의 공유 예외를 검토합니다. **가져오기 자체가 로컬이라는 이유로, 뒤따르는 작품 ID 보강 전송까지 로컬이라고 표시하면 안 됩니다.** |
| **Other user-generated content** / 메모·폴더·원형 아카이브 | 기본 처리는 로컬입니다. 로컬 취향 이벤트와 읽기/잘라내기 아카이브도 전용 업로드하지 않습니다. 사용자가 고른 JSON 내보내기/시스템 백업의 범위는 별도 공개합니다. 원형 `legacy.*` 아카이브는 앱 JSON 내보내기에서 제외됩니다. |
| **Email address / Emails** | 활성 Drive 프로필 수집이나 자체 이메일 계정 입력 기능은 없습니다. 지원 버튼은 외부 메일 앱을 여는 링크입니다. 사용자가 별도 메일 앱에서 쓴 메시지의 수신·보관은 사업자 문의 절차로 공개합니다. 서버 계정란에서 실제 이메일을 인증 ID로 사용하는 경우는 그 사용을 추가 확인합니다. |
| 연락처·일정·SMS·금융·건강·정밀 위치·음성 | 해당 데이터를 읽거나 외부로 보내는 앱 기능은 검토 코드에서 확인되지 않았으므로 **미선택 후보**입니다. 단순히 공유 메뉴나 보안 저장소 의존성이 있다는 이유로 수집했다고 선언하지 않습니다. |

OS 백업은 활성 Android 규칙에 따라 라이브러리를 포함할 수 있습니다. WebView 저장소·검증 경로 설정·Drive 비교 디렉터리만 명시적으로 제외합니다. 모든 데이터의 클라우드 이전이 차단되었다거나 보안 저장소까지 모든 OS 백업에서 제외된다고 보장할 수 없습니다. 실제 OS 처리와 Data safety 예외를 최종 확인합니다.

## 자동 보강과 사이트/DNS 근거

**코드 확인:** [가져오기 성공 경로](../../flutter/lib/features/settings_screen.dart)는 Android·기존 포맷·JSON 성공 후 `libraryRestored(fillMissingMetadata: true)`를 호출합니다. [큐](../../flutter/lib/core/app_controller.dart)는 저장 작품 ID를 상세 조회하고 [커버 캐시](../../flutter/lib/ui/metadata_fill.dart)를 채웁니다. 사이트가 없으면 대기하고 연결 후 재개하며, 사용자 일시중지/앱 foreground 조건이 있습니다. 사이트 등록은 자동 생성하지 않습니다. 가져오기 확인이나 진행 안내가 있다는 사실만으로 모든 자동 전송에 대한 공유 예외/사전 동의가 증명되는 것은 아닙니다. 예외에 의존하려면 실제 화면의 사전 설명과 범위를 검토합니다.

**운영 확인:** 검수 경로로 승인된 [Safebooru 공식 약관/개인정보 설명](https://safebooru.org/index.php?page=tos)은 계정명·이메일·IP 처리, 특정 동작의 IP 기록 및 브라우저/기기 정보의 방문자 분석을 설명합니다. 익명 공개 API 사용에 계정 이메일을 보낸다고 추정하지는 않지만, 이 서비스가 모든 요청을 메모리에서만 처리한다고 주장할 근거도 없습니다. 다른 사용자 지정 사이트에 같은 정책을 대입하지 않습니다. 검수 계정은 비밀번호 불필요로 확인되었습니다.

**운영 확인:** [DoH 코드](../../flutter/lib/data/manga_fallback_client.dart)의 대상은 `cloudflare-dns.com/dns-query`입니다. [Cloudflare 공식 Public Resolver 정책](https://developers.cloudflare.com/1.1.1.1/privacy/public-dns-resolver/)에는 제한된 로그/잘린 IP의 최대 25시간 처리, 국가 메타데이터, 일부 익명 자료의 APNIC 접근 및 집계 보관이 설명되어 있습니다. 따라서 DNS 경로를 무조건 일시적 처리 또는 제3자 전달 없음으로 표시하지 않습니다. 이 앱은 Cloudflare를 페이지 내용을 전송하는 애플리케이션 프록시로 사용하지 않습니다.

## App content: 광고·계정·접근·권한

| 항목 | 코드 확인 / 입력 후보 |
| --- | --- |
| 운영자·연락처 | **확정 제공값:** NextLine / `contact@nextline.work` / `https://nextline.work`. 조직 계정 인증과 앱 이름 등록 완료는 소유자가 확인했습니다. |
| Contains ads | **앱 소유 UI 기준 아니오 후보.** 광고 SDK/광고 ID 선언·광고 렌더러·결제 광고 코드는 확인되지 않았습니다. Discord/GitHub 링크 자체를 유료 광고라고 추정하지 않습니다. 최종 답변 전 후원/유료 배치와 임베디드 사이트의 실제 광고 노출을 확인합니다. SDK가 없다는 사실만으로 외부 페이지의 광고까지 없다고 보장하지 않습니다. |
| App access | TEGNAL 계정은 없습니다. 승인된 공개 검수 사이트는 비밀번호가 필요 없습니다. **추가 인증이 필요한 사이트/API 기능을 제공하는 경우 일부 제한 있음 후보**로 실제 접근 절차를 제공합니다. 공개 경로만 설명하고 나머지 제한 기능을 숨기지 않습니다. [검수 절차](review-instructions.md)를 최종 화면과 대조합니다. |
| 계정 삭제 | TEGNAL 계정을 생성하지 않는 현재 구조로 답변합니다. 독립 사이트 계정/기록은 해당 운영자에게 요청해야 합니다. 앱 로컬 삭제와 전 수신자 계정 삭제를 구분합니다. [Google 계정 삭제 범위](https://support.google.com/googleplay/android-developer/answer/13327111?hl=en)를 확인합니다. |
| Target audience / IARC | **운영자 확정 필요.** 검수 사이트 약관은 미성년자 이용을 제한하므로 성인 대상 선택을 검토해야 하며, SFW 표시만으로 아동 대상이나 특정 IARC 등급을 추정하지 않습니다. 모든 접근 가능한 콘텐츠와 기능으로 설문을 작성합니다. |
| Privacy policy | Android 실제 흐름을 반영한 공개 정책 URL과 앱 내 링크를 대조합니다. 새 계정이 없거나 분석 SDK가 없다는 이유로 정책 제출을 생략하지 않습니다. |
| Permissions declaration | 아래 병합 Manifest에는 SMS/통화 기록·광역 파일 접근·백그라운드 위치 등 제한 권한이 없습니다. Console이 실제 업로드 AAB에 표시하는 추가 선언 요구를 확인하되 존재하지 않는 권한 사용을 주장하지 않습니다. |

App content 답변 범위는 [Google 공식 검수 준비 안내](https://support.google.com/googleplay/android-developer/answer/9859455?hl=en), 개인정보 공개·동의 조건은 [User Data 정책](https://support.google.com/googleplay/android-developer/answer/10144311?hl=en)을 기준으로 최종 확인합니다.

## release Manifest와 의존성 확인 기록

로컬 근거: `flutter/build/app/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml`, `flutter/build/app/outputs/logs/manifest-merger-release-report.txt`, [pubspec.lock](../../flutter/pubspec.lock), Android 생성 플러그인 목록. 이 경로의 빌드 출력은 재생성될 수 있으므로 실제 제출 AAB와 버전을 다시 대조합니다.

| Manifest 선언 | 실제 의미 |
| --- | --- |
| `android.permission.INTERNET` | API·미디어·DNS·WebView 네트워크 기능. 런타임 허가 팝업이 없어도 전송은 발생합니다. |
| `USE_BIOMETRIC`, `USE_FINGERPRINT` | 병합 보고서상 `androidx.biometric:biometric:1.1.0`에서 추가됩니다. 앱은 `flutter_secure_storage` 기본 옵션을 사용하고 생체인증을 강제하지 않습니다. 생체 템플릿을 읽거나 전송하는 코드는 확인되지 않았습니다. 이 선언만으로 생체 데이터 수집 행을 선택하지 않습니다. |
| `work.nextline.tegnal.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION` | AndroidX의 자체 signature 보호 권한이며 사용자 개인정보 접근 권한이 아닙니다. |
| package visibility | 지정 Google 번역 패키지와 `PROCESS_TEXT` 처리 조회. 전체 설치 앱 목록 조회 권한이 아닙니다. |

병합 `uses-permission`에는 **AD_ID, QUERY_ALL_PACKAGES, 위치, 카메라, 마이크, 연락처, SMS, 광역 저장소/사진 읽기, 알림, WAKE_LOCK가 없습니다.** 수신자/서비스의 `android:permission` 접근 보호 속성은 앱이 그 권한을 요청한다는 뜻이 아닙니다. 사진 저장은 사용자가 고른 MediaStore 경로, 파일 가져오기는 시스템 선택기를 사용합니다.

핵심 의존성: `ech_http 0.2.3`, `http 1.6.0`, `google_sign_in_android 7.2.18`, `flutter_secure_storage 11.2.0`, `file_selector_android 0.5.2+11`, `media_kit_libs_android_video 1.3.8`, `url_launcher_android 6.3.33`, `wakelock_plus 1.8.2`, SQLite 및 Flutter. 직접/병합 정보에서 Firebase·Crashlytics·광고 SDK는 확인되지 않았습니다.

[Drive 기능 플래그](../../flutter/lib/core/app_features.dart)는 false이고 [main](../../flutter/lib/main.dart)은 Drive 컨트롤러를 생성하지 않습니다. Google 인증 플러그인은 여전히 등록되며 네이티브 인증/자격증명 라이브러리는 묶여 있으므로, 기능 비활성화를 근거로 모든 SDK 통신을 무조건 없다고 단정하지 않습니다. 플러그인 초기 등록은 delegate/channel 연결이며 실제 자격증명 요청은 별도 API 호출입니다. [Google의 core Play services 설명](https://developers.google.com/android/guides/play-data-disclosure)은 base/basement/tasks 등에 한정되므로 다른 인증/FIDO SDK의 무수집 증명으로 확대하지 않습니다. SDK의 기본 수집까지 검토해야 한다는 [SDK 요구사항](https://support.google.com/googleplay/android-developer/answer/13323374?hl=en-GB)을 적용합니다.

## 최종 확정 전 남은 최소 확인

1. 위 표의 데이터 유형 중 요청/활동/URL 매핑, 쿠키·IP 사용, 위치 추론 및 수신자 목적을 확정하고 공유 예외를 적용할 경로만 문서화합니다.
2. 제출 AAB에서 SDK 기본 통신·광고/임베디드 페이지·HTTPS 범위를 확인합니다. 이번 검토는 코드/Manifest 기반이며 실제 트래픽 캡처나 Console 저장을 수행하지 않았습니다.
3. 공개 Android 정책과 사전 안내가 **자동 보강의 ID·커버 요청**까지 설명하는지 확인합니다. 외부 사이트의 보관/삭제를 개발자 통제처럼 표시하지 않습니다.
4. 운영자가 실제 목적·보관·삭제·대상 연령을 승인한 최종 답변을 버전과 함께 보관합니다. 이 문서의 보수적 후보를 검증 없이 자동 제출하지 않습니다.
