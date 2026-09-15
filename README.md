# Azure Foundry 全生命周期统一脚本

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

## 文件

```text
Azure_Foundry_AI_Automation/
├── Azure_Foundry_AI_Automation.ps1   # Windows 推荐
├── Azure_Foundry_AI_Automation.sh    # macOS / Linux / WSL
├── Azure_Foundry_AI_Plan.csv        # 唯一配置来源
├── logs/                         # 运行日志
└── results/                      # 每阶段结果 CSV
```

两个版本功能一致，选一个运行即可。

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

Windows 上脚本必须以 `.\` 开头运行。若脚本来自压缩包或网页下载，先解除阻止：

```powershell
Unblock-File .\Azure_Foundry_AI_Automation.ps1
```

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
| `FoundryResourceName` | Foundry 账户资源名，同时作为 `customSubDomainName` |
| `DefaultProjectName` | Foundry 账户下的默认 Project |
| `Location` | 资源组、Foundry 账户和 Project 的区域 |
| `ModelNames` | 分号分隔的模型列表，部署和扩容阶段共用 |
| `ModelVersion` | 该行模型的默认版本 |
| `ModelFormat` | 该行模型的默认格式，留空按 `OpenAI` 处理 |
| `DeploymentType` | SKU，留空按 `GlobalStandard` 处理 |
| `DeploymentCapacityK` | 留空表示自动用满剩余配额；填数字表示固定容量（K TPM） |

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
3. **FoundryResourceName 唯一性**：
   - `FoundryResourceName` 同时作为 Custom Domain Name，在 Azure 全局公共命名空间内唯一，不可使用 `foundry-ai-01` 等过于通用的名称。
4. **订阅名与订阅 ID 一致性校验**：
   - 使用已有订阅时，CSV 中的 `SubscriptionName` 必须与 Azure Portal 中的真实订阅名称严格匹配，否则脚本会拒绝执行以防止误操作。
5. **配额与模型存在性**：
   - 部署前请确认目标模型在所选 Azure 区域有对应 SKU（如 `GlobalStandard` 或 `DataZoneStandard`）的配额项。

---

## 命名建议

`FoundryResourceName` 同时作为 Custom Domain Name，必须**全局唯一**，不要使用 `foundry-ai-01` 这类通用名：

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
> 执行后自动回填 `SubscriptionId` 并生成 `.bak` 备份文件。

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
- 回填 CSV 前自动生成 `.bak.<时间戳>` 备份，并使用原子替换写入
- 未注册 `Microsoft.CognitiveServices` 时自动注册并记录到日志
- 阶段 1 仅调用订阅别名创建 API；CSP 订阅不会因为运行阶段 1 而获得创建权限

## 输出

```text
logs/azure_foundry_ai_automation_<时间戳>.log
results/stage1_subscription_creation_<时间戳>.csv
results/stage2_foundry_provisioning_<时间戳>.csv
results/stage3_model_deployment_<时间戳>.csv
results/stage4_quota_scale_up_<时间戳>.csv
```

## 常见问题

`CustomDomainInUse`：`FoundryResourceName` 已被全局占用，换一个更唯一的名称后重跑。

`UserNotAuthorized`：当前账号无权在该 `BillingAccountName` / `EnrollmentAccountName` 下创建订阅，需确认 Account Owner 权限。

订阅名不匹配：CSV 中的 `SubscriptionName` 与 Azure 实际名称不一致，脚本会拒绝继续，请改成 Portal 中显示的真实名称。

区域没有配额项：目标区域未提供该模型或该 SKU 组合，请更换区域或模型。

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
