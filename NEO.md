# NetNewsWire Neo

基于 NetNewsWire mac-7.2.1 的本地 macOS 分支，加入简体中文界面和第三方 AI RSS 翻译。

## 使用

- 在「设置 → AI 翻译」配置兼容 Chat Completions 的 HTTPS API 地址、模型、API 密钥和目标语言。
- 阅读文章时点击「翻译为中文」，完成后可切换原文/译文；原始 RSS 内容不会被覆盖。
- 「自动后台翻译所有文章」默认关闭。开启后扫描已保存的所有订阅源文章，并翻译后续抓取的新文章及更新文章。
- 中文文章（简体/繁体，包含英文技术术语也可识别）自动跳过，手动按钮也会禁用；已有中文译文缓存不会显示。
- 队列串行执行，手动任务优先。关闭开关会取消后台队列及正在进行的后台翻译；应用退出时停止，重新打开后按缓存恢复扫描。
- 翻译结果按账号、文章、正文、API 地址、模型和语言缓存，位于 `~/Library/Application Support/NetNewsWire Neo/Translations`。切换模型或语言不会错误复用旧译文。
- 429/5xx 最多重试三次。其他错误会暂停后台队列，修正配置并保存后恢复。文章超过 200,000 字符会提示，不会静默截断。
- 译文以转义后的纯文本展示，保留段落；图片、链接和原始排版可通过「查看原文」或「展开原文」访问。

## 构建和验证

需要完整 Xcode（Swift 6.2+、macOS 15+）。本地 Apple Silicon 构建：

```sh
bash scripts/test-ai-translation.sh
bash scripts/build-neo.sh
```

产物：`.build-local/Build/Products/Debug/NetNewsWire Neo.app`。使用独立标识 `local.lnk137.NetNewsWireNeo` 和数据目录，不覆盖官方版的数据。

本机构建使用 ad-hoc 签名和上游开发配置；iCloud、Feedly OAuth 及依赖上游私有服务密钥的阅读视图不具备官方发行版的服务凭据。普通 RSS 本地账号和本次新增的第三方 AI API 不依赖这些服务。官方自动更新已禁用，防止将 Neo 替换回上游版本。

## 凭据

API 密钥存放于 macOS 钥匙串，不编译进应用，不提交到 Git。a6api 首次安装可运行：

```sh
conda run -n base python scripts/configure-a6api.py /path/to/agent-secrets.txt
```

脚本只创建权限为 0600 的临时初始化文件；Neo 启动后导入钥匙串并删除文件。不要将此初始化文件纳入分发包。自动后台翻译会将 RSS 标题和正文发送给你配置的 API 提供商，并消耗该服务的调用额度。

## 中文界面

中文翻译位于原有 `.xcstrings` 目录，保持上游英文和其他语言。macOS 根据应用语言选择简体中文；也可在系统设置的应用语言中切换。翻译生成脚本会校验格式占位符，可复用缓存后重新运行；生成后应人工检查重要界面。

上游项目及许可证见 [README.md](README.md)、[LICENSE](LICENSE)。
