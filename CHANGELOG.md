# 更新记录

## [1.0.2] - 2026-09-18

### 新增

- 阶段 3 正式执行完成后自动生成交付清单，输出到 `delivery_reports/`。
- 交付清单按项目输出，每个项目一行，包含订阅、项目、区域、部署数量和全部已部署模型。
- 同时输出三个 Endpoint：`OpenAIEndpoint`、`ProjectEndpoint`、`ServicesEndpoint`。
- 交付清单结束前通过交互询问是否包含 API Key，默认不包含。
- 包含 API Key 的文件名带 `_WITH_KEY` 后缀，Bash 版自动将权限设为 `600`。
- 清单数据取自 Azure 实时状态，已存在的历史部署也会一并列出。

### 修复与改进

- 缺少 `Microsoft.CognitiveServices/accounts/listKeys/action` 权限时，`ApiKey` 列留空并继续执行，不中断流程。
- 预演模式不再生成交付清单，避免产生内容不准确的交付文件。
- `.gitignore` 增加 `delivery_reports/` 和 `script_backups/`，避免凭据和备份进入仓库。
- 调整 README 中关于公开仓库的措辞，改为通用的凭据保护提示，避免使用方误解。

## [1.0.1] - 2026-09-16

### 修复

- 将 CSV 回填前的备份统一保存到 CSV 所在目录的 `csv_backups/`，文件名包含原 CSV 名称和时间戳，避免与脚本备份混淆。
- PowerShell 和 Bash 两个版本的 CSV 备份行为保持一致。
- 增加根目录和 Delivery 目录的 `.gitignore`，避免 `csv_backups/`、`logs/`、`results/` 和 `.bak.*` 文件进入公开仓库。
- 版本查询命令现在返回 `v1.0.1`。

## [1.0.0] - 2026-09-16

### 新增

- 合并订阅创建、Foundry 资源创建、模型部署和配额扩容四个阶段。
- 支持 PowerShell 和 Bash 两种运行方式。
- 支持交互式菜单、独立阶段运行和全流程运行。
- 支持按剩余共享配额批量部署模型。
- 支持将已有部署扩容至可用配额上限。
- 支持同一账户内同一模型使用多个 SKU，并通过自定义部署名区分。
- 支持 `--version` / `-Version` 查询脚本版本。

### 修复与改进

- 修复 PowerShell 回写 CSV 时全字段加引号导致后续阶段无法读取的问题。
- 增加 CSV 表头的 BOM 和引号兼容处理。
- 增加订阅创建 429 限流自动重试和 `Retry-After` 退避。
- 根据待创建订阅数量自动选择创建间隔：10 秒、20 秒或 30 秒。
- 支持通过参数覆盖订阅创建间隔。
- 增加 EA/CSP 使用范围提示。
- 完成交付模板脱敏。

## 版本规则

使用语义化版本号：

- `MAJOR`：不兼容的配置或行为变更。
- `MINOR`：向后兼容的新功能。
- `PATCH`：向后兼容的问题修复或文档修正。

Git 标签格式：`vMAJOR.MINOR.PATCH`，例如 `v1.0.0`。
