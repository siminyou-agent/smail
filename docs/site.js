"use strict";
const translations = {
  skip: "跳到正文", eyebrow: "开源 · 原生 iOS 应用", headline1: "邮件轻一点。", headline2: "生活多一点。",
  intro: "每次十封，轻轻一划。给真正重要的事留点空间，让整理 Gmail 不再是一件苦差事。",
  github: "在 GitHub 查看", watch: "看看怎么用", requirements: "原生 SwiftUI · iOS 18+ · 中文和 English",
  downloadVideo: "下载演示视频", demoCaption: "真实 App 操作，虚构演示邮件，不涉及你的真实邮箱。", fullVideo: "观看视频 ↗",
  smallByDesign: "小而专注", featureTitle: "用轻松一点的方式，整理邮件。",
  swipeTitle: "轻轻一划，做个选择。", swipeBody: "右划有用，左划没用。分类同步为 Gmail 标签。改主意了？撤销就好。", leftLabel: "← 没用", rightLabel: "有用 →",
  batchTitle: "一次只看十封。", batchBody: "从收件箱最新的十封未分类邮件开始，包含已读和未读。处理一批，歇一口气，要不要继续，由你决定。",
  readTitle: "看清楚，再决定。", readBody: "点开卡片，阅读保留 HTML 排版的邮件原文，按需加载图片。读完，回到卡片继续。",
  yourMail: "你的邮件，由你掌控", privacyTitle1: "只改分类标签。", privacyTitle2: "原邮件不变。",
  privacyBody: "Smail 直接连接 Google，没有 Smail 后台，没有 AI 分析。不删除、不归档，也不修改已读状态。",
  privacyDetail: "Google 的 gmail.modify 权限比这些操作更宽，Smail 在程序内限制为两个自定义标签。远程图片默认不加载，是否加载由你决定。",
  privacyLink: "了解工作方式 ↗", makeItYours: "开源，也可以成为你的版本。", startTitle: "给收件箱一分钟。",
  startBody: "克隆仓库，用 Xcode 打开，先体验十封演示邮件。演示模式不需要 Google 账号。",
  setupNote: "需要 macOS、Xcode 和 XcodeGen。连接真实 Gmail 需配置你自己的 Google OAuth。",
  setupLink: "配置与开发指南 ↗", inRepo: "在克隆的仓库目录中运行", demoNote: "在模拟器运行，点击「先体验十封演示邮件」。",
  privacyPolicy: "隐私政策", contact: "联系支持", licenses: "第三方许可声明", feedback: "建议与反馈 ↗"
};
const nodes = [...document.querySelectorAll("[data-i18n]")];
const english = new Map(nodes.map(node => [node, node.textContent]));
const languageButton = document.getElementById("language");
let language = "en";
try { language = localStorage.getItem("smail-site-language") || (navigator.language.startsWith("zh") ? "zh" : "en"); } catch { /* Storage can be unavailable in private browsing. */ }

function setLanguage(value) {
  language = value === "zh" ? "zh" : "en";
  document.documentElement.lang = language === "zh" ? "zh-Hans" : "en";
  for (const node of nodes) node.textContent = language === "zh" ? translations[node.dataset.i18n] || english.get(node) : english.get(node);
  languageButton.textContent = language === "zh" ? "EN" : "中文";
  languageButton.setAttribute("aria-label", language === "zh" ? "Switch to English" : "切换到简体中文");
  try { localStorage.setItem("smail-site-language", language); } catch { /* The page still works without storage. */ }
}
languageButton.hidden = false;
languageButton.addEventListener("click", () => setLanguage(language === "zh" ? "en" : "zh"));
setLanguage(language);

const video = document.getElementById("demo-video");
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
let manuallyPaused = false;
let autoPausing = false;
video.addEventListener("pause", () => { if (!autoPausing && !video.ended) manuallyPaused = true; });
video.addEventListener("play", () => { manuallyPaused = false; });
if ("IntersectionObserver" in window) {
  new IntersectionObserver(([entry]) => {
    if (entry.isIntersecting && !reducedMotion.matches && !manuallyPaused) video.play().catch(() => {});
    else if (!entry.isIntersecting && !video.paused) {
      autoPausing = true;
      video.pause();
      setTimeout(() => { autoPausing = false; }, 100);
    }
  }, { threshold: 0.25 }).observe(video);
}
reducedMotion.addEventListener("change", () => { if (reducedMotion.matches) video.pause(); });
