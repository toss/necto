//
//  Copyright (c) 2026 Viva Republica, Inc.
//

import { defineConfig } from "vitepress";
import { docsLicensePlugin } from "../../script/licenses.mjs";

const repo = "https://github.com/toss/toss-necto";

function sidebar(prefix: string, labels: Record<string, string>) {
  const link = (page: string) => `${prefix}/${page}`;
  return [
    {
      text: labels.start,
      items: [
        { text: labels.setup, link: link("setup") },
        { text: labels.install, link: link("install") },
      ],
    },
    {
      text: labels.tutorial,
      items: [
        { text: labels.tutorialDesktop, link: link("tutorial-desktop") },
        { text: labels.tutorialDevice, link: link("tutorial-device") },
        { text: labels.publishing, link: link("publishing") },
      ],
    },
    {
      text: labels.pluginStructure,
      items: [
        { text: labels.manifest, link: link("plugin-manifest") },
        { text: labels.bridges, link: link("bridges") },
        { text: labels.design, link: link("design") },
      ],
    },
    {
      text: labels.libraryStructure,
      items: [
        { text: labels.architecture, link: link("architecture") },
        { text: labels.harness, link: link("harness") },
        { text: labels.controlSocket, link: link("control-socket") },
        { text: labels.verification, link: link("verification") },
      ],
    },
  ];
}

const en = sidebar("", {
  start: "Start",
  setup: "Connect Necto to your app",
  install: "Install the Necto app",
  tutorial: "Adding a plugin",
  tutorialDesktop: "Part 1 — A desktop plugin",
  tutorialDevice: "Part 2 — A device plugin",
  publishing: "Publishing a plugin",
  pluginStructure: "Plugin structure",
  manifest: "Plugin manifest",
  bridges: "Bridges",
  design: "Design",
  libraryStructure: "Library structure",
  architecture: "Architecture",
  harness: "Harness",
  controlSocket: "Control socket",
  verification: "Verification",
});

const ko = sidebar("/ko", {
  start: "시작하기",
  setup: "앱에 Necto 연결하기",
  install: "Necto 앱 설치하기",
  tutorial: "플러그인을 추가하고 싶다면",
  tutorialDesktop: "1부 — 데스크톱 플러그인",
  tutorialDevice: "2부 — 디바이스 플러그인",
  publishing: "플러그인 배포하기",
  pluginStructure: "플러그인 구조",
  manifest: "플러그인 매니페스트",
  bridges: "브리지",
  design: "디자인",
  libraryStructure: "라이브러리 구조",
  architecture: "아키텍처",
  harness: "하네스",
  controlSocket: "컨트롤 소켓",
  verification: "검증",
});

export default defineConfig({
  base: "/toss-necto/",
  title: "Necto",
  description:
    "A macOS debugging tool for iOS apps, with plugins for network requests, events and performance metrics.",
  srcExclude: ["design/**"],
  vite: { plugins: [docsLicensePlugin()] },
  locales: {
    root: {
      label: "English",
      lang: "en",
      themeConfig: {
        nav: [{ text: "Docs", link: "/setup" }],
        sidebar: { "/": en },
      },
    },
    ko: {
      label: "한국어",
      lang: "ko",
      themeConfig: {
        nav: [{ text: "문서", link: "/ko/setup" }],
        sidebar: { "/ko/": ko },
        outline: { label: "이 페이지에서" },
        docFooter: { prev: "이전", next: "다음" },
      },
    },
  },
  themeConfig: {
    socialLinks: [{ icon: "github", link: repo }],
    footer: {
      message: '<a href="/toss-necto/THIRD_PARTY_NOTICES.txt">Licenses and third-party notices</a>',
    },
  },
});
