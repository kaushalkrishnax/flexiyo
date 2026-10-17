#!/usr/bin/env node

// Builds release artifacts for a target platform and archives them to dist/.
//
//   node scripts/build-release.js --platform android   # per-ABI APKs
//   node scripts/build-release.js --platform ios       # IPA
//
// Version (name + code) comes from pubspec.yaml for both platforms, so bump it
// with `bun run bump:release` / `bun run bump:beta` first.

import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');

const platformArg = process.argv[2];
const platform = process.argv[3];

if (platformArg !== '--platform' || !['android', 'ios'].includes(platform)) {
  console.error('Usage: node scripts/build-release.js --platform <android|ios>');
  process.exit(1);
}

const flutter = process.platform === 'win32' ? 'flutter.bat' : 'flutter';

function run(args) {
  const result = spawnSync(flutter, args, {
    cwd: ROOT,
    env: process.env,
    stdio: 'inherit',
    shell: process.platform === 'win32',
  });

  if (result.error) {
    console.error(`Failed to start Flutter: ${result.error.message}`);
    process.exit(1);
  }
  if (result.status !== 0) {
    console.error(`Release build failed for ${platform}.`);
    process.exit(result.status ?? 1);
  }
}

function getCurrentVersion() {
  const pubspecPath = path.join(ROOT, 'pubspec.yaml');
  const pubspec = fs.readFileSync(pubspecPath, 'utf8');
  const match = pubspec.match(/^version:\s*(.+)$/m);
  if (!match) throw new Error('Could not find version in pubspec.yaml');
  return match[1].trim().split('+')[0];
}

if (platform === 'android') {
  const architectures = ['arm64-v8a', 'armeabi-v7a', 'x86_64'];
  const outputDir = path.join(ROOT, 'dist', 'release-apks');
  const apkOutputDirs = [
    path.join(ROOT, 'build', 'app', 'outputs', 'apk', 'release'),
    path.join(ROOT, 'build', 'app', 'outputs', 'flutter-apk'),
  ];

  const version = getCurrentVersion();
  // --split-per-abi emits per-ABI release APKs
  run([
    'build',
    'apk',
    '--release',
    '--split-per-abi',
    `--dart-define=APP_VERSION=${version}`,
  ]);

  fs.rmSync(outputDir, { recursive: true, force: true });
  fs.mkdirSync(outputDir, { recursive: true });

  const archivedApks = [];

  for (const abi of architectures) {
    const targetApkName = `Flexiyo-${version}-${abi}-RELEASE.apk`;
    const candidateNames = [
      targetApkName,
      `Flexiyo-${version}-${abi}-release.apk`,
      `Flexiyo-${version}-${abi}.apk`,
      `app-${abi}-release.apk`,
      `app-${abi}.apk`,
    ];

    let foundApk = null;
    for (const dir of apkOutputDirs) {
      if (!fs.existsSync(dir)) continue;
      for (const name of candidateNames) {
        const candidatePath = path.join(dir, name);
        if (fs.existsSync(candidatePath)) {
          foundApk = candidatePath;
          break;
        }
      }
      if (foundApk) break;

      const dirFiles = fs.readdirSync(dir);
      const matched = dirFiles.find(
        (f) =>
          f.endsWith('.apk') &&
          f.includes(abi) &&
          (f.includes('release') || f.startsWith('Flexiyo-')),
      );
      if (matched) {
        foundApk = path.join(dir, matched);
        break;
      }
    }

    if (!foundApk) {
      console.error(
        `Expected APK for ${abi} was not generated in output directories.`,
      );
      process.exit(1);
    }

    const archivedApk = path.join(outputDir, targetApkName);
    fs.copyFileSync(foundApk, archivedApk);
    archivedApks.push(path.relative(ROOT, archivedApk));
  }

  console.log('\nRelease APKs:');
  for (const archivedApk of archivedApks) {
    console.log(archivedApk);
  }
} else {
  const outputDir = path.join(ROOT, 'dist', 'release-ios');
  const ipaOutputDir = path.join(ROOT, 'build', 'ios', 'ipa');

  const version = getCurrentVersion();
  run(['build', 'ipa', '--release', `--dart-define=APP_VERSION=${version}`]);

  if (!fs.existsSync(ipaOutputDir)) {
    console.error(`Expected IPA output directory is missing: ${ipaOutputDir}`);
    process.exit(1);
  }

  fs.rmSync(outputDir, { recursive: true, force: true });
  fs.mkdirSync(outputDir, { recursive: true });

  const ipaFiles = fs
    .readdirSync(ipaOutputDir)
    .filter((name) => name.endsWith('.ipa'));

  if (ipaFiles.length === 0) {
    console.error(`No .ipa was generated in ${ipaOutputDir}`);
    process.exit(1);
  }

  const archivedIpas = [];
  for (const ipaFile of ipaFiles) {
    const builtIpa = path.join(ipaOutputDir, ipaFile);
    const archivedIpa = path.join(outputDir, ipaFile);
    fs.copyFileSync(builtIpa, archivedIpa);
    archivedIpas.push(path.relative(ROOT, archivedIpa));
  }

  console.log('\nRelease IPAs:');
  for (const archivedIpa of archivedIpas) {
    console.log(archivedIpa);
  }
}
