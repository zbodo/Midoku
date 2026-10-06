# Aidoku v0.9 备份导入

格式依据：[Aidoku v0.9 BackupManager](https://github.com/Aidoku/Aidoku/blob/v0.9/Aidoku/Core/Backup/BackupManager.swift) 和该版本的 `Backup/Models`。默认导出文件为 `.aib` 二进制 plist；兼容原应用的 plist／JSON 解码路径，JSON 日期采用 Unix 秒数。

在“文件 → Aidoku Library & Backups…”打开导入书架，选择“Import Aidoku Backup…”。原有“Import Comics…”也接受单个 `.aib`、`.json` 或 `.plist` 备份，并显示同一导入预览。

## 导入行为

- 采用合并导入，保留本地漫画和已安装书源。按原始 sourceId、mangaId、chapterId 区分记录；重复导入不重复创建记录。阅读历史选择更新的 dateRead，本地更晚的阅读进度也会保留。
- 导入漫画在 Aidoku 书架中按原有多分类筛选，打开详情可浏览保存的漫画信息和章节。已有书源时可以读取章节；缺失书源的漫画会显示状态，其数据保留。
- Aidoku 的页码从 1 开始，桌面索引从 0 开始；导入时转换并限制在实际章节页数范围内。备份中的旧版 viewer 和 nsfw 枚举按语义转换，不能直接使用 AidokuRunner 的 rawValue。
- 可选择恢复书源设置和已支持的阅读设置：Reader.readingMode 映射方向／连续布局，漫画专属的 Reader.readingMode.<sourceId>.<mangaId> 优先于全局设置，Reader.invertTapZones 映射点击区域反转。漫画通过 editedKeys 标记的自定义标题、作者、描述等内容在刷新后继续保留。书源设置保留布尔、整数、小数、字符串、数组和对象类型，并只应用精确的书源命名空间；用户后续修改不会被每次打开书源重置。
- 可选择添加仓库并安装缺失书源；各项失败独立报告。本地数据先保存，网络失败不会删除已导入数据，可以从导入书架重试书源恢复。
- 本地写入采用原子替换；在写入前保存 `Application Support/Midoku/Backups/before-aidoku-<UUID>.json`。写入失败不会提交新快照或应用偏好。可关闭应用后，将备份副本复制为 `Application Support/Midoku/library.json` 恢复原书架。
- 完整备份以不可变版本存放于 `Application Support/Midoku/AidokuBackups/`，书架只保存存档引用。日常阅读进度保存不会重写整份导入数据；旧版本存档保留，便于通过书架副本回退。
- 完整原始文件与全部解码字段持久化，包含未知字段。导入书架中的“Save Original…”可重新保存字节一致的原备份。

## 兼容范围

支持 v0.9 全部导出区段：library、manga、chapters、history、categories、sources、sourceLists、settings、trackItems、readingSessions、vocabulary、updates，以及日期、名称、版本和自动备份标记。兼容字符串／对象两种分类和书源表示，以及只包含部分区段的备份。文件限制为 64 MiB。

这项实现提供完整格式读取和数据保留，但桌面运行时的功能仍有差异：追踪、词汇、更新调度、阅读统计、分类分组与自定义书源配置仅保留，尚无对应可用功能；其余未映射的 iOS 设置也不应用。当前运行时只执行现代 ABI 0.7 书源；旧 ABI、内置本地／Komga／Suwayomi 等书源不能由备份直接重建。

Aidoku 备份不包含书源程序、已下载漫画文件或 Keychain 内容。离线阅读文件与账号凭据需另行处理，不能通过元数据备份恢复。

## 验证

核心测试使用独立构造的 v0.9 格式 JSON 和 Foundation 二进制 plist，覆盖全部区段、日期与 Data 字段、精确设置类型、重复合并、进度保护、非法文件拒绝，以及原始未知字段在持久化后的保留。

macOS 集成测试覆盖 viewer／内容分级转换、章节继续阅读、本地新进度优先、设置不会反复覆盖及写入失败保护。Linux 只能执行核心测试和 Swift 语法检查，原生编译与界面流程需在 Mac 上验证。
