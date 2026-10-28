// Rasterize the native outlined SVG badges at 3x, without changing their source.
// Usage: node tool/generate_community_buttons.cjs [path-to-installed-sharp]
const fs = require('node:fs/promises');
const path = require('node:path');
const sharp = require(process.argv[2] || 'sharp');
const root = path.resolve(__dirname, '../..');
(async () => {
  for (const service of ['Discord', 'GitHub']) {
    for (const [nativeLanguage, language] of [['kr', 'ko'], ['en', 'en']]) {
      const source = path.join(root, `native-ios/TEGNAL/Assets.xcassets/Developer${service}_${nativeLanguage}.imageset/${service}_button_${nativeLanguage}.svg`);
      const target = path.join(root, `flutter/assets/branding/developer-${service.toLowerCase()}-${language}.png`);
      const svg = await fs.readFile(source);
      await sharp(svg, { density: 216 }).resize({ width: 1200 }).png().toFile(target);
      const result = await sharp(target).metadata();
      if (result.width !== 1200 || !result.hasAlpha) throw new Error('Invalid badge output');
      process.stdout.write(`${path.basename(target)}: ${result.width}×${result.height}\n`);
    }
  }
})().catch(error => { process.stderr.write(`${error.message}\n`); process.exitCode = 1; });
