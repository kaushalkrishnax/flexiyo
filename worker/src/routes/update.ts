import { IRequest, Router } from 'itty-router';
import type { Env } from '../types.js';
import { rateLimitMiddleware } from '../middleware/rateLimit.js';

export const updateRouter = Router({ base: '/api/update' });

// GitHub repository that publishes Flexiyo release APKs (override via UPDATE_GITHUB_REPO).
const DEFAULT_UPDATE_REPO = 'kaushalkrishnax/flexiyo';

// Maps an Android ABI to its legacy release APK asset name; maintained for backward compatibility.
export const ARCH_APK_MAP: Record<string, string> = {
  'arm64-v8a': 'app-arm64-v8a-release.apk',
  'armeabi-v7a': 'app-armeabi-v7a-release.apk',
  x86: 'app-x86-release.apk',
  x86_64: 'app-x86_64-release.apk',
};

export interface ReleaseAsset {
  name: string;
  browser_download_url: string;
  size: number;
  digest?: string | null;
  download_count?: number;
  created_at?: string | null;
}

export function findMatchingApkAsset(
  assets: ReleaseAsset[],
  arch: string,
  version?: string,
): ReleaseAsset | undefined {
  const targetArch = arch || 'arm64-v8a';
  const expectedUpperName = version
    ? `Flexiyo-${version}-${targetArch}-RELEASE.apk`
    : `Flexiyo-${targetArch}-RELEASE.apk`;
  const expectedLowerName = version
    ? `Flexiyo-${version}-${targetArch}-release.apk`
    : `Flexiyo-${targetArch}-release.apk`;
  const expectedShortName = version
    ? `Flexiyo-${version}-${targetArch}.apk`
    : `Flexiyo-${targetArch}.apk`;
  const legacyName = ARCH_APK_MAP[targetArch] ?? `app-${targetArch}-release.apk`;

  return (
    assets.find(
      (a) =>
        a.name === expectedUpperName ||
        a.name === expectedLowerName ||
        a.name.toLowerCase() === expectedUpperName.toLowerCase() ||
        a.name === expectedShortName ||
        a.name === legacyName ||
        (a.name.endsWith('.apk') && a.name.includes(targetArch) && a.name.startsWith('Flexiyo-')),
    ) ??
    assets.find((a) => a.name.endsWith('.apk') && a.name.includes(targetArch)) ??
    assets.find((a) => a.name === legacyName) ??
    assets.find((a) => a.name.endsWith('.apk'))
  );
}

/// True when `latest` is strictly newer than `current`, including prerelease
/// precedence (`beta.2` > `beta.1` and stable > any prerelease).
export function isNewerVersion(latest: string, current: string): boolean {
  const parse = (version: string) => {
    const [withoutBuild, build] = version.trim().replace(/^v/i, '').split('+', 2);
    const [core, prerelease] = withoutBuild.split('-', 2);
    const coreParts = core.split('.').map((part) => Number.parseInt(part, 10));
    return {
      core: [coreParts[0] || 0, coreParts[1] || 0, coreParts[2] || 0],
      prerelease: prerelease?.split('.') ?? [],
      build,
    };
  };

  const l = parse(latest);
  const c = parse(current);
  for (let i = 0; i < l.core.length; i++) {
    if (l.core[i] > c.core[i]) return true;
    if (l.core[i] < c.core[i]) return false;
  }

  if (l.prerelease.length === 0 || c.prerelease.length === 0) {
    return l.prerelease.length === 0 && c.prerelease.length > 0;
  }

  const length = Math.max(l.prerelease.length, c.prerelease.length);
  for (let i = 0; i < length; i++) {
    if (i >= l.prerelease.length) return false;
    if (i >= c.prerelease.length) return true;
    const left = l.prerelease[i];
    const right = c.prerelease[i];
    if (left === right) continue;
    const leftNumber = /^\d+$/.test(left) ? Number(left) : null;
    const rightNumber = /^\d+$/.test(right) ? Number(right) : null;
    if (leftNumber != null && rightNumber != null) {
      return leftNumber > rightNumber;
    }
    if (leftNumber != null) return true;
    if (rightNumber != null) return false;
    return left > right;
  }
  return false;
}

/// Parses a release body into `{ section: [items] }` from bold headings and `*` bullets.
export function parseChangelog(body: string): Record<string, string[]> {
  const sections: Record<string, string[]> = {};
  let currentSection = '';

  for (const line of body.split('\n')) {
    const heading = line.match(/^\*\*(.+)\*\*$/);
    if (heading) {
      currentSection = heading[1].trim();
      sections[currentSection] = [];
    } else if (currentSection && line.trim().startsWith('*')) {
      sections[currentSection].push(line.replace(/^\*\s*/, '').trim());
    }
  }

  return sections;
}

function formatBytes(bytes: number): string {
  const mb = bytes / (1024 * 1024);
  return `${mb.toFixed(1)} MB`;
}

/// Stable releases (X.Y.Z) are 'high' severity; pre-releases (beta/rc) 'low'.
export function getSeverity(version: string): 'high' | 'low' {
  return /^\d+\.\d+\.\d+$/.test(version) ? 'high' : 'low';
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

updateRouter.post(
  '/check',
  // @ts-ignore — itty-router middleware arity differs from the plain Request signature.
  rateLimitMiddleware({ limit: 30, windowMs: 60_000 }),
  // @ts-ignore
  async (request: IRequest, env: Env, _ctx: ExecutionContext): Promise<Response> => {
    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return json({ error: 'Invalid JSON body' }, 400);
    }

    // `platform` is accepted for forward-compatibility; APK selection is by ABI.
    const { version, arch } = (body ?? {}) as {
      version?: unknown;
      arch?: unknown;
      platform?: unknown;
    };

    if (typeof version !== 'string' || version.trim().length === 0) {
      return json({ error: 'Version required' }, 400);
    }

    const repo = (env.UPDATE_GITHUB_REPO || DEFAULT_UPDATE_REPO).trim();
    if (!repo) {
      return json({ error: 'Update repository not configured' }, 500);
    }

    try {
      const res = await fetch(
        `https://api.github.com/repos/${repo}/releases?per_page=30`,
        {
        headers: {
          Accept: 'application/vnd.github+json',
          'User-Agent': 'Flexiyo App',
          ...(env.GITHUB_TOKEN
            ? { Authorization: `Bearer ${env.GITHUB_TOKEN}` }
            : {}),
        },
        },
      );

      if (!res.ok) {
        console.error('GitHub API failed:', res.status, await res.text());
        return json({ error: 'GitHub API failed' }, 502);
      }

      const data = (await res.json()) as Array<{
        tag_name?: string;
        name?: string | null;
        published_at?: string | null;
        html_url?: string | null;
        body?: string | null;
        draft?: boolean;
        assets?: ReleaseAsset[];
      }>;
      const releases = data
        .filter((release) => !release.draft && release.tag_name && release.assets)
        .sort((a, b) =>
          String(b.published_at ?? '').localeCompare(String(a.published_at ?? '')),
        );
      if (releases.length === 0) {
        return json({ error: 'No published releases found' }, 404);
      }

      const archKey = typeof arch === 'string' ? arch : '';
      const selected = releases
        .map((release) => {
          const latestVersion = release.tag_name!.replace(/^v/i, '');
          return {
            release,
            latestVersion,
            apk: findMatchingApkAsset(release.assets!, archKey, latestVersion),
          };
        })
        .find((candidate) => candidate.apk);
      if (!selected || !selected.apk) {
        return json({ error: `No APK found for arch: ${archKey || 'unknown'}` }, 404);
      }

      const { release, latestVersion } = selected;
      const apk: ReleaseAsset = selected.apk as ReleaseAsset;

      const releaseInfo = {
        version: latestVersion,
        latestVersion,
        name: release.name ?? null,
        publishedAt: release.published_at ?? null,
        releaseUrl: release.html_url ?? null,
        changelog: parseChangelog(String(release.body ?? '')),
        severity: getSeverity(latestVersion),
        apkUrl: apk.browser_download_url,
        apk: {
          url: apk.browser_download_url,
          name: apk.name,
          size: apk.size,
          sizeFormatted: formatBytes(apk.size),
          digest: apk.digest ?? null,
          downloadCount: apk.download_count ?? 0,
          createdAt: apk.created_at ?? null,
        },
      };

      return json({
        updateAvailable: isNewerVersion(latestVersion, version),
        ...releaseInfo,
      });
    } catch (e) {
      console.error('Update check failed:', e);
      return json({ error: 'Update check failed' }, 500);
    }
  },
);
