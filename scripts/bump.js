#!/usr/bin/env node

// Flutter version bumper with git tagging.
//
//   node scripts/bump.js --release   # 1.2.3 -> 1.2.4
//   node scripts/bump.js --beta      # 1.2.3 -> 1.2.4-beta.1 (or bump beta.N)
//
// pubspec.yaml `version: X.Y.Z+N` is the single source of truth:
//   - Flutter derives Android versionName/versionCode from it at build time.
//   - iOS MARKETING_VERSION / CURRENT_PROJECT_VERSION are kept in sync here.
//
// Two-phase like a release tool: with a dirty tree it only writes the version
// files (commit them, then re-run to push the tag); with a clean tree it tags.

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, '..');
const arg = process.argv[2];

function git(args, options = {}) {
  return execFileSync('git', args, { cwd: ROOT, encoding: 'utf8', ...options });
}

if (!arg || !['--release', '--beta'].includes(arg)) {
  console.error('Usage: node scripts/bump.js <release|beta>');
  process.exit(1);
}

const mode = arg.slice(2);

const PUBSPEC = path.join(ROOT, 'pubspec.yaml');
const PBXPROJ = path.join(ROOT, 'ios', 'Runner.xcodeproj', 'project.pbxproj');

function getCurrentVersion() {
  const pubspec = fs.readFileSync(PUBSPEC, 'utf8');
  const match = pubspec.match(/^version:\s*(.+)$/m);
  if (!match) throw new Error('Could not find version in pubspec.yaml');
  // "1.2.3+4" -> "1.2.3"; keep any pre-release suffix.
  return match[1].trim().split('+')[0];
}

// versionCode = major*10000 + minor*100 + patch (monotonic across releases).
function getVersionCode(version) {
  const [major, minor, patch] = version
    .replace(/-beta\.\d+$/, '')
    .split('.')
    .map(Number);
  return major * 10000 + minor * 100 + patch;
}

function setVersion(newVersion) {
  const versionCode = getVersionCode(newVersion);

  const pubspec = fs.readFileSync(PUBSPEC, 'utf8');
  fs.writeFileSync(
    PUBSPEC,
    pubspec.replace(/^version:\s*.+$/m, `version: ${newVersion}+${versionCode}`),
  );

  if (fs.existsSync(PBXPROJ)) {
    let pbx = fs.readFileSync(PBXPROJ, 'utf8');
    // Only the concrete per-config values, not the $(FLUTTER_*) build-setting refs.
    pbx = pbx.replace(/MARKETING_VERSION = [^;]+;/g, `MARKETING_VERSION = ${newVersion};`);
    pbx = pbx.replace(/CURRENT_PROJECT_VERSION = \d+;/g, `CURRENT_PROJECT_VERSION = ${versionCode};`);
    fs.writeFileSync(PBXPROJ, pbx);
  }

  console.log(`Updated version to ${newVersion}+${versionCode}`);
}

function bumpRelease(current) {
  const parts = current.replace(/-beta\.\d+$/, '').split('.').map(Number);
  parts[2] += 1;
  return parts.join('.');
}

function bumpBeta(current) {
  const betaMatch = current.match(/^(.+?)-beta\.(\d+)$/);
  if (betaMatch) {
    return `${betaMatch[1]}-beta.${parseInt(betaMatch[2], 10) + 1}`;
  }
  const parts = current.split('.').map(Number);
  parts[2] += 1;
  return `${parts.join('.')}-beta.1`;
}

function ensureTag(version) {
  const tag = `v${version}`;
  const remoteTag = git(['ls-remote', '--tags', 'origin', `refs/tags/${tag}`]).trim();
  if (remoteTag) {
    console.log(`Remote tag ${tag} already exists. Nothing to do.`);
    return;
  }

  let previousVersion;
  try {
    const prevPubspec = git(['show', 'HEAD^:pubspec.yaml']);
    const match = prevPubspec.match(/^version:\s*(.+)$/m);
    previousVersion = match ? match[1].trim().split('+')[0] : undefined;
  } catch {
    console.log('HEAD has no previous version to tag. Nothing to do.');
    return;
  }

  if (previousVersion === version) {
    console.log('HEAD did not bump the version. Nothing to tag.');
    return;
  }

  const head = git(['rev-parse', 'HEAD']).trim();
  let localTagCommit;
  try {
    localTagCommit = git(['rev-parse', '--verify', `refs/tags/${tag}^{commit}`]).trim();
  } catch {
    git(['tag', tag]);
  }

  if (localTagCommit && localTagCommit !== head) {
    throw new Error(`Local tag ${tag} points to a different commit; refusing to move it.`);
  }

  git(['push', 'origin', `refs/tags/${tag}`], { stdio: 'inherit' });
  console.log(`Tag ${tag} pushed.`);
}

const current = getCurrentVersion();
const uncommittedChanges = git([
  'status',
  '--porcelain',
  '--untracked-files=all',
]).trim();

if (uncommittedChanges) {
  const next = mode === 'release' ? bumpRelease(current) : bumpBeta(current);
  setVersion(next);
  console.log(
    `Commit the version changes manually, then run this command again to push tag v${next}.`,
  );
} else {
  try {
    ensureTag(current);
  } catch (error) {
    console.error(`Failed to push version tag: ${error.message}`);
    process.exitCode = 1;
  }
}
