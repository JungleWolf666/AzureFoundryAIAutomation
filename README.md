# Azure Foundry AI Automation

当前版本：`v1.0.3` · [更新记录](CHANGELOG.md)

用于 Azure Foundry AI 生命周期自动化的 Bash 和 PowerShell 脚本集合，支持订阅准备、Foundry 资源创建、按剩余配额批量部署模型，以及将已有部署扩容至可用配额上限。

请在本地填写 CSV 配置。CSV、日志和交付清单可能包含订阅、计费和凭据信息，请勿提交到任何公开仓库，也不要通过不安全的渠道传递。

把原来四个独立脚本合并为一个，所有参数集中在同一个 CSV 中维护：

| 阶段 | 作用 | 对应原脚本 |
|---|---|---|
| `CreateSubscription` | 在 EA Enrollment Account 下创建订阅，并回填 `SubscriptionId`【**仅限 EA 企业协议订阅**，见下方提示】 | `create_ea_subscriptions_from_csv` |
| `CreateFoundry` | 创建资源组、Foundry 服务（AIServices）和 Foundry 默认项目 | `provision_foundry_from_csv` |
| `DeployModels` | 按剩余配额批量部署模型 | `Azure_Foundry_AI_batch_deploy` |
| `ScaleUpQuota` | 把已有部署的容量扩到剩余配额上限 | `Azure_Foundry_AI_scale_up` |

## 开始前必读

### ⚠️ 阶段 1 的适用范围

- 阶段 1 `CreateSubscription` 仅适用于 **EA 企业协议订阅**。
- 如果您的订阅由 CSP 合作伙伴管理，请不要运行阶段 1，也不要运行菜单选项 5“全流程”。
- 请先联系合作伙伴创建订阅，将获得的 `SubscriptionId` 填入 CSV，然后直接从阶段 2 `CreateFoundry` 开始执行。
- 如果无法确认协议类型，请先联系贵司 Azure 管理员或服务合作伙伴。
- 正式运行阶段 1 时，脚本会要求输入大写 `EA` 进行二次确认；预演模式会自动跳过该确认。

### ⚠️ 同一账户内的部署名必须唯一

- 同一个 Foundry 账户内，`DeploymentName` 不能重复；同名部署再次创建会更新已有部署，而不是创建第二个并存部署。
- 如果同一模型需要在同一个账户内使用多个 SKU，模型名可以保持不变，但必须用不同部署名，例如：
   `gpt-5.6-sol-dz=gpt-5.6-sol:::DataZoneStandard`。
- 如果部署名必须与模型名完全一致，则需要使用两个不同的 Foundry 账户。

## 仓库文件

```text
AzureFoundryAIAutomation/
├── Azure_Foundry_AI_Automation.ps1   # PowerShell 版本
├── Azure_Foundry_AI_Automation.sh    # Bash 版本
├── Azure_Foundry_AI_Plan.csv          # 脱敏配置模板
├── CHANGELOG.md                       # 版本更新记录
└── README.md                          # 使用说明
```

两个脚本功能一致，按操作系统选择一个运行即可。脚本运行后会在当前目录自动创建 `logs/`、`results/`、`csv_backups/` 和 `delivery_reports/` 文件夹；这些运行产物不纳入仓库提交。

## 获取与快速开始

### 方式一：克隆仓库

```bash
git clone https://github.com/JungleWolf666/AzureFoundryAIAutomation.git
cd AzureFoundryAIAutomation
```

### 方式二：下载 ZIP

在 GitHub 页面选择 **Code → Download ZIP**，解压后进入项目目录。

### 开始前的操作

1. 在本地复制 `Azure_Foundry_AI_Plan.csv` 并填写配置。
2. 按照下方字段说明替换所有占位值，例如 `BILLING-ACCOUNT-ID`、`SUBSCRIPTION-DEMO` 和 `demo-*` 资源名称。
3. 确认 Azure CLI 已登录并具备对应阶段的权限。
4. 先使用预演模式验证配置，再执行正式命令。

查看版本：

```powershell
.\Azure_Foundry_AI_Automation.ps1 -Version
```

```bash
bash Azure_Foundry_AI_Automation.sh --version
```

## 运行前提

PowerShell 版本：

```powershell
az version
$PSVersionTable.PSVersion
```

- PowerShell 7+（推荐）或 Windows PowerShell 5.1
- Azure CLI
- 不依赖 `jq`、`python3`、Az PowerShell 模块

Bash 版本：

```bash
bash --version
az version
jq --version
python3 --version
```

- Bash 3.2+、Azure CLI、`jq`、Python 3

账号权限：

- 创建订阅：对应 EA Enrollment Account 的创建订阅权限，以及 `Microsoft.Subscription/aliases` 写入权限；CSP 合作伙伴管理的订阅不适用。
- 创建 Foundry：目标订阅读取权限、资源组创建/读取权限、`Microsoft.CognitiveServices` 注册权限、Cognitive Services 账户创建/读取权限，以及 Foundry Project 创建权限。
- 部署模型：目标订阅切换/读取权限、Foundry 账户读取权限、`Microsoft.CognitiveServices/locations/usages/read` 和 `accounts/deployments/read`、`accounts/deployments/write`。
- 扩容配额：与部署模型相同的读取/写入权限，以及 `Microsoft.CognitiveServices/locations/usages/read`；阶段 4 会先读取已有部署和共享配额，再更新部署容量。

## Windows 首次运行（执行策略）

Windows 默认禁止运行未签名脚本，直接双击或运行会报 `UnauthorizedAccess` / `无法加载文件`。推荐使用下面任意一种方式。

方式一：单条命令运行，不修改系统执行策略（推荐）。

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\Azure_Foundry_AI_Automation.ps1 -TenantId "<TENANT-ID>"
```

方式二：只对当前窗口放开执行策略，关闭窗口后自动失效。

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Azure_Foundry_AI_Automation.ps1 -TenantId "<TENANT-ID>"
```

如果脚本来自压缩包或网页下载，还需要先解除文件阻止：

```powershell
Unblock-File .\Azure_Foundry_AI_Automation.ps1
```

Windows 上运行脚本必须带 `.\` 前缀，不能只写文件名。

## 批量创建订阅的限流说明

阶段 1 通过 `Microsoft.Subscription/aliases` 创建订阅，属于**租户级写操作**。Azure Resource Manager 对租户范围的写请求按令牌桶限流（桶容量 200，每秒补充 10），超出后返回 `429 Too Many Requests` 并带 `Retry-After`。一次性创建 20 个以上订阅时容易触发。

脚本已内置以下缓解措施，**无需在命令中添加任何参数**：

- 遇到 429 或限流类错误时自动按 `Retry-After` 退避重试，最多 6 次。
- 每创建成功一个订阅后自动等待再创建下一个，等待时间按本次待创建数量自动选择：

  | 本次待创建订阅数 | 自动间隔 | 仅等待耗时（估算） |
  |---|---|---|
  | 1 - 20 | 10 秒 | 约 3 分钟以内 |
  | 21 - 50 | 20 秒 | 约 7 到 17 分钟 |
  | 51 及以上 | 30 秒 | 约 25 分钟起 |

- 订阅创建状态轮询间隔为 15 秒，减少租户级读请求。

以 50 个订阅为例，脚本会自动使用 20 秒间隔；如果该环境仍然出现限流，再手动调到 30 秒即可：

```powershell
.\Azure_Foundry_AI_Automation.ps1 -TenantId "<TENANT-ID>" -Stage CreateSubscription -CreateDelaySeconds 30
```

```bash
bash Azure_Foundry_AI_Automation.sh --tenant-id "<TENANT-ID>" --stage CreateSubscription --create-delay 30
```

上表的耗时只统计脚本主动等待的时间，不含订阅本身的创建和状态轮询时间，实际总时长会更长。

其他建议：

- 数量较多时建议分批执行，例如每批 20 个左右；已成功的行会自动回填 `SubscriptionId`，重跑时自动跳过，不会重复创建。
- 每个 EA 注册账户最多可创建 5000 个订阅，已取消、已删除和已转移的订阅同样计入该上限。
- 被限流失败的行会记录在 `results/stage1_subscription_creation_<时间戳>.csv` 中，修复后直接重跑阶段 1 即可。

## EA 计费账户信息从哪里查找

`BillingAccountName` 和 `EnrollmentAccountName` 只用于 EA 企业协议的阶段 1 `CreateSubscription`。如果使用的是已有订阅，或者订阅由 CSP 合作伙伴创建，则不需要通过本工具查找或填写这两个字段来创建订阅。

在 Azure Portal 中按以下路径查找：

1. 登录 [Azure Portal](https://portal.azure.com)。
2. 搜索并打开 **成本管理 + 计费**（Cost Management + Billing）。
3. 选择对应的 EA 计费账户（Billing account）。如果看不到该账户，说明当前登录身份可能没有 EA 计费范围的读取权限，请联系 EA Account Owner 或 Azure 管理员。
4. 在计费账户左侧选择 **Enrollment accounts**（注册帐户/Enrollment accounts）。
5. 将页面中的 **Billing account ID** 填入 CSV 的 `BillingAccountName`。
6. 将 **Enrollment account** 列表中对应账户的 **ID** 列填入 CSV 的 `EnrollmentAccountName`。脚本需要的是账户 ID，不是显示名称。

示例：

```text
BillingAccountName   = BILLING-ACCOUNT-ID
EnrollmentAccountName = ENROLLMENT-ACCOUNT-ID
```

注意：这两个字段填写的是名称/编号本身，不要填写完整的 Azure 资源 ID，例如不要填写 `/providers/Microsoft.Billing/...`。脚本会根据这两个值组装 EA Billing Scope：

```text
/providers/Microsoft.Billing/billingAccounts/<BillingAccountName>/enrollmentAccounts/<EnrollmentAccountName>
```

如果 Portal 中看不到 **Enrollment accounts**，或者无法确认某个 Enrollment Account 是否属于目标 Billing account，请不要猜测，联系贵司 Azure 管理员或 EA 服务合作伙伴确认后再运行阶段 1。

## CSV 配置

仓库中的 `Azure_Foundry_AI_Plan.csv` 是脱敏后的交付模板，包含 `BILLING-ACCOUNT-ID`、`ENROLLMENT-ACCOUNT-ID` 和 `SUBSCRIPTION-DEMO` 等占位值，不能直接用于正式部署。运行前请根据您的协议类型和 Azure 资源情况替换所有占位值；使用已有订阅或从阶段 2 开始时，还必须填写真实的 `SubscriptionId`。

列名和顺序必须严格一致：

```csv
BillingAccountName,EnrollmentAccountName,SubscriptionName,SubscriptionId,ResourceGroupName,FoundryResourceName,DefaultProjectName,Location,ModelNames,ModelVersion,ModelFormat,DeploymentType,DeploymentCapacityK
```

| 字段 | 说明 |
|---|---|
| `BillingAccountName` | EA Billing Account ID，例如 `BILLING-ACCOUNT-ID` |
| `EnrollmentAccountName` | EA Account ID，例如 `ENROLLMENT-ACCOUNT-ID` |
| `SubscriptionName` | 订阅名称。使用已有订阅时必须与 Azure 中的真实名称完全一致 |
| `SubscriptionId` | 创建订阅前留空，创建成功后自动回填；使用已有订阅时手工填写 |
| `ResourceGroupName` | 要创建或复用的资源组 |
| `FoundryResourceName` | Foundry 账户资源名，同时用于生成 `customSubDomainName`（2-64 位字母/数字/连字符，不支持下划线；支持大小写，但自定义子域名会自动转小写） |
| `DefaultProjectName` | Foundry 账户下的默认 Project |
| `Location` | 资源组、Foundry 账户和 Project 的区域 |
| `ModelNames` | 分号分隔的模型列表，部署和扩容阶段共用 |
| `ModelVersion` | 该行模型的默认版本 |
| `ModelFormat` | 该行模型的默认格式，留空按 `OpenAI` 处理 |
| `DeploymentType` | SKU，留空按 `GlobalStandard` 处理 |
| `DeploymentCapacityK` | 留空表示自动用满剩余配额；填数字表示固定容量（K TPM，仅对文本类模型有效；`gpt-image-*`/`dall-e`/`sora` 等模型的配额单位是 RPM，脚本会自动识别并在日志/交付清单中显示为 `RPM`，不套用 K/M 换算） |

`ModelNames` 每项支持以下写法，省略的部分回退到该行的 `ModelVersion` / `ModelFormat` / `DeploymentType`：

```text
gpt-5.6-sol                              仅模型名（继承整行 Version / Format / SKU）
gpt-image-2:2026-04-21                   模型名 + 版本
FW-GLM-5.2::Fireworks                    模型名 + 格式（版本继承整行）
FW-GLM-5.2:::DataZoneStandard            模型名 + 单独指定 SKU
FW-GLM-5.2:1:Fireworks:DataZoneStandard  模型名 + 版本 + 格式 + SKU
gpt-5.6-sol-dz=gpt-5.6-sol                自定义部署名（=左侧）+ 模型名（=右侧）
gpt-5.6-sol-dz=gpt-5.6-sol:::DataZoneStandard  自定义部署名 + 单独指定 SKU
```

## 注意事项（常见问题与规避）

1. **阶段 1 仅限 EA 企业协议订阅，CSP 合作伙伴管理的订阅请勿运行**：
   - `CreateSubscription`（包括菜单选项 1 以及菜单选项 5“全流程”里的阶段 1）只适用于 EA 企业协议订阅。
   - 如果您的订阅由 CSP 合作伙伴管理，请不要运行阶段 1；请先联系合作伙伴创建订阅，并将获得的 `SubscriptionId` 填入 CSV，然后直接从阶段 2（`CreateFoundry`）开始执行。
   - 运行前如无法确认协议类型，请联系贵司 Azure 管理员或服务合作伙伴。
   - 脚本在进入阶段 1 时会先输出警告并要求额外输入大写 `EA` 确认（预演模式下自动跳过确认），但仍需在交付前先口头/文档告知清楚，避免误运行后因权限不足报错。
2. **日期格式必须为标准连字符格式**：
   - 模型版本请务必使用 **`YYYY-MM-DD`（如 `2026-07-09`）**。
   - 若使用 Excel 编辑 CSV，请注意单元格格式，避免被自动转换为 `2026/7/9`（虽然脚本内置了自动容错归一化，但建议源文件保持标准格式）。
3. **FoundryResourceName 命名规则与唱一性**：
   - 允许字母（不区分大小写）、数字、连字符 `-`，2-64 位，首尾必须为字母或数字，**不支持下划线**。
   - `FoundryResourceName` 同时作为 Custom Domain Name（自定义子域名），子域名本质上是 DNS 主机名的一部分，脚本会自动将它转为全小写后写入 Azure（Azure 账户资源名本身仍保留您在 CSV 中填写的大小写）。
   - 在 Azure 全局公共命名空间内必须全局唯一，不可使用 `foundry-ai-01` 等过于通用的名称。
4. **订阅名与订阅 ID 一致性校验**：
   - 使用已有订阅时，CSV 中的 `SubscriptionName` 必须与 Azure Portal 中的真实订阅名称严格匹配，否则脚本会拒绝执行以防止误操作。
5. **配额与模型存在性**：
   - 部署前请确认目标模型在所选 Azure 区域有对应 SKU（如 `GlobalStandard` 或 `DataZoneStandard`）的配额项。
   - 日志与交付清单中的配额单位目前只有两种：**TPM**（文本类模型，按 K/M 千进制显示，如 `10 K TPM`、`3.333 M TPM`）和 **RPM**（按请求计费，直接显示原始数值，如 `10 RPM`）。`gpt-image-*`、`dall-e`、`sora` 等模型基于名称关键字识别为 RPM 类型。这是启发式匹配，如遇到未覆盖的新模型类型，请以 Azure 门户实际显示的配额单位为准。
6. **警惕在 Portal 上手动删除资源引发的软删除冲突**：
   - 删除资源组会级联删除组内所有 Foundry 账户，账户随即进入软删除状态。
   - 若某 Foundry 账户下**只有一个（默认）项目**，直接在 Portal 删除这个项目，很可能会连账户一起删除（而不仅仅是项目本身），进而触发软删除保护。
   - 账户或项目被软删除后，同名重新创建会被 Azure 拒绝（`FlagMustBeSetForRestore`），必须先清除才能重新创建。详细排查/解决步骤见下方「常见问题」中的 `FlagMustBeSetForRestore` 条目。

---

## 命名建议

`FoundryResourceName` 同时作为 Custom Domain Name，必须**全局唯一**，不要使用 `foundry-ai-01` 这类通用名。允许大小写字母、数字、连字符（不支持下划线），脚本会在写入 Azure 时自动把自定义子域名转换为小写，无需手工改成全小写：

```text
<customer-short>-foundry-<workload>-<region>-<seq>
例：demo-foundry-01-eus2-001
```

`DefaultProjectName` 建议在同一账户下唯一且可读：

```text
proj-<workload>-<env>-<region>
例：proj-demo-prod-eus2
```

## 运行方式

脚本支持**交互式菜单**与**命令行直接指定阶段**两种方式。每个阶段都**完全支持独立单独运行**，并且每个阶段都支持先用 `--dry-run` / `-DryRun` 预演。

### 方式一：交互式菜单（推荐）

不带 `-Stage` / `--stage` 时进入菜单选择阶段：

```powershell
.\Azure_Foundry_AI_Automation.ps1 -TenantId "<TENANT-ID>"
```

```bash
bash Azure_Foundry_AI_Automation.sh --tenant-id "<TENANT-ID>"
```

菜单项：

```text
1) 创建 Azure 订阅（仅限 EA 企业协议订阅，回填 SubscriptionId）
2) 创建 Foundry 服务和 Foundry 项目
3) 批量部署模型（按剩余配额）
4) 批量扩容已有部署配额
5) 全流程（1 -> 2 -> 3）
0) 退出
```

---

### 方式二：单阶段独立运行命令

你可以根据当前业务进度，跳过菜单直接单独执行任意阶段：

#### 阶段 1：单独创建 Azure 订阅
> 依赖 CSV 字段：`BillingAccountName`、`EnrollmentAccountName`、`SubscriptionName`  
> 执行后自动回填 `SubscriptionId`，并在 CSV 所在目录的 `csv_backups/` 中生成带时间戳的 CSV 备份文件。

```powershell
# 预演
.\Azure_Foundry_AI_Automation.ps1 -TenantId "<TENANT-ID>" -Stage CreateSubscription -DryRun
# 正式创建
.\Azure_Foundry_AI_Automation.ps1 -TenantId "<TENANT-ID>" -Stage CreateSubscription
```

```bash
# 预演
bash Azure_Foundry_AI_Automation.sh --tenant-id "<TENANT-ID>" --stage CreateSubscription --dry-run
# 正式创建
bash Azure_Foundry_AI_Automation.sh --tenant-id "<TENANT-ID>" --stage CreateSubscription
```

#### 阶段 2：单独创建 Foundry 服务和项目
> 依赖 CSV 字段：`SubscriptionId`、`ResourceGroupName`、`FoundryResourceName`、`DefaultProjectName`、`Location`  
> 自动完成 `Microsoft.CognitiveServices` 提供程序注册、资源组创建、AIServices 账户创建及默认项目创建。

```powershell
# 预演
.\Azure_Foundry_AI_Automation.ps1 -TenantId "<TENANT-ID>" -Stage CreateFoundry -DryRun
# 正式创建
.\Azure_Foundry_AI_Automation.ps1 -TenantId "<TENANT-ID>" -Stage CreateFoundry
```

```bash
# 预演
bash Azure_Foundry_AI_Automation.sh --tenant-id "<TENANT-ID>" --stage CreateFoundry --dry-run
# 正式创建
bash Azure_Foundry_AI_Automation.sh --tenant-id "<TENANT-ID>" --stage CreateFoundry
```

#### 阶段 3：单独批量部署模型（按剩余配额）
> 依赖 CSV 字段：`SubscriptionId`、`ResourceGroupName`、`FoundryResourceName`、`ModelNames` 等  
> 自动探测目标区域剩余共享配额，并在账户中批量创建指定模型部署。`DeploymentCapacityK` 留空时使用全部剩余配额；填写正整数时作为本次容量上限，但如果剩余配额更少，实际部署容量会自动降到剩余配额。  
> 正式执行完成后会自动生成交付清单，并询问是否包含 API Key（默认不包含），详见下方「交付清单」章节。

```powershell
# 预演
.\Azure_Foundry_AI_Automation.ps1 -TenantId "<TENANT-ID>" -Stage DeployModels -DryRun
# 正式创建
.\Azure_Foundry_AI_Automation.ps1 -TenantId "<TENANT-ID>" -Stage DeployModels
```

```bash
# 预演
bash Azure_Foundry_AI_Automation.sh --tenant-id "<TENANT-ID>" --stage DeployModels --dry-run
# 正式创建
bash Azure_Foundry_AI_Automation.sh --tenant-id "<TENANT-ID>" --stage DeployModels
```

#### 阶段 4：单独批量扩容已有部署配额
> 适用于后续申请了更多配额、需要将已有部署容量“拉满”的场景。以 CSV 的 `ModelNames` 中的**模型名**为白名单过滤已有部署；部署名、版本、格式、SKU 和当前容量均从 Azure 实时读取，`DeploymentCapacityK` 在本阶段不参与计算。目标容量为当前部署容量加上该模型/SKU 的剩余共享配额。

```powershell
# 预演
.\Azure_Foundry_AI_Automation.ps1 -TenantId "<TENANT-ID>" -Stage ScaleUpQuota -DryRun
# 正式创建
.\Azure_Foundry_AI_Automation.ps1 -TenantId "<TENANT-ID>" -Stage ScaleUpQuota
```

```bash
# 预演
bash Azure_Foundry_AI_Automation.sh --tenant-id "<TENANT-ID>" --stage ScaleUpQuota --dry-run
# 正式创建
bash Azure_Foundry_AI_Automation.sh --tenant-id "<TENANT-ID>" --stage ScaleUpQuota
```

#### 菜单选项 5：全流程自动化（阶段 1 -> 阶段 2 -> 阶段 3）
> 一键串联：从空白 CSV 创建订阅 -> 自动回填 -> 创建 Foundry 资源 -> 批量部署模型。
> 仅适用于 EA 企业协议订阅；CSP 合作伙伴管理的订阅请跳过本选项，直接运行阶段 2。

```powershell
# 预演
.\Azure_Foundry_AI_Automation.ps1 -TenantId "<TENANT-ID>" -Stage All -DryRun
# 正式执行
.\Azure_Foundry_AI_Automation.ps1 -TenantId "<TENANT-ID>" -Stage All
```

```bash
# 预演
bash Azure_Foundry_AI_Automation.sh --tenant-id "<TENANT-ID>" --stage All --dry-run
# 正式执行
bash Azure_Foundry_AI_Automation.sh --tenant-id "<TENANT-ID>" --stage All
```

## 安全设计

- 所有阶段都支持预演模式，不创建或修改任何 Azure 资源
- 正式执行前显示完整计划并要求输入大写 `YES`
- 部署前校验订阅 ID、订阅名和租户三者一致，避免资源建到错误订阅
- 已存在且配置一致的资源会跳过；配置冲突会标记失败而不是覆盖
- 不删除任何资源
- 回填 CSV 前自动将原文件备份到 `csv_backups/`，并使用原子替换写入；该目录专门保存 CSV 历史备份，不是脚本备份目录
- 未注册 `Microsoft.CognitiveServices` 时自动注册并记录到日志
- 阶段 1 仅调用订阅别名创建 API；CSP 订阅不会因为运行阶段 1 而获得创建权限
- 交付清单默认不包含 API Key，需要在阶段 3 结束时主动输入大写 `KEY` 才会导出
- 含 API Key 的清单文件名带 `_WITH_KEY` 后缀，Bash 版会将文件权限设为 `600`
- API Key 只写入交付清单文件，不会输出到终端或日志
- `csv_backups/`、`logs/`、`results/`、`delivery_reports/` 已加入 `.gitignore`，避免凭据误入仓库

## 交付清单（阶段 3 自动生成）

阶段 3 正式执行完成后，脚本会读取 Azure 上的实际状态，生成一份可直接交付给项目负责人的清单，输出到 `delivery_reports/`。

清单**每个项目一行**，包含订阅、项目、三个 Endpoint 和该项目下所有已部署模型：

| 列 | 说明 |
|---|---|
| `SubscriptionName` / `SubscriptionId` | 所属订阅 |
| `ResourceGroupName` / `FoundryResourceName` / `ProjectName` / `Location` | 资源定位信息 |
| `DeploymentCount` | 该项目下的部署数量 |
| `DeployedModels` | 全部部署，格式为 `部署名(模型名, SKU, 容量K)`，多个用 `;` 分隔 |
| `OpenAIEndpoint` | `https://<子域>.openai.azure.com/`，接入 AI 网关和 OpenAI SDK 常用 |
| `ProjectEndpoint` | `https://<子域>.services.ai.azure.com/api/projects/<项目名>`，Foundry SDK 和 Agent 使用 |
| `ServicesEndpoint` | `https://<子域>.cognitiveservices.azure.com/`，Foundry Tools 使用 |
| `ApiKey` | 默认留空，仅在运行时选择包含后才填充 |

三个 Endpoint 共用同一个账户级 API Key，因此清单中只输出一列 `ApiKey`。

### API Key 的导出是交互式的

阶段 3 结束时会询问是否在清单中包含 API Key，**默认不包含**：

```text
API Key 是明文长期凭据，一旦泄露即可直接调用该 Foundry 资源。
默认不导出。仅在需要交付给项目负责人时才导出，并通过安全渠道传递。
是否在交付清单中包含 API Key？输入大写 KEY 表示包含，其他任意输入表示不包含：
```

- 输入大写 `KEY`：包含 API Key，文件名带 `_WITH_KEY` 后缀，Bash 版会将文件权限设为 `600`。
- 输入其他任意内容：`ApiKey` 列留空。
- 预演模式不会生成交付清单。
- 若账号缺少 `Microsoft.CognitiveServices/accounts/listKeys/action` 权限，该列留空并继续，不会中断。

> ⚠️ 带 `_WITH_KEY` 的文件包含明文凭据，等同于该 Foundry 资源的访问权限。请通过安全渠道传递给客户，要求客户妥善保管，并在交付完成后删除本地副本。该目录已加入 `.gitignore`，不会被提交到仓库。

## 输出

```text
logs/azure_foundry_ai_automation_<时间戳>.log
results/stage1_subscription_creation_<时间戳>.csv
results/stage2_foundry_provisioning_<时间戳>.csv
results/stage3_model_deployment_<时间戳>.csv
results/stage4_quota_scale_up_<时间戳>.csv
delivery_reports/foundry_endpoints_<时间戳>.csv
delivery_reports/foundry_endpoints_<时间戳>_WITH_KEY.csv
```

## 常见问题

`CustomDomainInUse`：`FoundryResourceName` 已被全局占用，换一个更唯一的名称后重跑。

`UserNotAuthorized`：当前账号无权在该 `BillingAccountName` / `EnrollmentAccountName` 下创建订阅，需确认 Account Owner 权限。

订阅名不匹配：CSV 中的 `SubscriptionName` 与 Azure 实际名称不一致，脚本会拒绝继续，请改成 Portal 中显示的真实名称。

区域没有配额项：目标区域未提供该模型或该 SKU 组合，请更换区域或模型。

`FlagMustBeSetForRestore`：目标 Foundry 账户同名资源之前被删除过，仍处于 Azure 的软删除保护期内，无法直接用同名重新创建。常见诱因：

- 在 Portal 手动删除了资源组（会级联删除组内所有账户）。
- 在 Portal 手动删除了账户本身。
- 账户下只有一个（默认）项目时，在 Portal 删除了这个项目——实测发现这种情况下账户会被一起删除，而不仅仅是移除项目。

解决步骤：

1. 确认是否处于软删除状态（需先 `az account set --subscription <订阅ID>` 切换到对应订阅）：
   ```bash
   az cognitiveservices account list-deleted --output table
   ```
2. 确认不需要恢复原账户后，执行清除（**不可逆操作**，请确认账户内无需保留的数据/密钥/部署）：
   ```bash
   az cognitiveservices account purge --location <区域> --resource-group <资源组> --name <账户名>
   ```
   `purge` 返回退出码 `0` 仅表示请求被接受，不代表立即在所有后端节点生效。实测有时需要等待几分钟到几十分钟才真正清除完成；若清除后立即重跑仍报同样错误，请重新执行 `list-deleted` 确认，必要时再次 `purge` 并耐心等待。
3. 确认 `list-deleted` 返回为空后，重新运行阶段 2（`CreateFoundry`）重建账户和默认项目，再运行阶段 3重新部署模型（模型部署挂在账户下，账户被删除后部署记录也会一并丢失，必须重新部署，光跑阶段 3 不够）。

预防建议：

- 尽量不要在 Portal 上手动删除资源组/账户/项目，改用 CLI 精确操作。
- 如果只想调整项目配置，优先直接在 Portal 编辑项目设置，而不是删除重建。
- 确实需要删除项目时，先新建一个项目确认可用后再删除旧项目，确保账户下至少始终保留一个项目；或直接用 CLI 删除项目（不会级联删除账户）：
  ```bash
  az cognitiveservices account project delete --name <账户名> --resource-group <资源组> --project-name <项目名>
  ```

## 灵活配置与多场景参考

以下场景属于高级配置。基础部署只需要按前面的 CSV 字段说明填写一行或多行配置；只有在存在多个账户、多个 SKU 或单行混合模型参数时，才需要参考本节。

### 场景 1：同一订阅、同一 FoundryResourceName、同一 DefaultProjectName，同一模型部署多个 SKU

CSV 中使用两行完全相同的 `SubscriptionName`、`FoundryResourceName` 和 `DefaultProjectName`，只区分 `DeploymentType`，并为第二个 SKU 指定不同的部署名：

- 阶段 1：同一订阅只创建一次。
- 阶段 2：同一 Foundry 账户只创建一次，后续行自动复用。
- 阶段 3：按不同 SKU 查询配额，并用部署名、模型名和 SKU 三者判断是否已存在。

```csv
BillingAccountName,EnrollmentAccountName,SubscriptionName,SubscriptionId,ResourceGroupName,FoundryResourceName,DefaultProjectName,Location,ModelNames,ModelVersion,ModelFormat,DeploymentType,DeploymentCapacityK
BILLING-ACCOUNT-ID,ENROLLMENT-ACCOUNT-ID,SUBSCRIPTION-DEMO,,rg-foundry-demo,demo-foundry-01-eus2-001,proj-demo-prod-eus2,eastus2,gpt-4o;gpt-4o-mini,2026-01-01,OpenAI,GlobalStandard,
BILLING-ACCOUNT-ID,ENROLLMENT-ACCOUNT-ID,SUBSCRIPTION-DEMO,,rg-foundry-demo,demo-foundry-01-eus2-001,proj-demo-prod-eus2,eastus2,gpt-4o-dz=gpt-4o:::DataZoneStandard,2026-01-01,OpenAI,DataZoneStandard,
```

上例会在同一个 Foundry 账户/Project 中创建两个 `gpt-4o` 部署：`gpt-4o` 使用 `GlobalStandard`，`gpt-4o-dz` 指向相同的模型但使用 `DataZoneStandard`。模型名没有改变，只有部署名增加了区分后缀。

#### 替代方案：部署名必须与模型名完全一致

如果业务要求部署名不能增加任何后缀，只能使用两个不同的 Foundry 账户。两个账户可以共用订阅和资源组，但每个账户内都使用裸模型名：

```csv
BillingAccountName,EnrollmentAccountName,SubscriptionName,SubscriptionId,ResourceGroupName,FoundryResourceName,DefaultProjectName,Location,ModelNames,ModelVersion,ModelFormat,DeploymentType,DeploymentCapacityK
BILLING-ACCOUNT-ID,ENROLLMENT-ACCOUNT-ID,SUBSCRIPTION-DEMO,,rg-foundry-demo,demo-foundry-global-eus2-001,proj-demo-global-eus2,eastus2,gpt-4o;gpt-4o-mini,2026-01-01,OpenAI,GlobalStandard,
BILLING-ACCOUNT-ID,ENROLLMENT-ACCOUNT-ID,SUBSCRIPTION-DEMO,,rg-foundry-demo,demo-foundry-dz-eus2-001,proj-demo-dz-eus2,eastus2,gpt-4o;gpt-4o-mini,2026-01-01,OpenAI,DataZoneStandard,
```

### 场景 2：同一订阅下创建多个 Foundry 账户或 Project

在 CSV 中保持 `SubscriptionName` / `SubscriptionId` 相同，分别指定不同的 `FoundryResourceName` 和 `DefaultProjectName`。各账户可以位于相同或不同资源组、相同或不同 Azure 区域：

```csv
BillingAccountName,EnrollmentAccountName,SubscriptionName,SubscriptionId,ResourceGroupName,FoundryResourceName,DefaultProjectName,Location,ModelNames,ModelVersion,ModelFormat,DeploymentType,DeploymentCapacityK
BILLING-ACCOUNT-ID,ENROLLMENT-ACCOUNT-ID,SUBSCRIPTION-DEMO,,rg-foundry-demo,demo-foundry-team-a-eus2-001,proj-demo-team-a-eus2,eastus2,gpt-4o;gpt-4o-mini,2026-01-01,OpenAI,GlobalStandard,
BILLING-ACCOUNT-ID,ENROLLMENT-ACCOUNT-ID,SUBSCRIPTION-DEMO,,rg-foundry-demo,demo-foundry-team-b-eus2-001,proj-demo-team-b-eus2,eastus2,gpt-4o-mini,2026-01-01,OpenAI,GlobalStandard,
```

### 场景 3：单行内混合指定模型 SKU、版本和格式

如果不想拆多行，可以在同一行的 `ModelNames` 中通过 `name:version:format:sku` 为个别模型覆盖默认值：

```csv
BillingAccountName,EnrollmentAccountName,SubscriptionName,SubscriptionId,ResourceGroupName,FoundryResourceName,DefaultProjectName,Location,ModelNames,ModelVersion,ModelFormat,DeploymentType,DeploymentCapacityK
BILLING-ACCOUNT-ID,ENROLLMENT-ACCOUNT-ID,SUBSCRIPTION-DEMO,,rg-foundry-demo,demo-foundry-01-eus2-001,proj-demo-prod-eus2,eastus2,gpt-4o;gpt-image-1:2026-01-01,2026-01-01,OpenAI,GlobalStandard,
```

- `gpt-4o`：继承整行的版本、格式和 SKU。
- `gpt-image-1`：覆盖版本为 `2026-01-01`，其余继承整行。
