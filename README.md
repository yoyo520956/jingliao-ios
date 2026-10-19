# 鲸聊 · JingLiao

DeepSeek 网页版免费直连 iOS 客户端 + 本地 OpenAI 兼容 API 网关。

## 功能

- **聊天**：DeepSeek 网页版账号直连，流式输出，深度思考/联网开关，本地会话管理
- **账号池**：多账号空闲最久优先轮转，禁言/封禁状态自动识别
- **PoW 求解**：隐藏 WKWebView 运行官方 sha3 wasm（自动下载缓存），算法与官方网页同步
- **风控对齐**：x-hif-leim / x-hif-dliq 令牌自动获取刷新，X-Client-* 指纹齐全
- **本地网关**：`http://127.0.0.1:22217/v1` OpenAI 兼容（含流式与 reasoning_content），其他 App 直接连
- **device_id 抓取**：内置浏览器登录一次自动提取（数美指纹不能伪造）

## 构建

XcodeGen + GitHub Actions 云构建，产物未签名 IPA（Feather 签名安装）。

## 使用

1. 「账号」→ 添加账号 → 抓取 device_id → 登录
2. 「聊天」开聊
3. 「设置」→ 打开本地网关 → 客户端 Base URL 填 `http://127.0.0.1:22217/v1`

## 风险提示

使用网页版登录态存在封号/禁言风险，建议小号；上游风控随时可能收紧。
