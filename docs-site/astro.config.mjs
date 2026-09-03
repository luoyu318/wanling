import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  base: '/docs',
  integrations: [
    starlight({
      title: '万灵小程序',
      description: '万灵小程序开发文档：包格式、JSBridge、权限、发布全流程',
      logo: { src: './src/assets/logo.png' },
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/luoyu318/wanling' },
      ],
      locales: { root: { label: '简体中文', lang: 'zh-CN' } },
      defaultLocale: 'root',
      head: [
        {
          tag: 'link',
          attrs: { rel: 'icon', href: '/docs/favicon.png' },
        },
      ],
      sidebar: [
        {
          label: '入门',
          items: ['', 'quickstart'],
        },
        {
          label: '指南',
          items: [
            'guides/manifest',
            'guides/navigation',
            'guides/permissions',
            'guides/identity',
            'guides/storage',
            'guides/debugging',
            'guides/publishing',
          ],
        },
        {
          label: 'API 参考',
          items: ['api/bridge', 'api/limits'],
        },
        {
          label: '示例',
          items: ['examples'],
        },
      ],
      customCss: ['./src/styles/custom.css'],
    }),
  ],
});
