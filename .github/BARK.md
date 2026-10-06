# Actions 成功通知

在仓库 **Settings → Secrets and variables → Actions** 中分别配置：

| 类型 | 名称 | 示例值 |
| --- | --- | --- |
| Variable | `BARK_SERVER_URL` | `https://api.day.app` |
| Secret | `BARK_KEY` | `kkkk` |

例如完整地址为 `https://api.day.app/kkkk` 时，按上表拆分填写。
服务地址不要包含密钥、查询参数或片段；支持自建 HTTPS Bark 服务及其路径前缀。

`bark.yml` 在 macOS Desktop、Build native macOS app、SwiftLint 或
Legacy AltStore Source (manual only) 成功完成后通知手机。通知包含工作流名称、
分支和运行编号，点击可打开对应 Actions 运行；使用 `group=example` 和 `ttl=600`。
失败或取消的运行不通知，未配置地址或密钥时跳过，通知失败不改变原工作流结果。

此工作流必须合入仓库默认分支后，GitHub 才会触发 `workflow_run` 通知。
通知任务不下载或执行被监控工作流的代码或产物。
