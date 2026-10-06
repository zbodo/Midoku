# Nightly 构建成功通知

在仓库 **Settings → Secrets and variables → Actions** 中分别配置：

| 类型 | 名称 | 示例值 |
| --- | --- | --- |
| Variable | `BARK_SERVER_URL` | `https://api.day.app` |
| Secret | `BARK_KEY` | `kkkk` |

例如完整地址为 `https://api.day.app/kkkk` 时，按上表拆分填写。
服务地址不要包含密钥、查询参数或片段；支持自建 HTTPS Bark 服务及其路径前缀。

`nightly.yml` 内的 `notify` job 通过 `needs: build` 等待构建成功后通知手机，
直接使用运行分支上的配置。

通知包含工作流名称、分支和运行编号，点击可打开对应 Actions 运行；
使用 `group=example` 和 `ttl=600`。
失败或取消的构建不通知，未配置地址或密钥时跳过，通知失败不改变构建结果。
