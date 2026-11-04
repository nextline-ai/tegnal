# TEGNAL Android 개인정보처리방침 / Privacy Policy

시행일 / Effective date: 2026-11-04

운영자 / Developer: **NextLine**

문의 / Contact: **contact@nextline.work** · https://nextline.work

이 방침은 TEGNAL Android 앱에 적용됩니다. Apple 앱의 방침은 [별도 문서](privacy-policy.md)를 참고하세요. English follows the Korean policy below.

## 기기의 라이브러리

저장 작품, 폴더, 작가, 태그, 메모, 사이트 주소, 검색 기록, 읽던 위치, 다운로드한 작품과 설정을 기기의 앱 저장소에 보관합니다. TEGNAL 자체 계정이나 개발자 운영 라이브러리 서버는 없으며, 정상적인 라이브러리 이용으로 이 데이터베이스 전체가 NextLine에 전송되지 않습니다. 앱은 광고, 행동 분석, 오류 보고 업로드 서비스를 사용하지 않으며(이미지 번역 기능의 Google ML Kit 진단 정보는 아래 "이미지 번역"을 참고하세요), 앱이 요청하는 권한은 인터넷 접근뿐입니다.

취향 통계와 리캡은 기기에서 저장·열람 활동과 작품 정보를 이용해 계산합니다. 리캡의 감상 시간을 위해 작품이 화면에 머문 시간과 본 페이지 수도 기기에만 기록합니다. 새 분석을 중단하거나 분석 기록을 초기화할 수 있습니다. 추천을 찾기 위한 태그 검색은 연결한 사이트로 전달됩니다. 챌린지 룰렛의 챌린지 정의, 진행 상황, 이미지 출처 선택도 기기에만 저장합니다. 앱은 생성형 AI 모델을 내려받지 않습니다.

## 사이트 및 네트워크 요청

탐색, 검색, 작품 정보, 이미지, 영상 및 다운로드 요청은 사용자가 연결한 사이트와 해당 미디어 서버로 전달됩니다. 상대 서비스는 IP 주소, 요청 주소, 검색어, 작품 식별자, 사용자 에이전트 및 필요한 인증 정보·쿠키를 받을 수 있습니다. 웹페이지는 해당 사이트가 제어하는 추가 리소스를 불러올 수 있습니다. 외부 운영자의 개인정보처리방침이 적용되며 NextLine은 그들의 기록 보관·재이용·삭제를 통제하지 않습니다.

일부 사이트는 앱의 직접 연결 대신 브라우저 확인을 요구합니다. 이 경우 앱은 화면에 보이지 않는 앱 내부 웹뷰(Android System WebView)를 통해 같은 사이트에 요청을 보내며, 이 웹뷰는 클라이언트 확인 화면 및 내장 브라우저와 같은 쿠키를 사용합니다. 어떤 사이트가 브라우저 확인을 요구했는지는 다음 실행에서 바로 웹뷰를 쓰도록 기기에 잠시 기억합니다. 설정에서 "내장 브라우저 사용"을 켜면 앱 화면 대신 사이트 자체를 앱 안의 브라우저로 엽니다.

백업 가져오기 성공 후에는 빠진 커버·제목·태그를 채우는 요청이 연결한 호환 사이트로 자동 전송됩니다. 상단 안내에서 일시정지할 수 있고, 사이트가 없으면 연결을 기다립니다. 앱이 백그라운드에 있는 동안 새 채우기 작업을 진행하지 않습니다. 커버와 이미지는 다시 이용할 수 있도록 기기에 캐시됩니다.

앱이 관리하는 사이트 요청은 HTTPS를 사용하며 인증서 오류를 무시하지 않습니다. DNS 조회는 기기와 네트워크 설정을 따르며, 앱은 별도의 DNS 서비스나 프록시를 사용하지 않습니다.

일부 네트워크는 접속하려는 서버 이름을 보고 연결을 중간에 끊습니다. 앱의 연결이 이렇게 끊기면 Android 14 이상에서는 같은 요청을 Android 기본 네트워크 스택(HttpEngine)으로 다시 보내며, 사이트가 DNS에 암호화 키를 공개한 경우 서버 이름을 암호화(Encrypted Client Hello)합니다. 요청은 사이트에 직접 전달되며 NextLine이나 다른 중계 서버를 거치지 않습니다. 이 경로가 필요했던 서버의 호스트 이름은 다음 실행에서 바로 이 경로를 쓰도록 최대 7일 동안 기기에 기억합니다. 만화 모드에서는 그래도 연결되지 않는 요청을 화면에 보이지 않는 웹뷰로 같은 사이트에 보낼 수 있습니다.

## 인증 정보와 브라우저 데이터

선택적으로 입력한 사이트 계정명·API 키와 사이트 로그인 쿠키는 Android Keystore로 보호되는 저장소에 보관하고 해당 사이트 인증에 사용합니다. 지원 방식에 따라 인증 헤더 또는 URL 질의 항목에 포함될 수 있습니다. 화면에 보이지 않는 웹뷰를 거치는 요청에는 계정명과 API 키를 넣지 않으며, 만화 모드에서 로그인한 사이트의 쿠키만 앱이 실행되는 동안 만료 시각 없이 웹뷰에 전달합니다. 클라이언트 확인 화면과 내장 브라우저는 쿠키와 웹 저장소를 유지합니다. 앱의 백업 파일에는 비밀 인증 정보와 브라우저 쿠키를 포함하지 않습니다.

앱에 저장된 인증 정보는 사이트 계정 입력란을 비워 저장해 제거할 수 있습니다. 쿠키 초기화 기능은 웹뷰의 쿠키·웹 저장소를 지웁니다. 사이트 연결 제거는 연결을 보관 처리하며 저장 작품을 유지하므로, 계정·쿠키·외부 사이트 기록을 모두 삭제하는 동작은 아닙니다. 외부 사이트 계정과 기록 삭제는 해당 운영자에게 요청해야 합니다.

## 가져오기, 백업, 다운로드

사용자가 선택한 백업 파일(TEGNAL 백업, 챌린지 백업, Violet 북마크 백업, Anime Boxes 백업, 다른 만화 뷰어의 데이터베이스)을 기기에서 읽고, 요청한 경우 백업 파일을 내보냅니다. 파일 선택기의 제공자는 클라우드 서비스일 수도 있습니다. 지원되는 만화 뷰어 백업의 원본 읽기·이미지 영역 기록과 Violet 백업에서 가져온 마지막 읽은 시각은 로컬에 보존하지만 앱 백업 내보내기에 포함되지 않습니다. 가져온 다운로드 경로나 인증 헤더를 복사하지 않습니다. 다운로드한 작품은 앱 저장소에 보관되어 앱을 삭제하면 함께 삭제되며, 내보낸 파일은 앱 밖에 남으므로 직접 삭제해야 합니다.

Google Drive 백업은 준비 중이며 현재 Android 버전에서는 Google 계정 로그인이나 Drive 전송이 이루어지지 않습니다. Android 앱은 Apple iCloud 동기화를 제공하지 않습니다. 다만 라이브러리는 Android 운영체제의 백업·기기 이전 대상이 될 수 있으며 기기 설정과 백업 제공자의 정책이 적용됩니다. 앱 백업 규칙은 웹뷰 데이터와 일부 접속·동기화 자료를 제외하며, 보안 저장소의 인증 정보는 새 기기에서 다시 입력해야 할 수 있습니다. 앱의 백업 내보내기와 운영체제 백업은 서로 다릅니다.

## 공유·외부 링크·화면 보호

공유, 이메일, 웹사이트 및 커뮤니티 바로가기는 사용자가 선택한 앱·서비스를 엽니다. 해당 서비스가 메시지나 접속 정보를 처리할 수 있습니다. 리캡 카드를 공유하면 이미지 파일을 앱 캐시에 만들어 사용자가 고른 앱에 읽기 권한과 함께 전달하며, 이 파일은 다음 공유 때 교체됩니다.

앱이 화면에서 벗어나면 앱 전환 화면에 작품 대신 TEGNAL 화면이 표시됩니다. Android 12 이하에서는 앱이 백그라운드에 있는 동안에만 화면 캡처가 제한됩니다.

## 이미지 번역

뷰어의 번역은 Google ML Kit로 기기에서 이미지의 글자를 인식하고, 언어를 판별해 번역 언어로 옮깁니다. 이미지, 인식한 글자와 번역 결과는 NextLine이나 번역 서버로 전송되지 않습니다. 번역하는 동안 이미지를 앱 캐시에 잠시 저장하며 번역이 끝나면 삭제합니다. 번역 언어 설정은 기기에 저장합니다.

글자 인식 모듈은 앱 설치 후 또는 처음 번역할 때 Google Play 서비스를 통해, 번역 모델은 언어 쌍마다 처음 사용할 때 한 번 Google에서 내려받아 기기에 보관합니다. 이때 Google은 IP 주소와 요청 정보를 받을 수 있습니다. ML Kit는 기능 진단과 이용 분석을 위해 기기 정보(제조사, 모델, OS 버전), 앱 정보(패키지 이름, 버전), 설치별 식별자, 성능 지표, 오류 코드, 판별한 언어와 번역 언어 쌍을 HTTPS로 Google에 보낼 수 있습니다. 이 정보에는 이미지나 글자 내용이 포함되지 않으며 [Google 개인정보처리방침](https://policies.google.com/privacy)이 적용됩니다. 글자 인식, 언어 판별과 번역은 사용자가 번역을 실행할 때만 동작합니다. 뷰어 설정에서 AI 번역(베타)을 켜면 번역을 켜 둔 동안 넘기는 페이지와 바로 다음 페이지를 차례로 번역합니다.

AI 번역(베타)을 켰고 기기에 Android AICore의 Gemini Nano가 설치되어 있으면, 대화 흐름을 살리기 위해 한 페이지의 말풍선 글자와 앞 페이지의 원문·번역 몇 줄을 함께 기기 안의 모델로 번역합니다. 이 글자는 기기를 벗어나지 않으며 NextLine이나 다른 서버로 전송되지 않습니다. 앱이 모델을 내려받게 하지 않으며, 모델이 없는 기기에서는 위의 ML Kit 번역을 사용합니다. AICore 자체의 진단 정보 처리에는 Google 개인정보처리방침이 적용됩니다.

## 보관 및 삭제

저장 작품과 메모·폴더 등은 사용자가 삭제하거나 앱 데이터를 지울 때까지 보관합니다. 검색 기록은 설정에서 저장 여부·보관 기간을 정하거나 삭제할 수 있습니다. 취향 분석 기록은 별도의 초기화 기능으로, 챌린지는 챌린지 목록에서 삭제할 수 있습니다. 폴더 삭제, 캐시 삭제, 사이트 연결 제거는 작품·외부 계정 기록의 전체 삭제와 같지 않습니다.

기기에서 앱 전체 로컬 데이터를 제거하려면 Android 설정의 앱 저장공간에서 TEGNAL 데이터를 삭제할 수 있습니다. 앱 삭제 후에도 내보낸 파일, 운영체제 백업 및 외부 서비스 기록이 남을 수 있습니다. 해당 위치의 관리 기능으로 별도 삭제하세요.

지원 문의를 보내면 발신 주소, 메시지와 선택한 첨부를 문의 처리·문제 조사에 사용합니다. 문의 정보 삭제 요청은 **contact@nextline.work**로 보내세요. NextLine이 보유한 문의 자료를 확인하여 삭제 요청을 처리하며, 법적 의무나 분쟁 대응에 필요한 경우에는 그 목적에 필요한 범위에서 보관할 수 있습니다. 비밀번호·API 키는 보내지 마세요. NextLine이 보유하지 않는 외부 사이트 기록은 해당 운영자에게 요청해야 합니다.

방침이 변경되면 이 페이지의 시행일과 내용을 갱신합니다.

---

# English

This policy applies to the **TEGNAL Android app**, developed by **NextLine**. Contact: **contact@nextline.work**, https://nextline.work. Effective date: **November 4, 2026**.

## Local library and statistics

Saved works, folders, artists, tags, notes, website addresses, search history, reading positions, downloaded works and preferences are stored in the app's device storage. There is no TEGNAL account or developer-operated library server. Normal library use does not upload your entire database to NextLine. The app does not use advertising, behavioral analytics or crash-upload services (for the Google ML Kit diagnostics of image translation, see "Image translation" below), and the only permission it requests is internet access.

Taste statistics and Recap are calculated locally from saved and opened works. For Recap, viewing time and pages viewed are also recorded on this device only. You can stop new analysis or reset its records. Tag searches used to find recommendations are sent to your configured website. Challenge Roulette definitions, progress and image-source choices are also kept on this device only. The app does not download generative AI models.

## Websites, enrichment and network services

Browsing, search, metadata, media and download requests go to your configured websites and their media servers. Those services can receive your IP address, requested URLs, search terms, work identifiers, user agent and necessary authentication information or cookies. Webpages may load additional resources. Their operators' policies apply; NextLine does not control their retention or deletion.

Some websites require a browser check instead of the app's direct connection. In that case the app sends its requests to the same website through an invisible in-app web view (Android System WebView), which uses the same cookies as Validate Client and the embedded browser. The app briefly remembers on the device which websites asked for a browser check, so the next launch can use the web view right away. When "Use Embedded Browser" is on, the website itself opens in an in-app browser instead of the app's own screens.

After a successful backup import, the app automatically requests missing covers, titles and tags from your configured compatible source. You can pause this in the progress notice. Without a source it waits for a connection; no new enrichment work is scheduled while the app is in the background. Covers and images are cached on the device.

App-managed website requests use HTTPS and do not ignore certificate errors. DNS lookups follow your device and network settings; the app does not use its own DNS service or proxy.

Some networks cut connections based on the server name being contacted. When that happens to the app's connection on Android 14 or later, the app retries the same request through Android's built-in network stack (HttpEngine), which encrypts the server name (Encrypted Client Hello) when the website publishes the keys for it in DNS. Requests still go directly to the website, never through NextLine or another relay. The app remembers the host names of servers that needed this route on the device for up to 7 days, so the next launch uses it right away. In Comics mode, requests that still cannot connect may be sent to the same website through the invisible web view.

## Credentials and browsing data

Optional website usernames, API keys and website sign-in cookies are kept in storage protected by the Android Keystore and used to authenticate to that website. Depending on the supported API they may be sent in headers or URL query parameters. Requests through the invisible web view never carry usernames or API keys; in Comics mode, the sign-in cookies of a website you signed in to are passed to that web view without an expiry, for as long as the app runs. Validate Client and the embedded browser keep cookies and website storage. Secret credentials and browser cookies are excluded from the app's backup files.

Clear saved account fields to remove credentials stored by the app. Cookie reset clears the web view's cookies and website storage. Removing a connection archives it and keeps saved works; it does not erase all credentials, cookies or records held by the website. Ask the website operator to delete its account or server records.

## Files, backups and downloads

The app reads backup files you select (TEGNAL backups, challenge backups, Violet bookmark backups, Anime Boxes backups and another manga viewer's databases) on the device and exports backup files when requested. The file provider may itself be a cloud service. Original read/crop records from supported imports, and last-read times from Violet backups, are kept locally and excluded from backup export. Download paths and authentication headers from those backups are not imported. Downloaded works stay in the app's storage and are removed with the app; exported files remain outside the app until you delete them.

Google Drive backup is coming soon; the current Android version does not sign in to a Google account or transfer anything to Drive. Android does not provide Apple iCloud sync. The library can nevertheless be included in Android system backup or device transfer, subject to your settings and provider. App backup rules exclude web view data and some connection and sync material, and credentials in secure storage may need to be entered again on a new device. OS backup and the app's backup export are different mechanisms.

## Sharing, external links and screen protection

Sharing, email and website or community links open the external app or service you choose, which may process the message or connection information. When you share a Recap card, the app creates an image file in its cache and passes it to the app you choose with read permission; the file is replaced the next time you share.

When you leave the app, the app switcher shows the TEGNAL screen instead of your works. On Android 12 and earlier, screen capture is restricted only while the app is in the background.

## Image translation

Translate in the viewer uses Google ML Kit to recognize the text in an image on the device, identify its language and translate it into your translation language. Images, recognized text and translations are not sent to NextLine or to a translation server. The image is kept briefly in the app cache while it is translated and deleted afterward. Your translation language choice is stored on the device.

Text recognition modules arrive through Google Play services after installation or on first use, and each language pair's translation model is downloaded once from Google the first time it is needed and kept on the device; Google can receive your IP address and request information when this happens. For diagnostics and usage analytics, ML Kit may send Google device information (manufacturer, model, OS version), app information (package name, version), a per-installation identifier, performance metrics, error codes, and the identified languages and translation language pair over HTTPS. This does not include image or text content, and the [Google Privacy Policy](https://policies.google.com/privacy) applies. Recognition, language identification and translation run only when you choose Translate. With AI Translation (Beta) turned on in the viewer settings, translation stays on and translates each page you turn to and the one after it.

With AI Translation (Beta) on, and on devices where Android AICore has Gemini Nano installed, a page's balloon text is translated together with a few original and translated lines from the pages before it by that on-device model, so conversations read naturally. This text stays on the device and is not sent to NextLine or any other server. The app never makes the device download the model; devices without it use ML Kit translation as described above. The Google Privacy Policy applies to AICore's own diagnostics.

## Retention and deletion

Library data remains until you delete it or clear app data. Search-recording and retention settings, taste-history reset and challenge deletion are separate controls. Removing a folder, a connection or cached images does not erase all works or external account records. Android's app-storage controls can clear TEGNAL's local data. Exported files, OS backups and third-party records may survive uninstallation and require separate deletion.

If you contact support, NextLine uses your sender address, message and chosen attachments to respond and investigate. Request deletion of support information at **contact@nextline.work**. We review and process requests for information we hold, retaining information only where needed for applicable obligations or disputes. Do not send passwords or API keys. Ask external website operators about records they hold. Changes to this policy will be published here with an updated effective date.
