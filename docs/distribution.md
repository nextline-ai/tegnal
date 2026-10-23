# TEGNAL 배포

공개 베타는 [TestFlight](https://testflight.apple.com/join/gnkqu44W), 다시 서명해 설치할 IPA는 [GitHub Releases](https://github.com/nextline-ai/tegnal/releases)에서 배포합니다. AltStore Classic과 SideStore는 하나의 [소스 JSON](https://nextline-ai.github.io/tegnal/source.json)을 사용합니다.

## 배포 경로

| 항목 | 위치 |
| --- | --- |
| 다운로드 페이지 | `https://nextline-ai.github.io/tegnal/` |
| 공통 소스 | `https://nextline-ai.github.io/tegnal/source.json` |
| GitHub Pages 원본 | `main` 브랜치의 `/docs` |
| IPA | GitHub Release의 `TEGNAL-<version>-<build>.ipa` 첨부 파일 |

기본 설치 경로는 TestFlight입니다. README와 다운로드 페이지에서 AltStore Classic·SideStore·IPA는 기본적으로 접힌 선택 항목으로 제공합니다. README의 소스 등록 HTTPS 버튼은 다운로드 페이지의 해당 선택 항목을 펼쳐 엽니다. 페이지의 소스 등록 버튼이 `altstore://source?url=…` 또는 `sidestore://source?url=…`를 열며, 앱이 설치되지 않은 경우를 위해 소스 주소 복사도 제공합니다. GitHub README는 앱 전용 URL 스킴을 제한하므로 소스 등록은 이 페이지를 거칩니다.

## 다음 버전 배포

1. `native-ios/project.yml`과 `native-ios/TEGNAL.xcodeproj/project.pbxproj`의 앱·공유 확장 버전을 함께 올립니다. 이미 공개한 버전과 빌드 번호 조합은 재사용하지 않습니다.
2. Xcode에서 **TEGNAL → Any iOS Device → Product → Archive**를 실행합니다. TestFlight 배포는 Organizer에서 App Store Connect로 업로드합니다. Xcode가 업로드 중 빌드 번호를 올릴 수 있으므로 내보내는 IPA의 번호도 확인합니다.
3. 사이드로딩용으로는 동일 소스의 기기용 **Release** 아카이브를 **Debugging** 방식으로 로컬 내보내기 합니다. 시뮬레이터 빌드나 TestFlight에서 내려받은 암호화 IPA를 사용하지 않습니다. 설치 도구가 사용자의 계정으로 다시 서명하는 IPA이며, 등록 기기에만 직접 설치할 수 있는 개발 서명 자체를 배포 권한으로 사용하지 않습니다.
4. IPA 이름과 Release 태그를 정한 뒤 아래 명령으로 소스를 갱신합니다. 같은 앱 버전의 핫픽스는 빌드 번호를 올리고 `v1.0.0-8`처럼 태그에 빌드 번호를 포함합니다. macOS의 `codesign`과 Python 3가 필요합니다.

```sh
python3 scripts/update-alt-source.py /path/to/TEGNAL-1.0.0-8.ipa \
  --download-url https://github.com/nextline-ai/tegnal/releases/download/v1.0.0-8/TEGNAL-1.0.0-8.ipa \
  --date 2026-10-23 \
  --notes 'What changed in this release.'
```

스크립트는 IPA에서 번들 ID·버전·빌드·최소 iOS 버전·파일 크기·앱 및 확장 권한을 읽습니다. 새 버전을 `docs/source.json` 맨 앞에 추가하고, 이전 버전은 유지합니다. 앱 아이콘도 실제 빌드에서 가져옵니다. 같은 버전·빌드의 메타데이터가 달라지면 덮어쓰지 않고 중단합니다.

5. README 두 언어의 버전과 `docs/index.html`의 기본 버전 표기를 갱신합니다. 다운로드 페이지는 소스를 불러온 뒤 최신 버전을 표시합니다.
6. IPA의 SHA-256 체크섬을 만들고 GitHub Release에 IPA와 `SHA256SUMS.txt`를 첨부합니다. 소스의 다운로드 URL·파일 크기와 첨부 파일이 일치하는지 확인한 뒤 소스와 문서를 커밋·푸시합니다. Release 태그는 해당 커밋을 가리키도록 지정합니다.
7. GitHub Pages 배포 후 페이지·소스·아이콘과 IPA 다운로드가 모두 정상 응답하는지 확인합니다. iPhone/iPad의 Safari에서 각 소스 등록과 실제 설치도 확인합니다.

## 권한과 서명

소스의 `appPermissions`는 메인 앱과 공유 확장의 entitlement 및 Info.plist 사용 목적 문구를 합친 값입니다. 새 권한을 추가할 때 반드시 IPA에서 다시 생성하세요. [AltStore 소스 사양](https://faq.altstore.io/developers/make-a-source)과 [SideStore URL 스킴](https://docs.sidestore.io/docs/advanced/url-schema)을 기준으로 합니다.

iCloud 기능은 다시 서명하는 Apple 계정·설치 도구가 제공하는 capability에 따라 제한될 수 있습니다. iCloud 동작을 우선한다면 TestFlight 설치본을 사용하세요. 사이드로딩 설치본에서도 통합 JSON으로 보관함을 백업·복원할 수 있습니다.

이 배포는 AltStore Classic용 IPA 배포입니다. AltStore PAL의 notarized 배포 패키지는 제공하지 않습니다. 인증서·개인 키·로컬 프로비저닝 파일은 저장소에 올리지 않습니다.
