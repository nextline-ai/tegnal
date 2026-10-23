<p align="right"><b>한국어</b> &nbsp; / &nbsp; <a href="README.en.md">English</a></p>

<p align="center">
  <a href="https://testflight.apple.com/join/gnkqu44W">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="docs/assets/tegnal-hero-dark.svg">
      <img src="docs/assets/tegnal-hero-light.svg" alt="TEGNAL — Comics. Images. Your collection." width="100%">
    </picture>
  </a>
</p>

<p align="center"><b>읽는 즐거움과 모으는 취향, 하나의 보관함.</b><br>
만화와 일러스트를 탐색하고, 감상하고, 나만의 컬렉션으로 정리하는 네이티브 iOS 앱.</p>

<p align="center"><sub>1.0.0 (7) &nbsp; · &nbsp; iOS 17+ &nbsp; · &nbsp; iPhone & iPad &nbsp; · &nbsp; 한국어 / English / 日本語</sub></p>

<p align="center">
  <a href="https://testflight.apple.com/join/gnkqu44W"><img src="docs/assets/button-testflight.svg" alt="TestFlight에서 설치" width="184" height="56"></a>
  <a href="https://nextline-ai.github.io/tegnal/#altstore"><img src="docs/assets/button-altstore.svg" alt="AltStore Classic 소스 등록" width="184" height="56"></a>
  <a href="https://nextline-ai.github.io/tegnal/#sidestore"><img src="docs/assets/button-sidestore.svg" alt="SideStore 소스 등록" width="184" height="56"></a>
  <a href="https://github.com/nextline-ai/tegnal/releases/latest"><img src="docs/assets/button-ipa.svg" alt="GitHub Release에서 IPA 다운로드" width="184" height="56"></a>
</p>

<p align="center"><a href="#설치">설치 안내</a> &nbsp; · &nbsp; <a href="#두-가지-감상-하나의-앱">기능 살펴보기</a> &nbsp; · &nbsp; <a href="https://github.com/nextline-ai/tegnal/releases">릴리스 노트</a> &nbsp; · &nbsp; <a href="https://discord.gg/vUTGZNMaMB">커뮤니티</a></p>

---

## 두 가지 감상, 하나의 앱

**만화는 흐름에 맞게. 이미지는 취향에 맞게.** 상단의 모드 전환으로 두 가지 감상 환경을 오가고, 마음에 드는 작품은 길게 눌러 보관하세요.

| | 만화 모드 | 이미지 모드 |
| :--- | :--- | :--- |
| **탐색** | 작품 검색, 인기 작품, 작가별 모아보기 | Danbooru·Gelbooru·Moebooru 계열 서버, 태그 검색, 여러 서버 탐색 |
| **감상** | 읽기 방향 선택, 페이지 넘김, 연속 스크롤, 이미지 번역 | 고해상도 이미지, GIF·동영상, 풀과 노트, 이미지 번역 |
| **정리** | 북마크, 작가, 폴더 | 저장한 작품, 색상별 폴더, 비슷한 이미지 찾기 |
| **가져오기** | 다른 만화 뷰어의 `user.db` / `data.db` | Anime Boxes의 `.abbj` |

### 감상에 집중하는 디테일

- **다음 페이지를 미리 준비합니다.** 만화 뷰어는 주변 페이지를 미리 불러오고 캐시를 재사용합니다. 페이지를 넘겨도 진행 중인 미리 읽기를 이어갑니다.
- **취향은 기기 안에서 읽습니다.** 저장한 작품과 태그를 바탕으로 추천과 리캡을 만들고, Apple Vision으로 비슷한 이미지를 찾습니다.
- **이미지 속 문장을 번역합니다.** 지원되는 기기와 OS에서 Apple의 텍스트 인식·번역 기능을 사용합니다.
- **참고 이미지는 연습으로 이어집니다.** 챌린지 룰렛에서 크로키 타이머와 나만의 미션을 구성할 수 있습니다.

## 설치

### TestFlight

[Apple TestFlight](https://apps.apple.com/kr/app/testflight/id899247664)를 설치한 뒤 **[TEGNAL 베타 참여](https://testflight.apple.com/join/gnkqu44W)**에서 앱을 설치하세요. 현재 공개 베타는 **1.0.0 (7)**입니다.

### AltStore Classic · SideStore

설치된 AltStore Classic 또는 SideStore가 있다면 **[다운로드 페이지](https://nextline-ai.github.io/tegnal/)**에서 해당 **소스 등록** 버튼을 누르세요. 소스를 추가한 뒤 TEGNAL을 선택해 설치하고, 이후 버전도 같은 소스에서 확인할 수 있습니다.

수동으로 등록할 때는 두 앱의 **Sources → +**에 아래 주소를 붙여 넣으세요.

```text
https://nextline-ai.github.io/tegnal/source.json
```

IPA는 **[GitHub Releases](https://github.com/nextline-ai/tegnal/releases/latest)**에서도 직접 받을 수 있습니다. AltStore Classic·SideStore 설치본은 사용자의 Apple 계정으로 다시 서명되며, 서명 갱신과 사용 가능한 iCloud 기능은 계정 및 설치 도구에 따라 달라집니다. 이 소스는 AltStore Classic용입니다.

## 시작하기

1. **이용할 사이트를 연결하세요.** 주소 입력 화면에서 사이트 주소를 지정합니다. 만화 모드는 입력한 도메인에서 데이터·이미지 서버를 찾아 저장하고, 이후에는 재사용합니다. 주소를 바꾸거나 연결이 실패했을 때 다시 탐색합니다.
2. **감상 방식을 고르세요.** 상단에서 만화·이미지 모드를 전환하고, 뷰어에서 읽기 방향과 넘김 방식을 설정하세요.
3. **컬렉션을 만드세요.** 작품을 길게 눌러 저장하고 폴더와 작가별로 정리하세요. 기존 백업은 보관함 관리에서 가져올 수 있습니다.

## 보관함은 이어지고, 백업은 한 파일로

**iCloud 동기화**를 켜면 북마크·폴더·작가·검색 기록 등 지원되는 보관함 데이터를 기기 사이에서 동기화합니다. 미디어 파일과 로그인 정보는 동기화하지 않습니다.

**설정 / 더보기 → 보관함 관리 → JSON 백업 내보내기**에서 만화·이미지 보관함과 챌린지 정의를 하나의 `tegnal-backup.json`으로 저장하세요. 어느 모드에서든 같은 파일로 복원할 수 있으며, 이전의 모드별 JSON 백업도 지원합니다. 미디어·캐시·로그인 정보는 백업에 포함되지 않습니다.

<details>
<summary><b>사이트 연결에 도움이 필요하다면</b></summary>

사이트가 클라이언트 확인을 요구하면 오류 화면 또는 서버 설정에서 **클라이언트 확인**을 완료하세요. 사이트에 따라 설정의 **내장 브라우저 사용**으로 연결할 수도 있습니다. 접속 가능 여부와 검색 제한은 이용하는 사이트의 정책에 따라 달라집니다.

</details>

<details>
<summary><b>소스 코드와 빌드</b></summary>

`native-ios/TEGNAL.xcodeproj`를 Xcode에서 열고 **TEGNAL** 스킴을 선택하세요. SwiftUI 기반이며 최소 지원 버전은 iOS 17입니다.

| 식별자 | 값 |
| :--- | :--- |
| 앱 | `work.nextline.tegnal` |
| 공유 확장 | `work.nextline.tegnal.share` |
| iCloud 컨테이너 | `iCloud.work.nextline.tegnal` |

실기기 빌드에는 해당 식별자와 일치하는 서명 설정이 필요합니다. 배포 파일과 소스 갱신 방법은 [배포 가이드](docs/distribution.md)를 참고하세요.

</details>

---

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/nextline-logo-dark.svg">
  <img src="docs/assets/nextline-logo-light.svg" alt="NextLine" width="140" align="right">
</picture>

**Made by NextLine**<br>
[Discord · 문의 및 제안](https://discord.gg/vUTGZNMaMB) &nbsp; / &nbsp; [nextline.work](https://nextline.work) &nbsp; / &nbsp; [Email](mailto:contact@nextline.work)

<sub>TEGNAL은 Apple 및 연결하는 외부 사이트와 무관한 독립 클라이언트입니다. 이용할 사이트는 사용자가 직접 지정합니다. <a href="docs/privacy-policy.md">개인정보처리방침</a></sub>
