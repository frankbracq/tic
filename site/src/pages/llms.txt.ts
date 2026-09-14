import type { APIRoute } from 'astro';
import { site, release, features, shortcuts, faqs } from '../data/site';

// llms.txt (https://llmstxt.org): a Markdown summary of the page for LLMs, built from the same data.
export const GET: APIRoute = () => {
  const body = [
    `# ${site.name}`,
    '',
    `> ${site.summary}`,
    '',
    [release && `Latest version: ${release.version} (released ${release.date}).`, 'Free and open source under the MIT license.', `Made by ${site.author.name}.`]
      .filter(Boolean)
      .join(' '),
    '',
    '## Features',
    '',
    ...features.map((f) => `- **${f.title}**: ${f.body}`),
    '',
    '## Keyboard shortcuts',
    '',
    ...shortcuts.map((s) => `- ${s.keys.join(' ')}: ${s.action}`),
    '',
    '## Install',
    '',
    `1. Download the .dmg or .zip from the [latest release](${site.download}) and move Tic.app to Applications.`,
    '2. Tic isn’t notarized yet, so clear the quarantine flag once in Terminal: `xattr -rc /Applications/Tic.app`',
    '3. Open Tic and press ⌘N to make a list. Turn on Launch at Login from the menu bar icon.',
    '',
    ...(release ? [`## What’s new in ${release.version}`, '', ...release.notes.map((n) => `- ${n}`), ''] : []),
    '## FAQ',
    '',
    ...faqs.flatMap((f) => [`### ${f.q}`, '', f.a, '']),
    '## Links',
    '',
    `- [Website](${site.url}/): the Tic landing page`,
    `- [Download](${site.download}): latest release on GitHub`,
    `- [Source code](${site.repo}): Swift 6, SwiftUI + AppKit, SQLite via GRDB`,
    `- [Changelog](${site.changelog}): release history`,
  ].join('\n');

  return new Response(`${body}\n`, { headers: { 'Content-Type': 'text/plain; charset=utf-8' } });
};
