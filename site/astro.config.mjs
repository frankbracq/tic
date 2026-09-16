// @ts-check
import { defineConfig, fontProviders } from 'astro/config';
import tailwindcss from '@tailwindcss/vite';
import sitemap from '@astrojs/sitemap';

export default defineConfig({
  site: 'https://tic.kasvith.me',
  trailingSlash: 'ignore',
  vite: { plugins: [tailwindcss()] },
  // /og/ only exists to render public/og.png.
  integrations: [sitemap({ filter: (page) => !page.includes('/og/') })],
  fonts: [
    { provider: fontProviders.fontsource(), name: 'Bricolage Grotesque', cssVariable: '--font-bricolage', weights: [500, 700, 800], styles: ['normal'], subsets: ['latin'] },
  ],
});
