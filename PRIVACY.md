# 隐私与数据说明

## 公开仓库中有什么

仓库只包含通用 Swift 源码、离线测试样例、构建与安装脚本、说明和许可证。测试中的用量与时间为测试数据，部分链接采用公开帖号；均不是作者的账号记录。

不包含登录文件、API Key、Cookie、浏览器资料、真实账号用量、个人便签、已读记录、本机备份、真实截图、聊天标识或私人磁盘路径。

## 使用时会访问什么

1. **本机 Codex**：启动用户已安装的 `codex app-server --stdio`，执行 `initialize` / `initialized` 和只读的 `account/rateLimits/read`。不创建或恢复聊天，不调用模型，不扫描会话。Codex 自己处理现有登录及向其服务查询额度；本工具不打开或解析认证文件。
2. **公开消息**：访问 `codex-resets.com`、`will-codex-reset.com` 和 `cdn.syndication.twimg.com`；点击原帖时由默认浏览器打开 `x.com`。这些服务可按常规网络请求获得 IP 等连接信息。请求不附带用户的账号、聊天或额度，不使用用户的 X Cookie。

没有分析统计、遥测服务、作者接收端或自动上传功能。

## 本机保存什么

- `~/Library/Preferences/local.codex-battery.plist`：显示选项、个人保留线、便签、已读版本和公开消息缓存。
- `~/Library/Application Support/Codex Battery/`：供本机检查的当前状态文件，含额度比例与更新时间。它不自动上传；求助时不要直接公开整个目录。
- `~/Library/LaunchAgents/local.codex-battery.plist`：仅在用户选择登录时启动后创建。
- `~/Library/Application Support/Codex Battery Backups/`：同一主版本升级前的应用与设置备份。

数据属于使用者。请勿把运行目录、偏好文件或备份提交到 GitHub。项目的 `.gitignore` 和公开文件检查会防止常见的误提交，但不能替代发布前的人工检查。

## 演示与删除

演示使用临时偏好域和合成数据，不发送外部查询；退出后恢复真实状态。所有自动检查都使用临时状态，不产生真实完成事件。

卸载时先关闭登录时启动、退出应用，再把应用移到废纸篓。设置可按使用说明手动移到废纸篓以便恢复。卸载工具时不应删除 Codex 本身或其登录与聊天资料。
