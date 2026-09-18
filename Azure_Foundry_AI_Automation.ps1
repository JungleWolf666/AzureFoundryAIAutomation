<#
.SYNOPSIS
    Azure Foundry AI 一站式全生命周期统一脚本：创建 Azure 订阅、创建 Foundry 服务和项目、批量部署模型、批量扩容配额。

.DESCRIPTION
    四个阶段的参数全部来自同一个 CSV，避免在多个脚本中重复维护配置。
    不带 -Stage 参数运行时进入交互式菜单。

.NOTES
    运行前提：
        1. PowerShell 7+（推荐）或 Windows PowerShell 5.1。
        2. 已安装 Azure CLI（az），且可在当前终端直接调用。
        3. 不依赖 jq / python3 / Az PowerShell 模块。
#>
[CmdletBinding()]
param(
    [string]$TenantId,
    [ValidateSet('CreateSubscription', 'CreateFoundry', 'DeployModels', 'ScaleUpQuota', 'All')]
    [string]$Stage,
    [string]$Csv = (Join-Path $PSScriptRoot 'Azure_Foundry_AI_Plan.csv'),
    [string]$OutputRoot = $PSScriptRoot,
    [int]$CreateDelaySeconds = 10,
    [switch]$DryRun,
    [switch]$BrowserLogin,
    [switch]$Version,
    [switch]$Help
)

$ScriptVersion = '1.0.2'

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CreateDelayExplicit = $PSBoundParameters.ContainsKey('CreateDelaySeconds')

$ExpectedColumns = @(
    'BillingAccountName',
    'EnrollmentAccountName',
    'SubscriptionName',
    'SubscriptionId',
    'ResourceGroupName',
    'FoundryResourceName',
    'DefaultProjectName',
    'Location',
    'ModelNames',
    'ModelVersion',
    'ModelFormat',
    'DeploymentType',
    'DeploymentCapacityK'
)

if ($Help) {
    @"
用法：
  # 1. 交互式菜单（推荐）：
  .\Azure_Foundry_AI_Automation.ps1 -TenantId <TENANT-ID>

  # 2. 单独运行各阶段（预演模式 -DryRun，不修改 Azure 资源）：
  .\Azure_Foundry_AI_Automation.ps1 -TenantId <TENANT-ID> -Stage CreateSubscription -DryRun
  .\Azure_Foundry_AI_Automation.ps1 -TenantId <TENANT-ID> -Stage CreateFoundry      -DryRun
  .\Azure_Foundry_AI_Automation.ps1 -TenantId <TENANT-ID> -Stage DeployModels       -DryRun
  .\Azure_Foundry_AI_Automation.ps1 -TenantId <TENANT-ID> -Stage ScaleUpQuota       -DryRun

  # 3. 单独正式执行各阶段（去掉 -DryRun，需输入大写 YES 确认）：
  .\Azure_Foundry_AI_Automation.ps1 -TenantId <TENANT-ID> -Stage CreateSubscription
  .\Azure_Foundry_AI_Automation.ps1 -TenantId <TENANT-ID> -Stage CreateFoundry
  .\Azure_Foundry_AI_Automation.ps1 -TenantId <TENANT-ID> -Stage DeployModels
  .\Azure_Foundry_AI_Automation.ps1 -TenantId <TENANT-ID> -Stage ScaleUpQuota

  # 4. 全流程依次执行阶段 1 -> 2 -> 3：
  .\Azure_Foundry_AI_Automation.ps1 -TenantId <TENANT-ID> -Stage All -DryRun
  .\Azure_Foundry_AI_Automation.ps1 -TenantId <TENANT-ID> -Stage All

参数：
  -TenantId GUID   客户 Microsoft Entra 租户 ID。必填。
  -Stage           指定阶段，省略时进入交互式菜单。可选值：
                     CreateSubscription  阶段 1：创建 Azure 订阅并回填 SubscriptionId【仅限 EA，CSP 请勿运行，见下方提示】
                     CreateFoundry       阶段 2：创建资源组、Foundry 服务和 Foundry 项目
                     DeployModels        阶段 3：按剩余配额批量部署 CSV 中的模型
                     ScaleUpQuota        阶段 4：把已有部署的容量扩到剩余配额上限
                     All                 全流程：依次执行前三个阶段（1 -> 2 -> 3），阶段 1 同样仅限 EA

【EA / CSP 提示】阶段 1（含 All 里的阶段 1）通过 Microsoft.Subscription/aliases API 自助创建订阅，
只有 EA 企业协议订阅有权限调用。CSP 合作伙伴管理的订阅（尤其是 HK CSP T1）
没有权限自行创建订阅，订阅必须由合作伙伴（Partner）在 Partner Center 中创建后交付 SubscriptionId。
此类订阅请勿运行阶段 1 / All，应直接从阶段 2（CreateFoundry）开始，把合作伙伴提供的 SubscriptionId
手工填入 CSV 的 SubscriptionId 列。运行阶段 1 时脚本会额外要求输入 EA 二次确认。
  -Csv PATH        规划 CSV 路径，默认同目录 Azure_Foundry_AI_Plan.csv。
  -OutputRoot PATH logs/results 输出根目录，默认脚本所在目录。
  -CreateDelaySeconds N 阶段 1 中每创建一个订阅后的等待秒数，用于缓解租户级限流。
                        不指定时按待创建数量自动选择：<=20 个用 10 秒，21-50 个用 20 秒，>50 个用 30 秒。
  -DryRun          只显示将执行的动作，不创建或修改任何 Azure 资源。
  -BrowserLogin    使用浏览器登录；默认使用设备码登录。
  -Help            显示本帮助。

注：Windows PowerShell/pwsh 必须带 .\ 前缀（当前目录不在命令搜索路径中），不能只写文件名。

CSV 列（顺序必须一致）：
  $($ExpectedColumns -join ',')

ModelNames 支持分号分隔，每项可写 name、name:version、name:version:format 或 name:version:format:sku，
例如：gpt-5.6-sol;gpt-image-2:2026-04-21;FW-GLM-5.2:::DataZoneStandard
也可使用 deployment_name=model:version:format:sku 指定与模型名不同的部署名，
例如：gpt-5.6-sol-dz=gpt-5.6-sol:::DataZoneStandard。
省略的部分回退到该行的 ModelVersion / ModelFormat / DeploymentType。
同一个订阅/账户可在 CSV 中写多行（如分别配置 GlobalStandard 和 DataZoneStandard）。
DeploymentCapacityK 留空表示自动使用剩余配额；填数字表示固定容量（单位 K TPM）。
"@ | Write-Host
    exit 0
}

if ($Version) {
    Write-Output "Azure Foundry AI Automation v$ScriptVersion"
    exit 0
}

# ==================== 运行时与日志 ====================

function Initialize-Runtime {
    $script:RunId = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:LogDir = Join-Path $OutputRoot 'logs'
    $script:ResultDir = Join-Path $OutputRoot 'results'
    New-Item -ItemType Directory -Path $script:LogDir, $script:ResultDir -Force | Out-Null
    $script:LogFile = Join-Path $script:LogDir ("azure_foundry_ai_automation_{0}.log" -f $script:RunId)
    Set-Content -Path $script:LogFile -Value '' -Encoding UTF8
}

function Write-Log {
    param([string]$Level, [string]$Message)
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    if ($Level -eq 'ERROR') { [Console]::Error.WriteLine($line) } else { Write-Host $line }
}

function Write-Info { param([string]$Message) Write-Log 'INFO' $Message }
function Write-Warn { param([string]$Message) Write-Log 'WARN' $Message }
function Write-Err { param([string]$Message) Write-Log 'ERROR' $Message }

# ==================== Azure CLI 封装 ====================

function Invoke-AzRaw {
    param([string[]]$Arguments, [switch]$AllowFailure)
    $output = & az @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { "$($_)" }) -join "`n"
    if (-not $AllowFailure -and $exitCode -ne 0) { throw $text }
    [pscustomobject]@{ ExitCode = $exitCode; Text = $text }
}

# Azure API 返回的字段会随版本变化，严格模式下直接取值会抛错，统一走安全读取。
function Get-Prop {
    param([object]$Object, [string]$Path, $Default = '')
    $current = $Object
    foreach ($segment in ($Path -split '\.')) {
        if ($null -eq $current) { return $Default }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) { return $Default }
        $current = $property.Value
    }
    if ($null -eq $current) { return $Default }
    $current
}

function Invoke-AzJson {
    param([string[]]$Arguments)
    $result = Invoke-AzRaw -Arguments ($Arguments + @('--output', 'json', '--only-show-errors'))
    if ([string]::IsNullOrWhiteSpace($result.Text)) { return $null }
    $result.Text | ConvertFrom-Json
}

function Invoke-AzRest {
    param([string]$Method, [string]$Url, [string]$BodyPath = '')
    $arguments = @('rest', '--method', $Method, '--url', $Url, '--output', 'json', '--only-show-errors')
    if (-not [string]::IsNullOrWhiteSpace($BodyPath)) { $arguments += @('--body', "@$BodyPath") }
    Invoke-AzRaw -Arguments $arguments -AllowFailure
}

function Test-ThrottledError {
    param([string]$Message)
    $Message -match '(?i)(^|[^0-9])429([^0-9]|$)|TooManyRequests|Too many requests|RateLimitExceeded|throttl|excessive volume of traffic'
}

function Get-RetryAfterSeconds {
    param([string]$Message, [int]$Attempt)
    if ($Message -match '(?i)retry[-\s]?after[^0-9]{0,12}(\d+)') {
        $advertised = [int]$Matches[1]
        if ($advertised -gt 0) { return [math]::Min($advertised, 300) }
    }
    [math]::Min([int][math]::Pow(2, $Attempt) * 5, 120)
}

# 订阅别名创建是租户级写操作，Azure 按租户令牌桶限流，429 需按 Retry-After 退避重试。
function Invoke-AzRestWithRetry {
    param([string]$Method, [string]$Url, [string]$BodyPath = '', [int]$MaxAttempts = 6)
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $result = Invoke-AzRest -Method $Method -Url $Url -BodyPath $BodyPath
        if ($result.ExitCode -eq 0) { return $result }
        if ($attempt -ge $MaxAttempts -or -not (Test-ThrottledError -Message $result.Text)) { return $result }
        $wait = Get-RetryAfterSeconds -Message $result.Text -Attempt $attempt
        Write-Warn "  请求被限流（第 $attempt/$MaxAttempts 次），等待 $wait 秒后重试。"
        Start-Sleep -Seconds $wait
    }
}

function Confirm-Environment {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw '未找到 Azure CLI，请先安装 az 并重新打开终端。' }
    if ([string]::IsNullOrWhiteSpace($TenantId)) { throw '-TenantId 为必填参数。' }
    if ($TenantId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw '-TenantId 必须是真实的 Microsoft Entra 租户 GUID，请替换 <TENANT-ID> 占位符。'
    }
}

function Invoke-AzLogin {
    $arguments = @('login', '--tenant', $TenantId, '--allow-no-subscriptions', '--output', 'none')
    if (-not $BrowserLogin) { $arguments += '--use-device-code' }
    Write-Info "登录租户 $TenantId"
    & az @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Azure CLI 登录失败。若在企业代理环境，请先配置受信任的根证书。' }
}

# ==================== CSV 处理 ====================

function Import-Plan {
    param([string]$Phase)

    if (-not (Test-Path -LiteralPath $Csv -PathType Leaf)) { throw "CSV 文件不存在：$Csv" }
    $headerLine = Get-Content -LiteralPath $Csv -TotalCount 1
    $headerLine = [string]$headerLine -replace "^\uFEFF", ''
    # Excel 和 Export-Csv 会给表头加引号，比对前先去掉引号和空白。
    $headerColumns = @(($headerLine -split ',') | ForEach-Object { $_.Trim().Trim('"').Trim() })
    if (($headerColumns -join ',') -ne ($ExpectedColumns -join ',')) {
        throw "CSV 列必须严格为：$($ExpectedColumns -join ',')"
    }

    $rows = @(Import-Csv -LiteralPath $Csv)
    if ($rows.Count -eq 0) { throw 'CSV 中没有数据行。' }

    $required = switch ($Phase) {
        'CreateSubscription' { @('BillingAccountName', 'EnrollmentAccountName', 'SubscriptionName') }
        'CreateFoundry' { @('SubscriptionName', 'SubscriptionId', 'ResourceGroupName', 'FoundryResourceName', 'DefaultProjectName', 'Location') }
        default { @('SubscriptionName', 'SubscriptionId', 'ResourceGroupName', 'FoundryResourceName', 'ModelNames') }
    }

    $rowNumber = 1
    $foundryMeta = @{}
    $subscriptionMeta = @{}
    foreach ($row in $rows) {
        $rowNumber++
        foreach ($field in $ExpectedColumns) {
            $value = [string]$row.$field
            if ($value -ne $value.Trim()) { throw "第 $rowNumber 行：$field 存在首尾空格。" }
            if ($value.Contains('|')) { throw "第 $rowNumber 行：$field 不能包含竖线字符。" }
        }
        foreach ($field in $required) {
            if ([string]::IsNullOrWhiteSpace([string]$row.$field)) { throw "第 $rowNumber 行：$Phase 阶段需要填写 $field。" }
        }
        foreach ($field in @('BillingAccountName', 'EnrollmentAccountName')) {
            if (([string]$row.$field).Contains('/')) { throw "第 $rowNumber 行：$field 应填资源名称，而不是完整资源 ID。" }
        }

        $subscriptionName = [string]$row.SubscriptionName
        $billing = [string]$row.BillingAccountName
        $enrollment = [string]$row.EnrollmentAccountName
        if (-not [string]::IsNullOrWhiteSpace($subscriptionName)) {
            if ($subscriptionMeta.ContainsKey($subscriptionName)) {
                $prev = $subscriptionMeta[$subscriptionName]
                if ($prev.Billing -ne $billing -or $prev.Enrollment -ne $enrollment) {
                    throw "第 $rowNumber 行：SubscriptionName「$subscriptionName」在其他行已配置了不同的计费账户或登记账户。"
                }
            } else {
                $subscriptionMeta[$subscriptionName] = @{ Billing = $billing; Enrollment = $enrollment }
            }
        }

        $subscriptionId = [string]$row.SubscriptionId
        if (-not [string]::IsNullOrWhiteSpace($subscriptionId)) { [void][guid]::Parse($subscriptionId) }

        $foundryName = [string]$row.FoundryResourceName
        $rg = ([string]$row.ResourceGroupName).ToLowerInvariant()
        $subIdKey = if (-not [string]::IsNullOrWhiteSpace($subscriptionId)) { $subscriptionId.ToLowerInvariant() } else { '' }
        $loc = ([string]$row.Location).ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($foundryName)) {
            if ($foundryName -notmatch '^[a-z0-9][a-z0-9-]{0,62}[a-z0-9]$') {
                throw "第 $rowNumber 行：FoundryResourceName '$foundryName' 必须为 2-64 位小写字母、数字或连字符，且以字母或数字开头结尾。"
            }
            $foundryKey = "$subIdKey|$rg|$($foundryName.ToLowerInvariant())"
            if ($foundryMeta.ContainsKey($foundryKey)) {
                if ($foundryMeta[$foundryKey] -ne $loc) {
                    throw "第 $rowNumber 行：FoundryResourceName '$foundryName' 在同一资源组中已配置了不同的区域。"
                }
            } else {
                $foundryMeta[$foundryKey] = $loc
            }
        }
    }
    $rows
}

# ModelNames 支持分号分隔，每项支持：
#   model
#   deployment_name=model
#   model:version
#   model:version:format
#   model:version:format:sku
#   deployment_name=model:version:format:sku
function Expand-ModelSpec {
    param([object]$Row)
    $specs = New-Object System.Collections.Generic.List[object]
    $defaultVersion = [string]$Row.ModelVersion
    # 兼容处理 2026/7/9 或 2026/07/09 为标准 ISO 8601 格式 2026-07-09
    if ($defaultVersion -match '^\d{4}/\d{1,2}/\d{1,2}$') {
        $parts = $defaultVersion.Split('/')
        $defaultVersion = "{0}-{1:D2}-{2:D2}" -f [int]$parts[0], [int]$parts[1], [int]$parts[2]
    }
    $defaultSku = if (-not [string]::IsNullOrWhiteSpace([string]$Row.DeploymentType)) { [string]$Row.DeploymentType } else { 'GlobalStandard' }
    foreach ($item in ([string]$Row.ModelNames -split ';')) {
        $trimmed = $item.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }

        $deploymentName = ''
        $modelPart = $trimmed
        if ($trimmed.Contains('=')) {
            $eqParts = $trimmed.Split('=', 2)
            $deploymentName = $eqParts[0].Trim()
            $modelPart = $eqParts[1].Trim()
        }

        $parts = $modelPart -split ':'
        $name = $parts[0].Trim()
        if ([string]::IsNullOrWhiteSpace($deploymentName)) { $deploymentName = $name }

        $version = if ($parts.Count -ge 2 -and -not [string]::IsNullOrWhiteSpace($parts[1])) { $parts[1].Trim() } else { $defaultVersion }
        if ($version -match '^\d{4}/\d{1,2}/\d{1,2}$') {
            $vParts = $version.Split('/')
            $version = "{0}-{1:D2}-{2:D2}" -f [int]$vParts[0], [int]$vParts[1], [int]$vParts[2]
        }
        $format = if ($parts.Count -ge 3 -and -not [string]::IsNullOrWhiteSpace($parts[2])) { $parts[2].Trim() } else { [string]$Row.ModelFormat }
        if ([string]::IsNullOrWhiteSpace($format)) { $format = 'OpenAI' }
        $sku = if ($parts.Count -ge 4 -and -not [string]::IsNullOrWhiteSpace($parts[3])) { $parts[3].Trim() } else { $defaultSku }
        $specs.Add([pscustomobject]@{
            DeploymentName = $deploymentName
            Name           = $name
            Version        = $version
            Format         = $format
            Sku            = $sku
        })
    }
    # PowerShell 7 对 List[object] 使用 @() 会抛类型错误，统一返回原生数组。
    $specs.ToArray()
}

function Get-DeploymentType {
    param([object]$Row)
    $value = [string]$Row.DeploymentType
    if ([string]::IsNullOrWhiteSpace($value)) { return 'GlobalStandard' }
    $value
}

function ConvertTo-CsvField {
    param([string]$Value)
    if ($Value -match '[",\r\n]') { return '"' + $Value.Replace('"', '""') + '"' }
    $Value
}

# Export-Csv 会给每个字段都加引号，回写后表头变成 "BillingAccountName",... 导致后续阶段校验失败，这里只在必要时加引号。
function Write-PlanCsv {
    param([object[]]$Rows)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add(($ExpectedColumns -join ','))
    foreach ($row in $Rows) {
        $fields = foreach ($column in $ExpectedColumns) { ConvertTo-CsvField -Value ([string]$row.$column) }
        $lines.Add(($fields -join ','))
    }
    Set-Content -LiteralPath $Csv -Value $lines.ToArray() -Encoding UTF8
}

function Save-ResultCsv {
    param([string]$Name, [object[]]$Rows)
    if ($Rows.Count -eq 0) { return }
    $path = Join-Path $script:ResultDir ("{0}_{1}.csv" -f $Name, $script:RunId)
    $Rows | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
    Write-Info "结果文件：$path"
}

function Update-PlanSubscriptionId {
    param([object[]]$Rows, [string]$SubscriptionName, [string]$SubscriptionId)
    $csvDirectory = Split-Path -Parent $Csv
    $backupDirectory = Join-Path $csvDirectory 'csv_backups'
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    $backupName = "{0}.bak.{1}" -f (Split-Path -Leaf $Csv), (Get-Date -Format 'yyyyMMdd_HHmmss_ffffff')
    $backup = Join-Path $backupDirectory $backupName
    Copy-Item -LiteralPath $Csv -Destination $backup -Force
    foreach ($row in $Rows) {
        if ($row.SubscriptionName -eq $SubscriptionName) { $row.SubscriptionId = $SubscriptionId }
    }
    Write-PlanCsv -Rows $Rows
}

function Confirm-Execution {
    param([string]$Message)
    if ($DryRun) { return $true }
    $answer = Read-Host "$Message，输入大写 YES 继续"
    if ($answer -ne 'YES') {
        Write-Warn '用户取消操作。'
        return $false
    }
    $true
}

# 阶段 1（创建订阅）仅适用于 EA 企业协议订阅；CSP 合作伙伴管理的订阅必须由合作伙伴创建。
function Confirm-EaOnlyStage {
    Write-Host ''
    Write-Host '========================================================'
    Write-Host '⚠️  重要提示：阶段 1 仅适用于 EA 企业协议订阅  ⚠️'
    Write-Host '========================================================'
    Write-Host ''
    Write-Host '  - 如果您的订阅由 CSP 合作伙伴管理，请不要运行阶段 1。'
    Write-Host '  - 请先联系合作伙伴创建订阅，并将获得的 SubscriptionId 填入 CSV，'
    Write-Host '    然后直接从阶段 2（CreateFoundry）开始执行。'
    Write-Host '  - 运行前如无法确认协议类型，请联系贵司 Azure 管理员或服务合作伙伴。'
    Write-Host ''
    if ($DryRun) { return $true }
    $answer = Read-Host '请确认当前订阅为 EA 企业协议、且有权限自助创建订阅，输入大写 EA 继续（其他任何输入将取消本阶段）'
    if ($answer -ne 'EA') {
        Write-Warn '未确认 EA 协议身份，已取消阶段 1。'
        return $false
    }
    $true
}

# ==================== 公共 Azure 辅助 ====================

function Format-Capacity {
    param([int]$CapacityK)
    if ($CapacityK -lt 1000) { return "$CapacityK K" }
    "{0:0.###} M" -f ($CapacityK / 1000.0)
}

function Resolve-Subscription {
    param([object]$Row, [object[]]$Accounts)
    $subscriptionId = [string]$Row.SubscriptionId
    $match = @($Accounts | Where-Object { ([string](Get-Prop $_ 'id')).ToLowerInvariant() -eq $subscriptionId.ToLowerInvariant() }) | Select-Object -First 1
    if (-not $match) { throw "订阅 '$subscriptionId' 对当前登录账号不可见。" }
    $actualName = [string](Get-Prop $match 'name')
    if ($actualName -ne [string]$Row.SubscriptionName) {
        throw "SubscriptionId '$subscriptionId' 实际属于订阅 '$actualName'，与 CSV 中的 SubscriptionName '$($Row.SubscriptionName)' 不一致。"
    }
    $actualTenant = [string](Get-Prop $match 'tenantId')
    if ($actualTenant.ToLowerInvariant() -ne $TenantId.ToLowerInvariant()) {
        throw "订阅属于租户 $actualTenant，与 -TenantId $TenantId 不一致。"
    }
    Invoke-AzRaw -Arguments @('account', 'set', '--subscription', $subscriptionId, '--only-show-errors') | Out-Null
    $match
}

function Get-AccountLocation {
    param([object]$Row)
    $result = Invoke-AzRaw -Arguments @('cognitiveservices', 'account', 'show', '--resource-group', [string]$Row.ResourceGroupName, '--name', [string]$Row.FoundryResourceName, '--query', 'location', '-o', 'tsv', '--only-show-errors') -AllowFailure
    if ($result.ExitCode -ne 0) { throw "无法读取 Foundry 账户区域：$($result.Text)" }
    $result.Text.Trim()
}

# currentValue 是共享配额范围的总分配量，可能包含同区域其他账户的部署。
function Get-Quota {
    param([string]$SubscriptionId, [string]$Location, [string]$ModelName, [string]$SkuName)
    $cacheKey = "$SubscriptionId|$Location|$ModelName|$SkuName"
    if ($script:QuotaCache.ContainsKey($cacheKey)) { return $script:QuotaCache[$cacheKey] }

    $usage = @(Invoke-AzJson -Arguments @('cognitiveservices', 'usage', 'list', '--location', $Location))
    $candidates = @()
    if ($ModelName -like 'FW-*') { $candidates += "AIServices.$SkuName.Fireworks" }
    $candidates += "AIServices.$SkuName.$ModelName"
    $candidates += "OpenAI.$SkuName.$ModelName"

    foreach ($key in $candidates) {
        $match = $usage | Where-Object { [string](Get-Prop $_ 'name.value') -eq $key } | Select-Object -First 1
        if ($null -ne $match) {
            $value = [pscustomobject]@{
                Total     = [int][math]::Floor([double](Get-Prop $match 'limit' 0))
                Allocated = [int][math]::Floor([double](Get-Prop $match 'currentValue' 0))
                Found     = $true
            }
            $script:QuotaCache[$cacheKey] = $value
            return $value
        }
    }

    $value = [pscustomobject]@{ Total = 0; Allocated = 0; Found = $false }
    $script:QuotaCache[$cacheKey] = $value
    $value
}

function Get-ExistingDeployments {
    param([object]$Row)
    $items = @(Invoke-AzJson -Arguments @('cognitiveservices', 'account', 'deployment', 'list', '--resource-group', [string]$Row.ResourceGroupName, '--name', [string]$Row.FoundryResourceName))
    @($items | ForEach-Object {
            [pscustomobject]@{
                DeploymentName = [string](Get-Prop $_ 'name')
                ModelName      = [string](Get-Prop $_ 'properties.model.name')
                ModelFormat    = [string](Get-Prop $_ 'properties.model.format')
                ModelVersion   = [string](Get-Prop $_ 'properties.model.version')
                SkuName        = [string](Get-Prop $_ 'sku.name')
                CapacityK      = [int](Get-Prop $_ 'sku.capacity' 0)
            }
        })
}

function Set-Deployment {
    param([object]$Row, [string]$DeploymentName, [string]$ModelName, [string]$ModelVersion, [string]$ModelFormat, [string]$SkuName, [int]$CapacityK)
    $arguments = @(
        'cognitiveservices', 'account', 'deployment', 'create',
        '--resource-group', [string]$Row.ResourceGroupName,
        '--name', [string]$Row.FoundryResourceName,
        '--deployment-name', $DeploymentName,
        '--model-name', $ModelName,
        '--model-format', $ModelFormat,
        '--sku-name', $SkuName,
        '--sku-capacity', "$CapacityK",
        '--only-show-errors'
    )
    if (-not [string]::IsNullOrWhiteSpace($ModelVersion)) { $arguments += @('--model-version', $ModelVersion) }
    if ($DryRun) {
        Write-Info "[DRY-RUN] az $($arguments -join ' ')"
        return
    }
    $result = Invoke-AzRaw -Arguments $arguments -AllowFailure
    if ($result.ExitCode -ne 0) { throw $result.Text }
}

# ==================== 交付清单 ====================

# 三个端点共用账户级 key1，主机名由自定义子域决定。
function Get-AccountEndpoints {
    param([object]$Row)
    $account = Invoke-AzJson -Arguments @('cognitiveservices', 'account', 'show', '--resource-group', [string]$Row.ResourceGroupName, '--name', [string]$Row.FoundryResourceName)
    $subDomain = [string](Get-Prop $account 'properties.customSubDomainName')
    if ([string]::IsNullOrWhiteSpace($subDomain)) { $subDomain = [string]$Row.FoundryResourceName }
    [pscustomobject]@{
        OpenAIEndpoint   = "https://$subDomain.openai.azure.com/"
        ProjectEndpoint  = "https://$subDomain.services.ai.azure.com/api/projects/$([string]$Row.DefaultProjectName)"
        ServicesEndpoint = "https://$subDomain.cognitiveservices.azure.com/"
    }
}

function Get-AccountApiKey {
    param([object]$Row)
    $result = Invoke-AzRaw -Arguments @('cognitiveservices', 'account', 'keys', 'list', '--resource-group', [string]$Row.ResourceGroupName, '--name', [string]$Row.FoundryResourceName, '--query', 'key1', '-o', 'tsv', '--only-show-errors') -AllowFailure
    if ($result.ExitCode -ne 0) {
        Write-Warn "  无法读取 $($Row.FoundryResourceName) 的 API Key，需要 Microsoft.CognitiveServices/accounts/listKeys/action 权限，该列留空。"
        return ''
    }
    $result.Text.Trim()
}

function Confirm-IncludeApiKey {
    Write-Host ''
    Write-Host 'API Key 是明文长期凭据，一旦泄露即可直接调用该 Foundry 资源。'
    Write-Host '默认不导出。仅在需要交付给项目负责人时才导出，并通过安全渠道传递。'
    $answer = Read-Host '是否在交付清单中包含 API Key？输入大写 KEY 表示包含，其他任意输入表示不包含'
    $answer -ceq 'KEY'
}

# 按 订阅 + Foundry 账户 + 项目 去重，每个项目输出一行。
function Save-DeliveryReport {
    param([object[]]$Rows, [object[]]$Accounts)
    if ($Rows.Count -eq 0) { return }
    if ($DryRun) { Write-Info '预演模式不生成交付清单。'; return }

    $includeKey = Confirm-IncludeApiKey
    if ($includeKey) { Write-Info '交付清单将包含 API Key。' } else { Write-Info '交付清单不包含 API Key。' }

    $report = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($row in $Rows) {
        $projectKey = '{0}|{1}|{2}|{3}' -f ([string]$row.SubscriptionId).ToLowerInvariant(), ([string]$row.ResourceGroupName).ToLowerInvariant(), ([string]$row.FoundryResourceName).ToLowerInvariant(), ([string]$row.DefaultProjectName).ToLowerInvariant()
        if ($seen.ContainsKey($projectKey)) { continue }
        $seen[$projectKey] = $true
        try {
            Resolve-Subscription -Row $row -Accounts $Accounts | Out-Null
            $endpoints = Get-AccountEndpoints -Row $row
            $deployments = @(Get-ExistingDeployments -Row $row)
            $modelText = (@($deployments | ForEach-Object { '{0}({1}, {2}, {3}K)' -f $_.DeploymentName, $_.ModelName, $_.SkuName, $_.CapacityK }) -join '; ')
            $apiKey = if ($includeKey) { Get-AccountApiKey -Row $row } else { '' }
            $report.Add([pscustomobject]@{
                    SubscriptionName    = $row.SubscriptionName
                    SubscriptionId      = $row.SubscriptionId
                    ResourceGroupName   = $row.ResourceGroupName
                    FoundryResourceName = $row.FoundryResourceName
                    ProjectName         = $row.DefaultProjectName
                    Location            = $row.Location
                    DeploymentCount     = $deployments.Count
                    DeployedModels      = $modelText
                    OpenAIEndpoint      = $endpoints.OpenAIEndpoint
                    ProjectEndpoint     = $endpoints.ProjectEndpoint
                    ServicesEndpoint    = $endpoints.ServicesEndpoint
                    ApiKey              = $apiKey
                })
        }
        catch {
            Write-Err "生成交付清单失败（$($row.FoundryResourceName)）：$($_.Exception.Message)"
        }
    }

    if ($report.Count -eq 0) { Write-Warn '没有可写入交付清单的项目。'; return }

    $deliveryDir = Join-Path $OutputRoot 'delivery_reports'
    New-Item -ItemType Directory -Path $deliveryDir -Force | Out-Null
    $suffix = if ($includeKey) { '_WITH_KEY' } else { '' }
    $path = Join-Path $deliveryDir ("foundry_endpoints_{0}{1}.csv" -f $script:RunId, $suffix)
    $report.ToArray() | Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
    Write-Info "交付清单：$path"
    if ($includeKey) { Write-Warn '该文件包含明文 API Key，请通过安全渠道传递，交付后及时删除本地副本。' }
}

# ==================== 阶段 1：创建 EA 订阅 ====================

# 订阅越多，累计租户级写请求越容易触发限流，未显式指定时按批量规模自动取间隔。
function Get-CreateDelaySeconds {
    param([int]$PendingCount)
    if ($script:CreateDelayExplicit) { return $CreateDelaySeconds }
    if ($PendingCount -gt 50) { return 30 }
    if ($PendingCount -gt 20) { return 20 }
    10
}

function Test-FatalBillingError {
    param([string]$Message)
    $Message -match 'Permission|Forbidden|UserNotAuthorized|AuthorizationFailed|InvalidBillingScope|EnrollmentAccount'
}

function Wait-AliasProvisioning {
    param([string]$Url, [string]$SubscriptionName)
    $started = Get-Date
    while ($true) {
        $result = Invoke-AzRestWithRetry -Method 'GET' -Url $Url
        if ($result.ExitCode -ne 0) { throw $result.Text }
        $object = $result.Text | ConvertFrom-Json
        $state = [string](Get-Prop $object 'properties.provisioningState')
        if ($state -eq 'Succeeded') { return $object }
        if ($state -in @('Failed', 'Canceled', 'Deleted')) { throw "订阅 '$SubscriptionName' 进入终止状态 $state" }
        if (((Get-Date) - $started).TotalSeconds -ge 900) { throw "订阅 '$SubscriptionName' 创建超时，最后状态为 $state" }
        Start-Sleep -Seconds 15
    }
}

function Invoke-StageCreateSubscription {
    Write-Info '========== 阶段：创建 Azure 订阅 =========='
    if (-not (Confirm-EaOnlyStage)) { Write-Info '已跳过阶段 1。'; return $true }
    $rows = @(Import-Plan -Phase 'CreateSubscription')
    $accounts = @(Invoke-AzJson -Arguments @('account', 'list', '--all'))
    $pending = @($rows | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.SubscriptionId) })

    Write-Info "待创建订阅数：$($pending.Count)"
    foreach ($row in $rows) {
        if (-not [string]::IsNullOrWhiteSpace([string]$row.SubscriptionId)) {
            Write-Host ("  [SKIP]   {0} -> {1}" -f $row.SubscriptionName, $row.SubscriptionId)
        }
        else {
            Write-Host ("  [CREATE] {0} | billingAccount={1} | enrollmentAccount={2}" -f $row.SubscriptionName, $row.BillingAccountName, $row.EnrollmentAccountName)
        }
    }
    if ($pending.Count -eq 0) { Write-Info '没有需要创建的订阅。'; return $true }
    $delaySeconds = Get-CreateDelaySeconds -PendingCount $pending.Count
    Write-Info "每创建一个订阅后等待 $delaySeconds 秒，用于避免租户级限流。"
    if (-not (Confirm-Execution "将创建 $($pending.Count) 个 EA 订阅")) { return $true }

    $results = New-Object System.Collections.Generic.List[object]
    $ok = $true
    foreach ($row in $rows) {
        if (-not [string]::IsNullOrWhiteSpace([string]$row.SubscriptionId)) {
            $results.Add([pscustomobject]@{ SubscriptionName = $row.SubscriptionName; SubscriptionId = $row.SubscriptionId; AliasName = ''; Status = 'SkippedExisting'; ErrorMessage = '' })
            continue
        }
        if (@($accounts | Where-Object { [string]$_.name -eq [string]$row.SubscriptionName }).Count -gt 0) {
            $message = '已存在同名的可访问订阅，但 CSV 中 SubscriptionId 为空，不做猜测。'
            Write-Err "$($row.SubscriptionName): $message"
            $results.Add([pscustomobject]@{ SubscriptionName = $row.SubscriptionName; SubscriptionId = ''; AliasName = ''; Status = 'AmbiguousExisting'; ErrorMessage = $message })
            $ok = $false
            continue
        }
        if ($DryRun) {
            Write-Info "[DRY-RUN] 将创建订阅 '$($row.SubscriptionName)'"
            $results.Add([pscustomobject]@{ SubscriptionName = $row.SubscriptionName; SubscriptionId = ''; AliasName = ''; Status = 'WhatIf'; ErrorMessage = '' })
            continue
        }

        $aliasName = 'ea-' + [guid]::NewGuid().ToString()
        $aliasUrl = "https://management.azure.com/providers/Microsoft.Subscription/aliases/$aliasName`?api-version=2021-10-01"
        $bodyPath = Join-Path ([System.IO.Path]::GetTempPath()) "$aliasName.json"
        $billingScope = "/providers/Microsoft.Billing/billingAccounts/$($row.BillingAccountName)/enrollmentAccounts/$($row.EnrollmentAccountName)"
        [pscustomobject]@{ properties = [pscustomobject]@{ billingScope = $billingScope; displayName = [string]$row.SubscriptionName; workload = 'Production' } } |
            ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $bodyPath -Encoding UTF8

        try {
            Write-Info "创建订阅 '$($row.SubscriptionName)'（billingAccount=$($row.BillingAccountName)，enrollmentAccount=$($row.EnrollmentAccountName)）"
            $created = Invoke-AzRestWithRetry -Method 'PUT' -Url $aliasUrl -BodyPath $bodyPath
            if ($created.ExitCode -ne 0) { throw $created.Text }
            $response = $created.Text | ConvertFrom-Json
            if ([string](Get-Prop $response 'properties.provisioningState') -ne 'Succeeded') {
                $response = Wait-AliasProvisioning -Url $aliasUrl -SubscriptionName $row.SubscriptionName
            }
            $newId = [string](Get-Prop $response 'properties.subscriptionId')
            if ([string]::IsNullOrWhiteSpace($newId)) { throw '订阅创建成功但未返回 SubscriptionId。' }
            Update-PlanSubscriptionId -Rows $rows -SubscriptionName ([string]$row.SubscriptionName) -SubscriptionId $newId
            Write-Info "订阅 '$($row.SubscriptionName)' 创建完成，ID=$newId"
            $results.Add([pscustomobject]@{ SubscriptionName = $row.SubscriptionName; SubscriptionId = $newId; AliasName = $aliasName; Status = 'Succeeded'; ErrorMessage = '' })
        }
        catch {
            $message = "$($_.Exception.Message)"
            Write-Err "$($row.SubscriptionName): $message"
            $results.Add([pscustomobject]@{ SubscriptionName = $row.SubscriptionName; SubscriptionId = ''; AliasName = $aliasName; Status = 'Failed'; ErrorMessage = $message })
            $ok = $false
            if (Test-FatalBillingError -Message $message) {
                Write-Err '计费或权限错误，停止本阶段。'
                break
            }
        }
        finally {
            Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
        }

        # 批量创建时主动限速，避免触发租户级写限流。
        if ($delaySeconds -gt 0) { Start-Sleep -Seconds $delaySeconds }
    }

    Save-ResultCsv -Name 'stage1_subscription_creation' -Rows $results.ToArray()
    $ok
}

# ==================== 阶段 2：创建 Foundry 资源 ====================

function Wait-ArmProvisioning {
    param([string]$Description, [string]$Url)
    $started = Get-Date
    while ($true) {
        $result = Invoke-AzRestWithRetry -Method 'GET' -Url $Url
        if ($result.ExitCode -ne 0) { throw $result.Text }
        $state = [string](Get-Prop ($result.Text | ConvertFrom-Json) 'properties.provisioningState')
        if ($state -eq 'Succeeded') { Write-Info "$Description 已就绪"; return }
        if ($state -in @('Failed', 'Canceled', 'Deleted')) { throw "$Description 进入终止状态 $state" }
        if (((Get-Date) - $started).TotalSeconds -ge 900) { throw "$Description 超时，最后状态为 $state" }
        Start-Sleep -Seconds 5
    }
}

function Register-CognitiveServicesProvider {
    param([string]$SubscriptionId)
    if ($script:RegisteredProviders.ContainsKey($SubscriptionId)) { return $true }

    $state = [string](Get-Prop (Invoke-AzJson -Arguments @('provider', 'show', '--namespace', 'Microsoft.CognitiveServices')) 'registrationState')
    Write-Info "订阅 $SubscriptionId 的 Microsoft.CognitiveServices 注册状态：$state"
    if ($state -ne 'Registered') {
        if ($DryRun) {
            Write-Info "[DRY-RUN] 将在订阅 $SubscriptionId 中注册 Microsoft.CognitiveServices"
            return $false
        }
        Write-Info "正在订阅 $SubscriptionId 中注册 Microsoft.CognitiveServices"
        Invoke-AzJson -Arguments @('provider', 'register', '--namespace', 'Microsoft.CognitiveServices') | Out-Null
        $started = Get-Date
        while ($true) {
            $state = [string](Get-Prop (Invoke-AzJson -Arguments @('provider', 'show', '--namespace', 'Microsoft.CognitiveServices')) 'registrationState')
            if ($state -eq 'Registered') { break }
            if (((Get-Date) - $started).TotalSeconds -ge 600) { throw "订阅 $SubscriptionId 注册 Microsoft.CognitiveServices 超时。" }
            Start-Sleep -Seconds 5
        }
        Write-Info "订阅 $SubscriptionId 的 Microsoft.CognitiveServices 已注册完成"
    }
    $script:RegisteredProviders[$SubscriptionId] = $true
    $true
}

function Invoke-StageCreateFoundry {
    Write-Info '========== 阶段：创建 Foundry 服务和 Foundry 项目 =========='
    $rows = @(Import-Plan -Phase 'CreateFoundry')
    $accounts = @(Invoke-AzJson -Arguments @('account', 'list', '--all'))

    foreach ($row in $rows) {
        Write-Host ("  {0} | {1} | {2} | {3} | {4} | {5}" -f $row.SubscriptionName, $row.SubscriptionId, $row.ResourceGroupName, $row.FoundryResourceName, $row.DefaultProjectName, $row.Location)
    }
    if (-not (Confirm-Execution "将为 $($rows.Count) 个订阅创建 Foundry 资源")) { return $true }

    $results = New-Object System.Collections.Generic.List[object]
    $ok = $true
    foreach ($row in $rows) {
        $groupStatus = 'Pending'; $foundryStatus = 'Pending'; $projectStatus = 'Pending'; $errorMessage = ''
        $location = [string]$row.Location
        $customDomain = [string]$row.FoundryResourceName

        try {
            Write-Info "检查订阅 '$($row.SubscriptionName)'（$($row.SubscriptionId)）"
            Resolve-Subscription -Row $row -Accounts $accounts | Out-Null

            $locations = @(Invoke-AzJson -Arguments @('account', 'list-locations'))
            if (@($locations | Where-Object { ([string](Get-Prop $_ 'name')).ToLowerInvariant() -eq $location.ToLowerInvariant() }).Count -eq 0) {
                throw "区域 '$location' 在订阅 $($row.SubscriptionId) 中不可用。"
            }

            $providerReady = Register-CognitiveServicesProvider -SubscriptionId ([string]$row.SubscriptionId)

            $groupResult = Invoke-AzRaw -Arguments @('group', 'show', '--name', [string]$row.ResourceGroupName, '--output', 'json', '--only-show-errors') -AllowFailure
            if ($groupResult.ExitCode -eq 0) {
                $existingLocation = [string](Get-Prop ($groupResult.Text | ConvertFrom-Json) 'location')
                if ($existingLocation -and $existingLocation.ToLowerInvariant() -ne $location.ToLowerInvariant()) {
                    throw "资源组 '$($row.ResourceGroupName)' 位于 '$existingLocation'，与目标区域 '$location' 不一致。"
                }
                $groupStatus = 'SkippedExisting'
            }
            elseif ($groupResult.Text -match 'ResourceGroupNotFound') {
                if ($DryRun) { $groupStatus = 'WhatIf' }
                else {
                    Invoke-AzJson -Arguments @('group', 'create', '--name', [string]$row.ResourceGroupName, '--location', $location) | Out-Null
                    $groupStatus = 'Succeeded'
                }
            }
            else { throw $groupResult.Text }

            if (-not $providerReady) {
                $foundryStatus = 'WhatIf'; $projectStatus = 'WhatIf'
                $results.Add([pscustomobject]@{ SubscriptionName = $row.SubscriptionName; SubscriptionId = $row.SubscriptionId; ResourceGroupName = $row.ResourceGroupName; FoundryResourceName = $row.FoundryResourceName; DefaultProjectName = $row.DefaultProjectName; Location = $location; ResourceGroupStatus = $groupStatus; FoundryStatus = $foundryStatus; ProjectStatus = $projectStatus; ErrorMessage = '' })
                continue
            }

            $encodedRg = [uri]::EscapeDataString([string]$row.ResourceGroupName)
            $encodedAccount = [uri]::EscapeDataString([string]$row.FoundryResourceName)
            $encodedProject = [uri]::EscapeDataString([string]$row.DefaultProjectName)
            $accountUrl = "https://management.azure.com/subscriptions/$($row.SubscriptionId)/resourceGroups/$encodedRg/providers/Microsoft.CognitiveServices/accounts/$encodedAccount`?api-version=2025-06-01"
            $projectUrl = "https://management.azure.com/subscriptions/$($row.SubscriptionId)/resourceGroups/$encodedRg/providers/Microsoft.CognitiveServices/accounts/$encodedAccount/projects/$encodedProject`?api-version=2025-06-01"

            $accountGet = Invoke-AzRest -Method 'GET' -Url $accountUrl
            $accountExists = $accountGet.ExitCode -eq 0
            if (-not $accountExists -and $accountGet.Text -notmatch 'ResourceNotFound|NotFound|could not be found') { throw $accountGet.Text }

            if ($accountExists) {
                $account = $accountGet.Text | ConvertFrom-Json
                if ([string](Get-Prop $account 'kind') -ne 'AIServices' -or
                    ([string](Get-Prop $account 'location')).ToLowerInvariant() -ne $location.ToLowerInvariant() -or
                    [string](Get-Prop $account 'properties.customSubDomainName') -ne $customDomain) {
                    throw "Foundry 账户 '$($row.FoundryResourceName)' 已存在但类型、区域或自定义域名不一致。"
                }
                $foundryStatus = 'SkippedExisting'
            }
            elseif ($DryRun) {
                $foundryStatus = 'WhatIf'; $projectStatus = 'WhatIf'
                $results.Add([pscustomobject]@{ SubscriptionName = $row.SubscriptionName; SubscriptionId = $row.SubscriptionId; ResourceGroupName = $row.ResourceGroupName; FoundryResourceName = $row.FoundryResourceName; DefaultProjectName = $row.DefaultProjectName; Location = $location; ResourceGroupStatus = $groupStatus; FoundryStatus = $foundryStatus; ProjectStatus = $projectStatus; ErrorMessage = '' })
                continue
            }
            else {
                $bodyPath = Join-Path ([System.IO.Path]::GetTempPath()) "account-$($row.SubscriptionId).json"
                [pscustomobject]@{
                    location   = $location
                    kind       = 'AIServices'
                    sku        = [pscustomobject]@{ name = 'S0' }
                    identity   = [pscustomobject]@{ type = 'SystemAssigned' }
                    properties = [pscustomobject]@{ customSubDomainName = $customDomain; allowProjectManagement = $true }
                } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $bodyPath -Encoding UTF8
                $created = Invoke-AzRest -Method 'PUT' -Url $accountUrl -BodyPath $bodyPath
                Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
                if ($created.ExitCode -ne 0) {
                    if ($created.Text -match 'CustomDomainInUse') { throw "CustomDomainInUse：'$customDomain' 已被占用，请更换 FoundryResourceName。" }
                    throw $created.Text
                }
                Wait-ArmProvisioning -Description "Foundry 账户 '$($row.FoundryResourceName)'" -Url $accountUrl
                $foundryStatus = 'Succeeded'
            }

            $projectGet = Invoke-AzRest -Method 'GET' -Url $projectUrl
            if ($projectGet.ExitCode -eq 0) {
                $projectStatus = 'SkippedExisting'
            }
            elseif ($projectGet.Text -notmatch 'ResourceNotFound|NotFound|could not be found') { throw $projectGet.Text }
            elseif ($DryRun) { $projectStatus = 'WhatIf' }
            else {
                $bodyPath = Join-Path ([System.IO.Path]::GetTempPath()) "project-$($row.SubscriptionId).json"
                [pscustomobject]@{
                    location   = $location
                    identity   = [pscustomobject]@{ type = 'SystemAssigned' }
                    properties = [pscustomobject]@{ displayName = [string]$row.DefaultProjectName }
                } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $bodyPath -Encoding UTF8
                $created = Invoke-AzRest -Method 'PUT' -Url $projectUrl -BodyPath $bodyPath
                Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
                if ($created.ExitCode -ne 0) { throw $created.Text }
                Wait-ArmProvisioning -Description "Foundry Project '$($row.DefaultProjectName)'" -Url $projectUrl
                $projectStatus = 'Succeeded'
            }
        }
        catch {
            $errorMessage = "$($_.Exception.Message)"
            Write-Err $errorMessage
            if ($groupStatus -eq 'Pending') { $groupStatus = 'NotStarted' }
            if ($foundryStatus -eq 'Pending') { $foundryStatus = 'NotStarted' }
            if ($projectStatus -eq 'Pending') { $projectStatus = 'NotStarted' }
            $ok = $false
        }

        $results.Add([pscustomobject]@{ SubscriptionName = $row.SubscriptionName; SubscriptionId = $row.SubscriptionId; ResourceGroupName = $row.ResourceGroupName; FoundryResourceName = $row.FoundryResourceName; DefaultProjectName = $row.DefaultProjectName; Location = $location; ResourceGroupStatus = $groupStatus; FoundryStatus = $foundryStatus; ProjectStatus = $projectStatus; ErrorMessage = $errorMessage })
    }

    Save-ResultCsv -Name 'stage2_foundry_provisioning' -Rows $results.ToArray()
    $ok
}

# ==================== 阶段 3：批量部署模型 ====================

function Invoke-StageDeployModels {
    Write-Info '========== 阶段：批量部署模型 =========='
    $rows = @(Import-Plan -Phase 'DeployModels')
    $accounts = @(Invoke-AzJson -Arguments @('account', 'list', '--all'))

    foreach ($row in $rows) {
        $specs = @(Expand-ModelSpec -Row $row)
        $depDesc = ($specs | ForEach-Object { if ($_.DeploymentName -eq $_.Name) { $_.Name } else { "$($_.DeploymentName)($($_.Name))" } }) -join ', '
        Write-Host ("  {0} | {1} | 部署: {2} | 类型: {3}" -f $row.SubscriptionName, $row.FoundryResourceName, $depDesc, (Get-DeploymentType -Row $row))
    }
    if (-not (Confirm-Execution "将在 $($rows.Count) 个 Foundry 账户中部署模型")) { return $true }

    $results = New-Object System.Collections.Generic.List[object]
    $ok = $true
    foreach ($row in $rows) {
        $deploymentType = Get-DeploymentType -Row $row
        try {
            Write-Info "处理 '$($row.SubscriptionName)' / '$($row.FoundryResourceName)'"
            Resolve-Subscription -Row $row -Accounts $accounts | Out-Null
            $location = Get-AccountLocation -Row $row
            $existing = @(Get-ExistingDeployments -Row $row)
        }
        catch {
            $message = "$($_.Exception.Message)"
            Write-Err "$($row.SubscriptionName): $message"
            $results.Add([pscustomobject]@{ SubscriptionName = $row.SubscriptionName; FoundryResourceName = $row.FoundryResourceName; ModelName = ''; DeploymentType = $deploymentType; CapacityK = 0; Status = 'Failed'; ErrorMessage = $message })
            $ok = $false
            continue
        }

        foreach ($spec in @(Expand-ModelSpec -Row $row)) {
            $status = 'Pending'; $errorMessage = ''; $capacityK = 0
            $specSku = [string]$spec.Sku
            $targetDepName = [string]$spec.DeploymentName
            $targetModel = [string]$spec.Name
            try {
                # 必须同时匹配部署名、模型名以及 SKU 类型（忽略空格与大小写差异）
                $normTargetSku = $specSku.Replace(' ', '').ToLowerInvariant()
                $matchingDeployment = @($existing | Where-Object {
                    $_.DeploymentName.ToLowerInvariant() -eq $targetDepName.ToLowerInvariant() -and
                    $_.ModelName.ToLowerInvariant() -eq $targetModel.ToLowerInvariant() -and
                    ($_.SkuName.Replace(' ', '')).ToLowerInvariant() -eq $normTargetSku
                }) | Select-Object -First 1

                if ($null -ne $matchingDeployment) {
                    Write-Info "  $targetDepName（$specSku）：部署已存在且类型一致，跳过"
                    $status = 'SkippedExisting'
                }
                else {
                    $quota = Get-Quota -SubscriptionId ([string]$row.SubscriptionId) -Location $location -ModelName $targetModel -SkuName $specSku
                    if (-not $quota.Found) { throw "区域 $location 没有 $specSku + $targetModel 的配额项，请确认该区域是否提供此模型与 SKU。" }
                    $remaining = [math]::Max(0, $quota.Total - $quota.Allocated)

                    $configured = 0
                    $hasConfigured = [int]::TryParse([string]$row.DeploymentCapacityK, [ref]$configured)
                    $capacityK = if ($hasConfigured -and $configured -gt 0) { [math]::Min($configured, $remaining) } else { $remaining }

                    Write-Info ("  {0}（{1}）：总配额 {2}，已分配 {3}，剩余 {4}，本次部署 {5}" -f $targetDepName, $specSku, (Format-Capacity $quota.Total), (Format-Capacity $quota.Allocated), (Format-Capacity $remaining), (Format-Capacity $capacityK))
                    if ($capacityK -le 0) {
                        $status = 'NoQuota'
                        $errorMessage = '剩余配额为 0，已跳过。'
                    }
                    else {
                        Set-Deployment -Row $row -DeploymentName $targetDepName -ModelName $targetModel -ModelVersion $spec.Version -ModelFormat $spec.Format -SkuName $specSku -CapacityK $capacityK
                        $status = if ($DryRun) { 'WhatIf' } else { 'Succeeded' }
                    }
                }
            }
            catch {
                $errorMessage = "$($_.Exception.Message)"
                Write-Err "  ${targetDepName}: $errorMessage"
                $status = 'Failed'
                $ok = $false
            }
            $results.Add([pscustomobject]@{ SubscriptionName = $row.SubscriptionName; FoundryResourceName = $row.FoundryResourceName; ModelName = $targetModel; DeploymentName = $targetDepName; DeploymentType = $specSku; CapacityK = $capacityK; Status = $status; ErrorMessage = $errorMessage })
        }
    }

    Save-ResultCsv -Name 'stage3_model_deployment' -Rows $results.ToArray()
    Save-DeliveryReport -Rows $rows -Accounts $accounts
    $ok
}

# ==================== 阶段 4：批量扩容配额 ====================

function Invoke-StageScaleUpQuota {
    Write-Info '========== 阶段：批量扩容已有部署 =========='
    $rows = @(Import-Plan -Phase 'ScaleUpQuota')
    $accounts = @(Invoke-AzJson -Arguments @('account', 'list', '--all'))

    foreach ($row in $rows) {
        $specs = @(Expand-ModelSpec -Row $row)
        Write-Host ("  {0} | {1} | 目标模型: {2}" -f $row.SubscriptionName, $row.FoundryResourceName, (($specs | ForEach-Object { $_.Name }) -join ', '))
    }
    if (-not (Confirm-Execution "将扩容 $($rows.Count) 个 Foundry 账户中的已有部署")) { return $true }

    $results = New-Object System.Collections.Generic.List[object]
    $ok = $true
    foreach ($row in $rows) {
        try {
            Write-Info "处理 '$($row.SubscriptionName)' / '$($row.FoundryResourceName)'"
            Resolve-Subscription -Row $row -Accounts $accounts | Out-Null
            $location = Get-AccountLocation -Row $row
            $deployments = @(Get-ExistingDeployments -Row $row)
        }
        catch {
            $message = "$($_.Exception.Message)"
            Write-Err "$($row.SubscriptionName): $message"
            $results.Add([pscustomobject]@{ SubscriptionName = $row.SubscriptionName; FoundryResourceName = $row.FoundryResourceName; DeploymentName = ''; CurrentK = 0; TargetK = 0; IncreaseK = 0; Status = 'Failed'; ErrorMessage = $message })
            $ok = $false
            continue
        }

        $targetModels = @(@(Expand-ModelSpec -Row $row) | ForEach-Object { $_.Name })
        if ($deployments.Count -eq 0) { Write-Warn "  该账户没有任何部署，跳过。"; continue }

        foreach ($deployment in $deployments) {
            if ($targetModels -notcontains $deployment.ModelName) { continue }
            $status = 'Pending'; $errorMessage = ''; $target = $deployment.CapacityK; $increase = 0
            try {
                $quota = Get-Quota -SubscriptionId ([string]$row.SubscriptionId) -Location $location -ModelName $deployment.ModelName -SkuName $deployment.SkuName
                # 只把共享配额中尚未分配的部分追加到当前部署，避免跨账户超配。
                $remaining = [math]::Max(0, $quota.Total - $quota.Allocated)
                $target = $deployment.CapacityK + $remaining
                $increase = [math]::Max(0, $target - $deployment.CapacityK)

                Write-Info ("  {0}：当前 {1}，共享已分配 {2}，总配额 {3}，剩余 {4}，预计提升 {5}" -f $deployment.DeploymentName, (Format-Capacity $deployment.CapacityK), (Format-Capacity $quota.Allocated), (Format-Capacity $quota.Total), (Format-Capacity $remaining), (Format-Capacity $increase))

                if ($remaining -le 0) { $status = 'Skipped' }
                else {
                    Set-Deployment -Row $row -DeploymentName $deployment.DeploymentName -ModelName $deployment.ModelName -ModelVersion $deployment.ModelVersion -ModelFormat $deployment.ModelFormat -SkuName $deployment.SkuName -CapacityK $target
                    $status = if ($DryRun) { 'WhatIf' } else { 'Succeeded' }
                }
            }
            catch {
                $errorMessage = "$($_.Exception.Message)"
                Write-Err "  $($deployment.DeploymentName): $errorMessage"
                $status = 'Failed'
                $ok = $false
            }
            $results.Add([pscustomobject]@{ SubscriptionName = $row.SubscriptionName; FoundryResourceName = $row.FoundryResourceName; DeploymentName = $deployment.DeploymentName; CurrentK = $deployment.CapacityK; TargetK = $target; IncreaseK = $increase; Status = $status; ErrorMessage = $errorMessage })
        }
    }

    Save-ResultCsv -Name 'stage4_quota_scale_up' -Rows $results.ToArray()
    $ok
}

# ==================== 交互菜单与入口 ====================

function Show-Menu {
    Write-Host ''
    Write-Host '========== Azure Foundry 全生命周期工具 =========='
    Write-Host '  1) 创建 Azure 订阅（仅限 EA 企业协议订阅，回填 SubscriptionId）'
    Write-Host '  2) 创建 Foundry 服务和 Foundry 项目'
    Write-Host '  3) 批量部署模型（按剩余配额）'
    Write-Host '  4) 批量扩容已有部署配额'
    Write-Host '  5) 全流程（1 -> 2 -> 3）'
    Write-Host '  0) 退出'
    Write-Host ''
    $choice = Read-Host '请选择要执行的阶段'
    switch ($choice) {
        '1' { 'CreateSubscription' }
        '2' { 'CreateFoundry' }
        '3' { 'DeployModels' }
        '4' { 'ScaleUpQuota' }
        '5' { 'All' }
        '0' { '' }
        default { throw "无效选项：$choice" }
    }
}

try {
    Initialize-Runtime
    Confirm-Environment

    $script:QuotaCache = @{}
    $script:RegisteredProviders = @{}

    $selected = if ([string]::IsNullOrWhiteSpace($Stage)) { Show-Menu } else { $Stage }
    if ([string]::IsNullOrWhiteSpace($selected)) { Write-Info '已退出。'; exit 0 }

    Write-Info "租户：$TenantId"
    Write-Info "规划 CSV：$Csv"
    Write-Info "执行阶段：$selected"
    $modeText = if ($DryRun) { '预演模式（DryRun）' } else { '正式模式（Live）' }
    Write-Info "运行模式：$modeText"

    Invoke-AzLogin

    $success = switch ($selected) {
        'CreateSubscription' { Invoke-StageCreateSubscription }
        'CreateFoundry' { Invoke-StageCreateFoundry }
        'DeployModels' { Invoke-StageDeployModels }
        'ScaleUpQuota' { Invoke-StageScaleUpQuota }
        'All' {
            $r1 = Invoke-StageCreateSubscription
            $r2 = Invoke-StageCreateFoundry
            $r3 = Invoke-StageDeployModels
            $r1 -and $r2 -and $r3
        }
    }

    Write-Info "日志文件：$script:LogFile"
    if (-not $success) { exit 1 }
    exit 0
}
catch {
    if ($script:LogFile) { Write-Err "$($_.Exception.Message)" } else { Write-Error $_ }
    exit 1
}
