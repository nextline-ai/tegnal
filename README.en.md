<p align="right"><a href="README.md">한국어</a></p>

<p align="center">
  <a href="https://testflight.apple.com/join/gnkqu44W">
    <img src="design-output/JPG/main_banner_en.jpg" alt="Download TEGNAL on TestFlight" width="100%">
  </a>
</p>

<h1 align="center">TEGNAL</h1>
<p align="center"><b>The first dedicated iOS viewer supporting both Hitomi and Danbooru in one place</b></p>
<p align="center">
  Download easily and safely via <b>Apple’s official TestFlight</b>—no risky sideloading required.<br>
  Enjoy on-device AI recommendations, instant translation, and secure iCloud sync across your Apple devices.
</p>

<p align="center">
  <a href="https://testflight.apple.com/join/gnkqu44W"><b>📲 Download Free on TestFlight</b></a> ·
  <a href="https://github.com/nextline-ai/tegnal/releases">Release Notes</a> ·
  <a href="https://discord.gg/vUTGZNMaMB">Discord Community</a>
</p>

---

## ✨ Why TEGNAL?

### 1. Hitomi & Danbooru in One Place (First All-in-One iOS Viewer)
- Supports both **Comics Mode (Hitomi, etc.)** and **Image Mode (Danbooru, Gelbooru, Moebooru, etc.)** in a single native iOS app.
- Seamlessly switch between reading comics and browsing illustration boards with the top mode bar.
- Browse multiple Booru servers simultaneously and long-press any work to organize it into custom color-coded folders.

### 2. Easy & Safe Installation via Official TestFlight (No Sideloading)
- TEGNAL uses **Public TestFlight as its official release channel**.
- Forget complicated, risky sideloading tools, PC tethering, or 7-day certificate expirations.
- Install with a single tap through Apple’s official TestFlight app and receive automatic updates safely.

### 3. Seamless Apple Continuity & Top-Tier iCloud Security
- **Cross-Platform Continuity (iPhone · iPad · macOS · visionOS):** Enjoy seamless continuity across all officially supported Apple platforms, featuring dedicated UI and controls optimized for each environment.
- **Secure iCloud Sync:** Your bookmarks, folders, saved artists, and search history are protected by Apple’s industry-leading iCloud security and synced automatically across your devices.

### 4. Private, 100% On-Device AI Features
Every AI feature runs **100% locally on your device** without sending your data to external servers—keeping your preferences completely private.
- **Smart Recommendations & Monthly Recaps:** Analyzes your saved works and tags on-device to recommend fresh content daily, complete with weekly stats and monthly recap cards.
- **Find Similar Art Styles:** Long-press a saved work to find visually similar pieces based on composition, color palette, and art style powered by Apple Vision.
- **One-Tap Image Translation:** Instantly recognize and translate text inside comics and illustrations using Apple’s on-device translation engine.

---

## 📲 How to Install

1. Install **[Apple TestFlight](https://apps.apple.com/app/testflight/id899247664)** from the App Store.
2. Tap the link below (or the banner at the top) to open the **TEGNAL TestFlight** page and tap **Install**.
   - 👉 **[Join TEGNAL on TestFlight](https://testflight.apple.com/join/gnkqu44W)**
3. **Supported Platforms:** iPhone, iPad, macOS, visionOS (UI optimized for each environment · Supports English, Korean, and Japanese)

<details>
<summary><b>What is TestFlight?</b></summary>

TestFlight is Apple’s service for distributing beta versions of apps.

**Apple’s official TestFlight is the recommended installation method for a safe, trustworthy distribution experience.**

- **Distribution managed by Apple:** Install developer-provided builds directly through TestFlight. Public distribution to external testers is subject to Apple’s beta review process. [Apple’s official guide](https://developer.apple.com/testflight/)
- **No manual certificate management:** There is no need to obtain and re-sign an IPA file or manually install separate certificates and device management profiles.
- **A consistent installation and update channel:** Enable automatic updates in TestFlight to receive new builds through the same official channel. [TestFlight installation and updates](https://testflight.apple.com/)

</details>

**The latest app versions are distributed through TestFlight first.** Use TestFlight to receive the latest version.

IPA files and builds for AltStore Classic and SideStore are uploaded only for selected versions, so they may lag behind TestFlight. **Source code is always updated on GitHub first.**

<details>
<summary><b>Other installation methods (optional)</b></summary>

If you already have AltStore Classic or SideStore installed, use the links below to add the TEGNAL source.

| Method | Download and install |
| --- | --- |
| AltStore Classic | [Add source](https://nextline-ai.github.io/tegnal/?lang=en#altstore) |
| SideStore | [Add source](https://nextline-ai.github.io/tegnal/?lang=en#sidestore) |
| Manual IPA installation | [Read the update limitations before downloading](https://nextline-ai.github.io/tegnal/manual-install.html?lang=en) |

To add the source manually, paste this address into **Sources → +** in AltStore Classic or SideStore:

```text
https://nextline-ai.github.io/tegnal/source.json
```

The IPA must be re-signed with your Apple account using your installation tool. Signing renewal and available iCloud capabilities depend on your account and installer.

</details>

---

## 🚀 Quick Start Guide

1. **Connect Your Sites:** Tap **Enter Website Address** and type the URL of the site you want to use (e.g., Hitomi, Danbooru, Gelbooru). Pick from the autocomplete suggestions to connect right away. The app discovers and saves data and image server addresses from your chosen domain, then reuses them across launches. It discovers them again only when you change the website address or a server connection fails.
2. **Switch Modes:** Use the **Book / Image switch** at the top of the screen to move between Comics Mode and Image Mode anytime.
3. **Save Favorites:** **Long-press** any work in Explore or the viewer to save it immediately, and organize your collection into custom folders.
4. **Import Existing Backups:** Easily bring your existing collection from **Violet** (`user.db` / `data.db`) or **Anime Boxes** (`.abbj`) in Settings.

| Feature | 📖 Comics Mode | 🖼️ Image Mode (Booru) |
| --- | --- | --- |
| **Browse** | Gallery search, popular feeds, artist collections | Multi-server search, latest/popular feeds, tag autocomplete |
| **Viewer** | Configurable reading direction, continuous scroll, translation | High-res images, GIFs/videos, pools, notes, translation |
| **Backup & Import** | Other manga viewer import & unified JSON backup | Anime Boxes import & unified JSON backup |

**Unified JSON backup:** In either mode, open **Settings / More → Library Management → Export JSON Backup** to save both libraries and challenge definitions in one `tegnal-backup.json` file. Restore both modes from the same screen; older separate backups remain supported. Media, caches, and sign-in details are excluded. Restored library data also syncs across devices when iCloud is enabled.

> 💡 **Bonus Feature — Challenge Roulette**
> Head to **More → Challenge Roulette** in Image Mode to practice timed croquis sketching or create your own custom roulette missions with reference images!

---

## 🛠️ Troubleshooting Connection Issues

- **Validate Client (Cloudflare, etc.):** If a site blocks automated requests, tap **Validate Client** on the error screen or in Server Settings to complete verification.
- **Built-in Browser Mode:** If a site’s API is temporarily unavailable, turn on **Use Embedded Browser** in Settings for uninterrupted browsing.
- **Danbooru Tag Limit:** Free Danbooru accounts are limited by the site to 2 tags per search. (Gelbooru and other servers do not have this limit.)

---

## 🛠️ Development

Native iOS sources live in `native-ios/TEGNAL`. Open `native-ios/TEGNAL.xcodeproj` and select the **TEGNAL** scheme. The minimum deployment target is iOS 17.

- **App bundle ID:** `work.nextline.tegnal`
- **Share extension ID:** `work.nextline.tegnal.share`
- **iCloud container:** `iCloud.work.nextline.tegnal`

Device signing and distribution require matching Apple Developer configuration and provisioning profiles. These identifiers create a separate app from existing installations. Image-library and challenge JSON backups from earlier versions can still be imported.

---

## 💬 Developer & Community

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/assets/nextline-logo-dark.svg">
  <img src="docs/assets/nextline-logo-light.svg" alt="NextLine" width="160" align="right">
</picture>

Have questions, feedback, or bug reports? Join our **Discord community** anytime!

- **Developer:** NextLine
- **Community / Bug Reports:** [Join Discord](https://discord.gg/vUTGZNMaMB)
- **Website:** [nextline.work](https://nextline.work)
- **Email:** [contact@nextline.work](mailto:contact@nextline.work)

---

<sub>TEGNAL is an independent client application and is not affiliated with Apple or any user-connected websites.<br>
<a href="docs/privacy-policy.md">Privacy Policy</a></sub>
