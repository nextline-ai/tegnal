# TEGNAL Android 개인정보처리방침 / Privacy Policy

시행일 / Effective date: 2026-10-29  
운영자 / Developer: **NextLine**  
문의 / Contact: **contact@nextline.work** · https://nextline.work

이 방침은 TEGNAL Android 앱에 적용됩니다. Apple 앱의 방침은 [별도 문서](privacy-policy.md)를 참고하세요. English follows the Korean policy below.

## 기기의 라이브러리

저장 작품, 폴더, 작가, 태그, 메모, 사이트 주소, 검색 기록, 읽던 위치, 다운로드 정보와 설정을 기기의 앱 저장소에 보관합니다. TEGNAL 자체 계정이나 개발자 운영 라이브러리 서버는 없으며, 정상적인 라이브러리 이용으로 이 데이터베이스 전체가 NextLine에 전송되지 않습니다. 앱은 자체 광고·행동 분석·오류 보고 업로드 서비스를 사용하지 않습니다.

취향 통계는 기기에서 저장·열람 활동과 작품 정보를 이용해 계산합니다. 새 분석을 중단하거나 분석 기록을 초기화할 수 있습니다. 추천 검색에 사용하는 태그는 연결한 사이트로 전달됩니다. 앱은 생성형 AI 모델을 내려받지 않습니다.

## 사이트 및 네트워크 요청

탐색, 검색, 작품 정보, 이미지, 영상 및 다운로드 요청은 사용자가 연결한 사이트와 해당 미디어 서버로 전달됩니다. 상대 서비스는 IP 주소, 요청 주소, 검색어, 작품 식별자, 사용자 에이전트 및 필요한 인증 정보·쿠키를 받을 수 있습니다. 웹페이지는 해당 사이트가 제어하는 추가 리소스를 불러올 수 있습니다. 외부 운영자의 개인정보처리방침이 적용되며 NextLine은 그들의 기록 보관·재이용·삭제를 통제하지 않습니다.

백업 가져오기 성공 후에는 빠진 커버·제목·태그를 채우는 요청이 연결한 호환 사이트로 자동 전송됩니다. 상단 안내에서 일시정지할 수 있고, 사이트가 없으면 연결을 기다립니다. 앱이 백그라운드에 있는 동안 새 채우기 작업을 진행하지 않습니다. 커버는 다시 이용할 수 있도록 기기에 캐시됩니다.

앱이 관리하는 사이트 요청은 HTTPS를 사용하며 인증서 오류를 무시하지 않습니다. 일부 Android 연결 복구 경로에서는 Cloudflare DNS-over-HTTPS 서비스로 대상 호스트명을 질의합니다. DNS 제공자는 대상 호스트명과 요청에 필요한 네트워크 정보를 받습니다. 시스템 DNS는 기기·네트워크 설정을 따릅니다. 이 기능은 VPN이나 익명성을 보장하지 않습니다. [Cloudflare 공개 DNS 개인정보 안내](https://developers.cloudflare.com/1.1.1.1/privacy/public-dns-resolver/).

## 인증 정보와 브라우저 데이터

선택적으로 입력한 사이트 계정명·API 키는 플랫폼 보안 저장소에 보관하고 해당 사이트 인증에 사용합니다. 지원 방식에 따라 인증 헤더 또는 URL 질의 항목에 포함될 수 있습니다. 내장 브라우저는 쿠키와 웹 저장소를 유지합니다. 앱의 JSON 백업에는 비밀 인증 정보와 브라우저 쿠키를 포함하지 않습니다.

앱에 저장된 인증 정보는 사이트 계정 입력란을 비워 저장해 제거할 수 있습니다. 쿠키 초기화 기능은 해당 주소의 쿠키·웹 저장소를 대상으로 합니다. 사이트 연결 제거는 연결을 보관 처리하며 저장 작품을 유지하므로, 계정·쿠키·외부 사이트 기록을 모두 삭제하는 동작은 아닙니다. 외부 사이트 계정과 기록 삭제는 해당 운영자에게 요청해야 합니다.

## 가져오기, 백업, 다운로드

사용자가 선택한 백업 파일을 읽고 요청한 경우 JSON 백업을 내보냅니다. 파일 선택기의 제공자는 클라우드 서비스일 수도 있습니다. 지원되는 만화 뷰어 백업의 원본 읽기·이미지 영역 기록은 로컬에 보존하지만 앱 JSON 내보내기에 포함되지 않습니다. 가져온 다운로드 경로나 인증 헤더를 복사하지 않습니다. 내보낸 파일과 갤러리 저장본은 앱 밖에 남으므로 직접 삭제해야 합니다.

현재 Android 버전의 Google Drive 동기화는 비활성화되어 있습니다. Android 앱은 Apple iCloud 동기화를 제공하지 않습니다. 다만 라이브러리는 Android 운영체제의 백업·기기 이전 대상이 될 수 있으며 기기 설정과 백업 제공자의 정책이 적용됩니다. 앱 백업 규칙은 WebView 데이터와 일부 접속·동기화 자료를 제외합니다. 앱의 JSON 내보내기와 운영체제 백업은 서로 다릅니다.

## 번역·공유·외부 링크

번역 동작은 설치된 Google 번역 앱의 지원 여부를 확인하고, 지원되는 경우 현재 이미지를 임시 파일의 읽기 권한과 함께 전달합니다. 직접 공유가 지원되지 않으면 사용자가 이미지 저장을 선택한 뒤 외부 앱에서 사용할 수 있습니다. 외부 앱은 자체 네트워크와 정책을 사용하며 TEGNAL은 오프라인 번역을 보장하지 않습니다. TEGNAL 자체 번역 서버는 없습니다. [Google 개인정보처리방침](https://policies.google.com/privacy).

공유, 이메일, 웹사이트 및 커뮤니티 바로가기는 사용자가 선택한 앱·서비스를 엽니다. 해당 서비스가 메시지나 접속 정보를 처리할 수 있습니다. 이미지 공유용 임시 파일은 앱 캐시에 보관하고 후속 공유 시 오래된 파일을 정리합니다. 갤러리 사본은 별도로 삭제해야 합니다.

## 보관 및 삭제

저장 작품과 메모·폴더 등은 사용자가 삭제하거나 앱 데이터를 지울 때까지 보관합니다. 검색 기록은 설정에서 저장 여부·보관 기간을 정하거나 삭제할 수 있습니다. 취향 분석 기록은 별도의 초기화 기능으로 삭제할 수 있습니다. 폴더 삭제, 캐시 삭제, 사이트 연결 제거는 작품·외부 계정 기록의 전체 삭제와 같지 않습니다.

기기에서 앱 전체 로컬 데이터를 제거하려면 Android 설정의 앱 저장공간에서 TEGNAL 데이터를 삭제할 수 있습니다. 앱 삭제 후에도 내보낸 파일, 갤러리 사본, 운영체제 백업 및 외부 서비스 기록이 남을 수 있습니다. 해당 위치의 관리 기능으로 별도 삭제하세요.

지원 문의를 보내면 발신 주소, 메시지와 선택한 첨부를 문의 처리·문제 조사에 사용합니다. 문의 정보 삭제 요청은 **contact@nextline.work**로 보내세요. NextLine이 보유한 문의 자료를 확인하여 삭제 요청을 처리하며, 법적 의무나 분쟁 대응에 필요한 경우에는 그 목적에 필요한 범위에서 보관할 수 있습니다. 비밀번호·API 키는 보내지 마세요. NextLine이 보유하지 않는 외부 사이트 기록은 해당 운영자에게 요청해야 합니다.

방침이 변경되면 이 페이지의 시행일과 내용을 갱신합니다.

---

# English

This policy applies to the **TEGNAL Android app**, developed by **NextLine**. Contact: **contact@nextline.work**, https://nextline.work. Effective date: **October 29, 2026**.

## Local library and statistics

Saved works, folders, artists, tags, notes, website addresses, search history, reading positions, download information and preferences are stored in the app's device storage. There is no TEGNAL account or developer-operated library server. Normal library use does not upload your entire database to NextLine. The app does not use its own advertising, behavioral analytics or crash-upload service.

Taste statistics use saved/opened works locally. You can stop new analysis or reset its records. Tags used to request recommendations are sent to your configured website. The app does not download generative AI models.

## Websites, enrichment and network services

Browsing, search, metadata, media and download requests go to your configured websites and their media servers. Those services can receive your IP address, requested URLs, search terms, work identifiers, user agent and necessary authentication information or cookies. Webpages may load additional resources. Their operators' policies apply; NextLine does not control their retention or deletion.

After a successful backup import, the app automatically requests missing covers, titles and tags from your configured compatible source. You can pause this in the progress notice. Without a source it waits for a connection; no new enrichment work is scheduled while the app is in the background. Covers are cached on the device.

App-managed website requests use HTTPS and do not ignore certificate errors. Some Android connection recovery paths query Cloudflare's DNS-over-HTTPS service, sending destination hostnames and necessary network information. System DNS depends on device/network settings. This is not a VPN or anonymity guarantee. See [Cloudflare's public DNS privacy information](https://developers.cloudflare.com/1.1.1.1/privacy/public-dns-resolver/).

## Credentials and browsing data

Optional website usernames and API keys are kept in platform secure storage and used to authenticate to that website. Depending on the supported API they may be sent in headers or URL query parameters. The embedded browser keeps cookies and website storage. Secret credentials and browser cookies are excluded from the app's JSON library export.

Clear saved account fields to remove credentials stored by the app. Cookie reset targets the relevant address's cookies and web storage. Removing a connection archives it and keeps saved works; it does not erase all credentials, cookies or records held by the website. Ask the website operator to delete its account or server records.

## Files, backups and external apps

The app reads backup files you select and exports JSON when requested. The file provider may itself be a cloud service. Original read/crop records from supported imports are kept locally and excluded from JSON export. Download paths and authentication headers from those backups are not imported. Exported files and gallery copies remain outside the app until separately deleted.

Google Drive sync is disabled in the current Android release. Android does not provide Apple iCloud sync. The library can nevertheless be included in Android system backup or device transfer, subject to your settings and provider. App backup rules exclude WebView data and some connection/sync material. OS backup and the app's JSON export are different mechanisms.

Translation checks the installed Google Translate app and, when supported, shares the current image using temporary file read permission. Otherwise you may explicitly save an image and use the external app. TEGNAL has no translation server and does not guarantee offline translation. The external app's policies apply, including [Google's privacy policy](https://policies.google.com/privacy). Sharing, email and website/community links open the selected external service. Temporary share images are kept in app cache with older-file cleanup during later sharing; gallery copies require separate deletion.

## Retention and deletion

Library data remains until you delete it or clear app data. Search-recording and retention settings and taste-history reset are separate controls. Removing a folder, a connection or cached images does not erase all works or external account records. Android's app-storage controls can clear TEGNAL's local data. Exported files, gallery copies, OS backups and third-party records may survive uninstallation and require separate deletion.

If you contact support, NextLine uses your sender address, message and chosen attachments to respond and investigate. Request deletion of support information at **contact@nextline.work**. We review and process requests for information we hold, retaining information only where needed for applicable obligations or disputes. Do not send passwords or API keys. Ask external website operators about records they hold. Changes to this policy will be published here with an updated effective date.
