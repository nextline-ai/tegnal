<p align="right"><a href="README.md">한국어</a> &nbsp; / &nbsp; <b>English</b></p>

<p align="center">
  <a href="https://testflight.apple.com/join/gnkqu44W">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="docs/assets/tegnal-hero-dark.svg">
      <img src="docs/assets/tegnal-hero-light.svg" alt="TEGNAL — Comics. Images. Your collection." width="100%">
    </picture>
  </a>
</p>

<p align="center"><b>A place for what you read. A home for what you love.</b><br>
A native iOS app for discovering comics and illustrations, enjoying them, and building your own collection.</p>

<p align="center"><sub>1.0.0 (7) &nbsp; · &nbsp; iOS 17+ &nbsp; · &nbsp; iPhone & iPad &nbsp; · &nbsp; 한국어 / English / 日本語</sub></p>

<p align="center"><a href="https://testflight.apple.com/join/gnkqu44W"><img src="docs/assets/button-testflight.svg" alt="Install with TestFlight" width="220" height="67"></a><br><sub>Recommended installation · TestFlight</sub></p>

<details>
<summary>Other installation options · AltStore Classic / SideStore / IPA</summary>

<p align="center">
  <a href="https://nextline-ai.github.io/tegnal/?lang=en#altstore"><img src="docs/assets/button-altstore.svg" alt="AltStore Classic" width="160"></a>
  <a href="https://nextline-ai.github.io/tegnal/?lang=en#sidestore"><img src="docs/assets/button-sidestore.svg" alt="SideStore" width="160"></a>
  <a href="https://github.com/nextline-ai/tegnal/releases/latest"><img src="docs/assets/button-ipa.svg" alt="Download IPA" width="160"></a>
</p>

</details>

<p align="center"><a href="#installation">Installation</a> &nbsp; · &nbsp; <a href="#two-ways-to-browse-one-place-to-keep-them">Explore the app</a> &nbsp; · &nbsp; <a href="https://github.com/nextline-ai/tegnal/releases">Release notes</a> &nbsp; · &nbsp; <a href="https://discord.gg/vUTGZNMaMB">Community</a></p>

---

## Two ways to browse. One place to keep them.

**Read at your own pace. Browse by your own taste.** Switch between comics and images from the top bar, then long-press a work to keep it in your collection.

| | Comics | Images |
| :--- | :--- | :--- |
| **Discover** | Gallery search, popular works, artist collections | Danbooru, Gelbooru and Moebooru servers; tag search and multiple sources |
| **Enjoy** | Reading direction, paged and continuous layouts, image translation | High-resolution images, GIFs and videos, pools, notes, image translation |
| **Collect** | Bookmarks, artists and folders | Saved works, folder colors and similar-image search |
| **Import** | `user.db` / `data.db` from other manga viewers | Anime Boxes `.abbj` files |

### Thoughtful details, page after page

- **The next page gets a head start.** The comic reader preloads nearby pages and reuses its cache. Turning a page preserves downloads already in progress.
- **Your taste stays on your device.** Saved works and tags inform recommendations and recaps; Apple Vision helps find visually similar images.
- **Read text inside images.** Use Apple's text recognition and translation on supported devices and OS versions.
- **Turn inspiration into practice.** Challenge Roulette combines reference images, sketch timers and custom missions.

## Installation

### TestFlight · Recommended

Install [Apple TestFlight](https://apps.apple.com/app/testflight/id899247664), then **[join the TEGNAL beta](https://testflight.apple.com/join/gnkqu44W)**. The current public beta is **1.0.0 (7)**. TestFlight is the recommended way to install TEGNAL and receive updates.

<details>
<summary><b>Other installation options · AltStore Classic / SideStore / IPA</b></summary>

With AltStore Classic or SideStore installed, open the **[download page](https://nextline-ai.github.io/tegnal/?lang=en)** and tap the corresponding **Add source** button. Add the source, select TEGNAL, and find future releases in the same place.

To add it manually, paste this address into **Sources → +** in either app:

```text
https://nextline-ai.github.io/tegnal/source.json
```

You can also download the IPA directly from **[GitHub Releases](https://github.com/nextline-ai/tegnal/releases/latest)**. AltStore Classic and SideStore re-sign it with your Apple account; signing renewal and available iCloud capabilities depend on your account and installation tool. This source is intended for AltStore Classic.

</details>

## Make it yours

1. **Connect your sites.** Enter the website address you want to use. Comics Mode discovers data and image servers from your chosen domain, saves them, and reuses them across launches. Discovery runs again when the address changes or a connection fails.
2. **Choose how to read.** Switch between comics and images at the top, then set your reading direction and page layout in the viewer.
3. **Build your collection.** Long-press to save a work, organize folders, and keep track of artists. Import existing backups through Library Management.

## A library that travels. A backup in one file.

Enable **iCloud sync** to keep supported library data, including bookmarks, folders, artists and search history, across your devices. Media files and sign-in details remain local.

Open **Settings / More → Library Management → Export JSON Backup** to save both libraries and challenge definitions in one `tegnal-backup.json` file. Restore it from either mode; older separate JSON backups are also supported. Media, caches and sign-in details are excluded.

<details>
<summary><b>Need help connecting a site?</b></summary>

If a site asks for client verification, complete **Validate Client** from its error screen or server settings. Depending on the site, **Use Embedded Browser** may provide another way to connect. Availability and search limits depend on the connected site's policies.

</details>

<details>
<summary><b>Source code and builds</b></summary>

Open `native-ios/TEGNAL.xcodeproj` in Xcode and select the **TEGNAL** scheme. The app uses SwiftUI and targets iOS 17 or later.

| Identifier | Value |
| :--- | :--- |
| App | `work.nextline.tegnal` |
| Share extension | `work.nextline.tegnal.share` |
| iCloud container | `iCloud.work.nextline.tegnal` |

Device builds need matching signing configuration. See the [distribution guide](docs/distribution.md) for release packaging and source updates.

</details>

---

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/nextline-logo-dark.svg">
  <img src="docs/assets/nextline-logo-light.svg" alt="NextLine" width="140" align="right">
</picture>

**Made by NextLine**<br>
[Discord · Feedback & support](https://discord.gg/vUTGZNMaMB) &nbsp; / &nbsp; [nextline.work](https://nextline.work) &nbsp; / &nbsp; [Email](mailto:contact@nextline.work)

<sub>TEGNAL is an independent client, unaffiliated with Apple or any connected website. You choose the sites you connect to. <a href="docs/privacy-policy.md">Privacy policy</a></sub>
