import type { Task } from '../components/Note.astro';

// Latest release, parsed from the git-cliff CHANGELOG.md on GitHub at build time. A failed fetch
// just hides the version and "What's new" rather than breaking the build.
async function latestRelease() {
  try {
    const res = await fetch('https://raw.githubusercontent.com/kasvith/tic/main/CHANGELOG.md');
    if (!res.ok) return undefined;
    const block = (await res.text()).split(/^## /m).find((b) => b.startsWith('['));
    const head = block?.match(/^\[(\d+\.\d+\.\d+)\] - (\d{4}-\d{2}-\d{2})/);
    if (!block || !head) return undefined;
    const notes = [...block.matchAll(/^- (.+)$/gm)].map((m) => m[1].replace(/^\*\(.+?\)\* /, ''));
    return { version: head[1], date: head[2], notes };
  } catch {
    return undefined;
  }
}

export const release = await latestRelease();

export const site = {
  name: 'Tic',
  url: 'https://tic.kasvith.me',
  title: 'Tic: Sticky-note to-do lists for your Mac desktop',
  description:
    'Tic is a free, open-source Mac app that keeps your to-do lists on the desktop as floating sticky notes, with subtasks, Markdown and keyboard shortcuts.',
  summary:
    'Tic is a free, open-source macOS app that keeps to-do lists on the desktop as floating, Stickies-style sticky notes instead of hiding them behind a menu bar. Each list is its own small window with subtasks, inline Markdown, solid or glass styles and keyboard shortcuts. It needs macOS 14 Sonoma or later.',
  keywords: ['to-do list', 'sticky notes', 'Stickies alternative', 'desktop checklist', 'task manager', 'macOS', 'open source'],
  repo: 'https://github.com/kasvith/tic',
  download: 'https://github.com/kasvith/tic/releases/latest',
  changelog: 'https://github.com/kasvith/tic/blob/main/CHANGELOG.md',
  productHunt: 'https://www.producthunt.com/products/tic?utm_source=badge-follow&utm_medium=badge&utm_source=badge-tic',
  author: { name: 'Kasun Vithanage', url: 'https://kasvith.me', github: 'https://github.com/kasvith' },
};

// The app's own welcome note (AppDatabase.seedSampleDataIfEmpty), rendered as HTML.
export const welcomeTasks: Task[] = [
  { t: 'Tap the circle to finish a task' },
  { t: 'Break big tasks into subtasks' },
  { t: 'Hover a row and click the + below it', l: 1 },
  { t: '…or press Shift-Tab while editing', l: 1 },
  { t: '<em>Markdown</em> — <strong>bold</strong>, <code>code</code>, <s>strike</s>, <a href="https://kasvith.me">links</a>' },
  { t: 'Need detail? Press Shift-Return\nfor a new line in the same task' },
  { t: 'Completing a parent completes its subtasks', done: true },
  { t: 'buy milk', l: 1, done: true },
  { t: 'water the plants', l: 1, done: true },
];

export const shipTasks: Task[] = [
  { t: 'Write release notes', done: true },
  { t: 'Record the demo' },
  { t: 'Trim the intro', l: 1, done: true },
  { t: 'Export at <strong>1080p</strong>', l: 1 },
  { t: 'Tag <code>v0.4.0</code>', editing: true, hint: ['⇧⇥', 'nest'] },
];

export const groceryTasks: Task[] = [
  { t: 'Oat milk' },
  { t: 'Sourdough', done: true },
  { t: 'Coffee beans' },
  { t: 'Lemons ×3' },
];

export const weekTasks: Task[] = [
  { t: 'Dentist, <strong>Thu 3pm</strong>' },
  { t: 'Call mum', done: true },
  { t: 'Book flights to Kandy' },
];

export const features = [
  {
    id: 'float',
    title: 'Lists that stay where you put them',
    body: 'Each list is its own small window on the desktop. Keep it above everything, show it on every Space, or double-click the title to roll it up. Tic remembers where every note sits.',
  },
  {
    id: 'subtasks',
    title: 'Subtasks, notes and Markdown',
    body: 'Nest tasks three levels deep. Finish every subtask and the parent ticks itself off. Add a second line with Shift-Return, and write bold, italic, code, strikethrough or links right in the task.',
  },
  {
    id: 'look',
    title: 'Six paper colours, or glass',
    body: 'Give each list its own colour, or switch it to glass so your wallpaper shows through. On macOS 26 glass notes pick up Liquid Glass automatically.',
  },
  {
    id: 'search',
    title: 'Find any list in a keystroke',
    body: 'Open Search Lists from the menu bar to jump to any list. Type to filter, use the arrow keys to move and Return to open it.',
  },
  {
    id: 'tidy',
    title: 'Finished tasks, handled your way',
    body: 'Per list, hide completed tasks, sink them to the bottom, or clear them all out when the list gets long.',
  },
  {
    id: 'private',
    title: 'Private by default',
    body: 'Your lists live in a SQLite file on your Mac. There’s no account, no server and no tracking.',
  },
];

export const shortcuts: { keys: string[]; action: string }[] = [
  { keys: ['⌘', 'N'], action: 'New list' },
  { keys: ['Return'], action: 'Save the task you’re typing' },
  { keys: ['⇧', 'Return'], action: 'New line inside a task' },
  { keys: ['⇧', 'Tab'], action: 'Nest a task under the one above' },
  { keys: ['⌃', '⇧', 'Tab'], action: 'Move a subtask back out' },
  { keys: ['↑', '↓'], action: 'Move through search results' },
];

export const faqs = [
  {
    q: 'Is Tic free?',
    a: 'Yes. Tic is free and open source under the MIT license. The code is on GitHub.',
  },
  {
    q: 'Which version of macOS do I need?',
    a: 'macOS 14 Sonoma or later. Glass notes use Liquid Glass automatically on macOS 26.',
  },
  {
    q: 'macOS says Tic can’t be opened. What do I do?',
    a: 'Tic isn’t notarized by Apple yet, so Gatekeeper blocks the first launch. Move Tic.app to Applications and run xattr -rc /Applications/Tic.app in Terminal, or right-click the app, choose Open, then Open again.',
  },
  {
    q: 'Where are my lists stored?',
    a: 'In a local SQLite database at ~/Library/Application Support/Tic/tic.sqlite. Nothing leaves your Mac.',
  },
  {
    q: 'Does Tic sync between Macs?',
    a: 'Not yet. Tic keeps everything local on one Mac for now.',
  },
  {
    q: 'Can Tic open when I log in?',
    a: 'Yes. Turn on Launch at Login from the Tic menu in the menu bar.',
  },
];
