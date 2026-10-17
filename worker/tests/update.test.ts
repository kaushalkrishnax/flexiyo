import { describe, expect, it } from 'vitest';
import {
  findMatchingApkAsset,
  getSeverity,
  isNewerVersion,
  parseChangelog,
} from '../src/routes/update.js';

describe('isNewerVersion', () => {
  it('detects a newer patch/minor/major version', () => {
    expect(isNewerVersion('1.2.1', '1.2.0')).toBe(true);
    expect(isNewerVersion('1.3.0', '1.2.9')).toBe(true);
    expect(isNewerVersion('2.0.0', '1.9.9')).toBe(true);
  });

  it('returns false for equal or older versions', () => {
    expect(isNewerVersion('1.2.0', '1.2.0')).toBe(false);
    expect(isNewerVersion('1.2.0', '1.2.1')).toBe(false);
    expect(isNewerVersion('0.9.0', '1.0.0')).toBe(false);
  });

  it('tolerates a leading v and build metadata', () => {
    expect(isNewerVersion('v1.3.0', '1.2.0')).toBe(true);
    expect(isNewerVersion('1.3.0+42', '1.2.0')).toBe(true);
    expect(isNewerVersion('1.2.0+42', '1.2.0')).toBe(false);
  });

  it('treats missing trailing segments as zero', () => {
    expect(isNewerVersion('1.2', '1.1.9')).toBe(true);
    expect(isNewerVersion('1.2.0', '1.2')).toBe(false);
  });

  it('orders prerelease versions before stable versions', () => {
    expect(isNewerVersion('1.0.2-beta.2', '1.0.2-beta.1')).toBe(true);
    expect(isNewerVersion('1.0.2', '1.0.2-beta.9')).toBe(true);
    expect(isNewerVersion('1.0.2-beta.1', '1.0.2')).toBe(false);
  });
});

describe('parseChangelog', () => {
  it('groups bullet items under bold section headings', () => {
    const body = [
      '**Features**',
      '* Added in-app updates',
      '* Dark mode polish',
      '**Fixes**',
      '* Crash on launch',
    ].join('\n');

    expect(parseChangelog(body)).toEqual({
      Features: ['Added in-app updates', 'Dark mode polish'],
      Fixes: ['Crash on launch'],
    });
  });

  it('ignores content outside of any section', () => {
    const body = ['Some preamble', '* not grouped', '**Notes**', '* real note'].join(
      '\n',
    );

    expect(parseChangelog(body)).toEqual({ Notes: ['real note'] });
  });

  it('returns an empty object for an empty body', () => {
    expect(parseChangelog('')).toEqual({});
  });
});

describe('getSeverity', () => {
  it('marks stable releases as high severity', () => {
    expect(getSeverity('1.2.3')).toBe('high');
    expect(getSeverity('10.0.0')).toBe('high');
  });

  it('marks pre-releases as low severity', () => {
    expect(getSeverity('1.2.3-beta.1')).toBe('low');
    expect(getSeverity('2.0.0-rc.2')).toBe('low');
    expect(getSeverity('1.2')).toBe('low');
  });
});

describe('findMatchingApkAsset', () => {
  const assets = [
    {
      name: 'Flexiyo-1.0.0-arm64-v8a-RELEASE.apk',
      browser_download_url: 'https://github.com/kaushalkrishnax/flexiyo/releases/download/v1.0.0/Flexiyo-1.0.0-arm64-v8a-RELEASE.apk',
      size: 15000000,
    },
    {
      name: 'Flexiyo-1.0.0-x86_64-RELEASE.apk',
      browser_download_url: 'https://github.com/kaushalkrishnax/flexiyo/releases/download/v1.0.0/Flexiyo-1.0.0-x86_64-RELEASE.apk',
      size: 16000000,
    },
    {
      name: 'app-armeabi-v7a-release.apk',
      browser_download_url: 'https://github.com/kaushalkrishnax/flexiyo/releases/download/v1.0.0/app-armeabi-v7a-release.apk',
      size: 14000000,
    },
  ];

  it('matches Flexiyo-<version>-<arch>-RELEASE.apk', () => {
    const match = findMatchingApkAsset(assets, 'arm64-v8a', '1.0.0');
    expect(match?.name).toBe('Flexiyo-1.0.0-arm64-v8a-RELEASE.apk');
    expect(match?.browser_download_url).toContain('Flexiyo-1.0.0-arm64-v8a-RELEASE.apk');
  });

  it('matches another architecture correctly', () => {
    const match = findMatchingApkAsset(assets, 'x86_64', '1.0.0');
    expect(match?.name).toBe('Flexiyo-1.0.0-x86_64-RELEASE.apk');
  });

  it('falls back to legacy app-<arch>-release.apk if named release apk not present', () => {
    const match = findMatchingApkAsset(assets, 'armeabi-v7a', '1.0.0');
    expect(match?.name).toBe('app-armeabi-v7a-release.apk');
  });

  it('defaults to arm64-v8a if arch is empty', () => {
    const match = findMatchingApkAsset(assets, '', '1.0.0');
    expect(match?.name).toBe('Flexiyo-1.0.0-arm64-v8a-RELEASE.apk');
  });
});

