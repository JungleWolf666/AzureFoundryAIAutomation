#!/usr/bin/env bash
# ============================================================================
# Azure Foundry AI 一站式全生命周期统一脚本（Bash 版）
#
# 四个阶段的参数全部来自同一个 CSV，避免在多个脚本中重复维护配置：
#   1) 创建 Azure 订阅（回填 SubscriptionId）—— 仅限 EA 企业协议订阅，CSP 订阅请勿运行
#   2) 创建 Foundry 服务和 Foundry 项目
#   3) 按剩余配额批量部署模型
#   4) 把已有部署的容量扩到剩余配额上限
#
# 不带 --stage 参数运行时进入交互式菜单。
#
# 【重要】阶段 1 通过 Microsoft.Subscription/aliases API 自助创建订阅，仅适用于 EA 企业协议订阅。
# CSP 合作伙伴管理的订阅（尤其是 HK CSP T1）请勿运行阶段 1；订阅必须由合作伙伴创建，
# 使用方应将获得的 SubscriptionId 填入 CSV，并直接从阶段 2 开始。
#
# 运行前提：Bash 3.2+、Azure CLI、jq、python3。
# ============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
  echo "此脚本必须使用 Bash 运行：bash Azure_Foundry_AI_Automation.sh" >&2
  exit 1
fi

set -euo pipefail

SCRIPT_VERSION="1.0.1"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
TENANT_ID=""
CSV_PATH="$SCRIPT_DIR/Azure_Foundry_AI_Plan.csv"
OUTPUT_ROOT="$SCRIPT_DIR"
STAGE=""
DRY_RUN=false
BROWSER_LOGIN=false
CREATE_DELAY_SECONDS=10
CREATE_DELAY_EXPLICIT=false

EXPECTED_HEADER="BillingAccountName,EnrollmentAccountName,SubscriptionName,SubscriptionId,ResourceGroupName,FoundryResourceName,DefaultProjectName,Location,ModelNames,ModelVersion,ModelFormat,DeploymentType,DeploymentCapacityK"

usage() {
  cat <<'EOF'
用法：
  # 1. 交互式菜单（推荐）：
  bash Azure_Foundry_AI_Automation.sh --tenant-id <TENANT-ID>

  # 2. 单独运行各阶段（预演模式 --dry-run，不修改 Azure 资源）：
  bash Azure_Foundry_AI_Automation.sh --tenant-id <TENANT-ID> --stage CreateSubscription --dry-run
  bash Azure_Foundry_AI_Automation.sh --tenant-id <TENANT-ID> --stage CreateFoundry      --dry-run
  bash Azure_Foundry_AI_Automation.sh --tenant-id <TENANT-ID> --stage DeployModels       --dry-run
  bash Azure_Foundry_AI_Automation.sh --tenant-id <TENANT-ID> --stage ScaleUpQuota       --dry-run

  # 3. 单独正式执行各阶段（去掉 --dry-run，需输入大写 YES 确认）：
  bash Azure_Foundry_AI_Automation.sh --tenant-id <TENANT-ID> --stage CreateSubscription
  bash Azure_Foundry_AI_Automation.sh --tenant-id <TENANT-ID> --stage CreateFoundry
  bash Azure_Foundry_AI_Automation.sh --tenant-id <TENANT-ID> --stage DeployModels
  bash Azure_Foundry_AI_Automation.sh --tenant-id <TENANT-ID> --stage ScaleUpQuota

  # 4. 全流程依次执行阶段 1 -> 2 -> 3：
  bash Azure_Foundry_AI_Automation.sh --tenant-id <TENANT-ID> --stage All --dry-run
  bash Azure_Foundry_AI_Automation.sh --tenant-id <TENANT-ID> --stage All

参数：
  --tenant-id GUID   客户 Microsoft Entra 租户 ID。必填。
  --stage NAME       指定阶段，省略时进入交互式菜单。可选值：
                       CreateSubscription  阶段 1：创建 Azure 订阅并回填 SubscriptionId【仅限 EA，CSP 请勿运行，见下方提示】
                       CreateFoundry       阶段 2：创建资源组、Foundry 服务和 Foundry 项目
                       DeployModels        阶段 3：按剩余配额批量部署 CSV 中的模型
                       ScaleUpQuota        阶段 4：把已有部署的容量扩到剩余配额上限
                       All                 全流程：依次执行前三个阶段（1 -> 2 -> 3），阶段 1 同样仅限 EA

【EA / CSP 提示】阶段 1（含 All 内的阶段 1）通过 Microsoft.Subscription/aliases API 自助创建订阅，
只有 EA 企业协议订阅有权限调用。CSP 合作伙伴管理的订阅（尤其是 HK CSP T1）
没有权限自行创建订阅，订阅必须由合作伙伴（Partner）在 Partner Center 中创建后交付 SubscriptionId。
此类订阅请勿运行阶段 1 / All，应直接从阶段 2（CreateFoundry）开始，把合作伙伴提供的 SubscriptionId
手工填入 CSV 的 SubscriptionId 列。运行阶段 1 时脚本会额外要求输入 EA 二次确认。
  --csv PATH         规划 CSV 路径，默认同目录 Azure_Foundry_AI_Plan.csv。
  --output-root PATH logs/results 输出根目录，默认脚本所在目录。
  --create-delay N   阶段 1 中每创建一个订阅后的等待秒数，用于缓解租户级限流。
                     不指定时按待创建数量自动选择：<=20 个用 10 秒，21-50 个用 20 秒，>50 个用 30 秒。
  --dry-run          只显示将执行的动作，不创建或修改任何 Azure 资源。
  --browser-login    使用浏览器登录；默认使用设备码登录。
  --version          显示脚本版本。
  --help             显示本帮助。

ModelNames 支持分号分隔，每项可写 name、name:version、name:version:format 或 name:version:format:sku，
例如：gpt-5.6-sol;gpt-image-2:2026-04-21;FW-GLM-5.2:::DataZoneStandard
也可使用 deployment_name=model:version:format:sku 指定与模型名不同的部署名，
例如：gpt-5.6-sol-dz=gpt-5.6-sol:::DataZoneStandard。
省略的部分回退到该行的 ModelVersion / ModelFormat / DeploymentType。
同一个订阅/账户可在 CSV 中写多行（如分别配置 GlobalStandard 和 DataZoneStandard）。
DeploymentCapacityK 留空表示自动使用剩余配额；填数字表示固定容量（单位 K TPM）。
EOF
}

while (($#)); do
  case "$1" in
    --tenant-id) TENANT_ID="${2:-}"; shift 2 ;;
    --stage) STAGE="${2:-}"; shift 2 ;;
    --csv) CSV_PATH="${2:-}"; shift 2 ;;
    --output-root) OUTPUT_ROOT="${2:-}"; shift 2 ;;
    --create-delay) CREATE_DELAY_SECONDS="${2:-10}"; CREATE_DELAY_EXPLICIT=true; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --browser-login) BROWSER_LOGIN=true; shift ;;
    --version) printf 'Azure Foundry AI Automation v%s\n' "$SCRIPT_VERSION"; exit 0 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
  esac
done

# ==================== 运行时与日志 ====================

RUN_ID=$(date '+%Y%m%d_%H%M%S')
LOG_DIR="$OUTPUT_ROOT/logs"
RESULT_DIR="$OUTPUT_ROOT/results"
mkdir -p "$LOG_DIR" "$RESULT_DIR"
LOG_FILE="$LOG_DIR/azure_foundry_ai_automation_${RUN_ID}.log"
: > "$LOG_FILE"

log() {
  local level="$1"; shift
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
  printf '%s\n' "$line" >> "$LOG_FILE"
  printf '%s\n' "$line" >&2
}
log_info() { log INFO "$@"; }
log_warn() { log WARN "$@"; }
log_error() { log ERROR "$@"; }

require_commands() {
  local missing=""
  for cmd in az jq python3; do
    command -v "$cmd" >/dev/null 2>&1 || missing="${missing} ${cmd}"
  done
  if [[ -n "$missing" ]]; then
    echo "缺少运行所需命令:${missing}" >&2
    exit 1
  fi
}

confirm_environment() {
  require_commands
  if [[ -z "$TENANT_ID" ]]; then
    echo "--tenant-id 为必填参数。" >&2
    exit 2
  fi
  if [[ ! "$TENANT_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "--tenant-id 必须是真实的 Microsoft Entra 租户 GUID，请替换 <TENANT-ID> 占位符。" >&2
    exit 2
  fi
}

# ==================== Azure CLI 封装 ====================

TEMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

az_json() { az "$@" --output json --only-show-errors; }

az_rest() {
  local method="$1" url="$2" body_file="${3:-}"
  local args=(rest --method "$method" --url "$url")
  [[ -n "$body_file" ]] && args+=(--body "@$body_file")
  args+=(--output json --only-show-errors)
  az "${args[@]}"
}

is_throttled_error() {
  printf '%s' "$1" | grep -Eqi '(^|[^0-9])429([^0-9]|$)|TooManyRequests|Too many requests|RateLimitExceeded|throttl|excessive volume of traffic'
}

retry_after_seconds() {
  local message="$1" attempt="$2" seconds=""
  seconds=$(printf '%s' "$message" | grep -Eoi 'retry[-_ ]?after[^0-9]{0,12}[0-9]+' | grep -Eo '[0-9]+' | head -n 1)
  if [[ -n "$seconds" ]] && ((seconds > 0)); then
    ((seconds > 300)) && seconds=300
    printf '%s' "$seconds"
    return 0
  fi
  seconds=$((5 * (1 << attempt)))
  ((seconds > 120)) && seconds=120
  printf '%s' "$seconds"
}

# 订阅别名创建是租户级写操作，Azure 按租户令牌桶限流，429 需按 Retry-After 退避重试。
# 命令替换会开子 shell，错误信息改用文件回传给调用方。
AZ_REST_ERROR_FILE=""
az_rest_retry() {
  local method="$1" url="$2" body_file="${3:-}"
  local attempt=1 max_attempts=6 output="" message="" wait_seconds=""
  local err_file="$TEMP_DIR/az_rest_attempt.err"
  AZ_REST_ERROR_FILE="$TEMP_DIR/az_rest_last.err"
  : > "$AZ_REST_ERROR_FILE"
  while :; do
    if output=$(az_rest "$method" "$url" "$body_file" 2>"$err_file"); then
      printf '%s' "$output"
      return 0
    fi
    message=$(tr '\n' ' ' < "$err_file")
    if ((attempt >= max_attempts)) || ! is_throttled_error "$message"; then
      printf '%s' "$message" > "$AZ_REST_ERROR_FILE"
      return 1
    fi
    wait_seconds=$(retry_after_seconds "$message" "$attempt")
    log_warn "  请求被限流（第 ${attempt}/${max_attempts} 次），等待 ${wait_seconds} 秒后重试。"
    sleep "$wait_seconds"
    attempt=$((attempt + 1))
  done
}

azure_login() {
  local args=(login --tenant "$TENANT_ID" --allow-no-subscriptions --output none)
  [[ "$BROWSER_LOGIN" == false ]] && args+=(--use-device-code)
  log_info "登录租户 $TENANT_ID"
  az "${args[@]}"
}

format_capacity() {
  python3 - "$1" <<'PY'
import sys
value = int(sys.argv[1])
print(f"{value} K" if value < 1000 else f"{value/1000:g} M")
PY
}

confirm_execution() {
  if [[ "$DRY_RUN" == true ]]; then return 0; fi
  printf '%s，输入大写 YES 继续：' "$1" >&2
  local answer
  IFS= read -r answer
  if [[ "$answer" != "YES" ]]; then
    log_warn "用户取消操作。"
    return 1
  fi
  return 0
}

# 阶段 1（创建订阅）仅适用于 EA 客户；CSP 合作伙伴管理的订阅无权限自行创建，必须由合作伙伴创建。
confirm_ea_only_stage() {
  cat >&2 <<'EOF'

========================================================
⚠️  重要提示：阶段 1 仅适用于 EA 企业协议订阅  ⚠️
========================================================

  - 如果您的订阅由 CSP 合作伙伴管理，请不要运行阶段 1。
  - 请先联系合作伙伴创建订阅，并将获得的 SubscriptionId 填入 CSV，
    然后直接从阶段 2（CreateFoundry）开始执行。
  - 运行前如无法确认协议类型，请联系贵司 Azure 管理员或服务合作伙伴。

EOF
  if [[ "$DRY_RUN" == true ]]; then return 0; fi
  printf '请确认当前订阅为 EA 企业协议、且有权限自助创建订阅，输入大写 EA 继续（其他任何输入将取消本阶段）：' >&2
  local answer
  IFS= read -r answer
  if [[ "$answer" != "EA" ]]; then
    log_warn "未确认 EA 协议身份，已取消阶段 1。"
    return 1
  fi
  return 0
}

# ==================== CSV 处理 ====================

# 把 CSV 校验并转换为 JSON Lines，后续各阶段统一按行读取。
load_plan() {
  local phase="$1"
  python3 - "$CSV_PATH" "$phase" "$EXPECTED_HEADER" <<'PY'
import csv, json, re, sys, uuid

csv_path, phase, expected = sys.argv[1], sys.argv[2], sys.argv[3].split(',')

required_map = {
    'CreateSubscription': ['BillingAccountName', 'EnrollmentAccountName', 'SubscriptionName'],
    'CreateFoundry': ['SubscriptionName', 'SubscriptionId', 'ResourceGroupName',
                      'FoundryResourceName', 'DefaultProjectName', 'Location'],
}
required = required_map.get(phase, ['SubscriptionName', 'SubscriptionId', 'ResourceGroupName',
                                    'FoundryResourceName', 'ModelNames'])

try:
    with open(csv_path, encoding='utf-8-sig', newline='') as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames != expected:
            raise SystemExit('CSV 列必须严格为：' + ','.join(expected))
        rows = list(reader)
except FileNotFoundError:
    raise SystemExit(f'CSV 文件不存在：{csv_path}')

if not rows:
    raise SystemExit('CSV 中没有数据行。')

errors, sub_meta, foundry_meta = [], {}, {}
for index, row in enumerate(rows, start=2):
    for field in expected:
        value = (row.get(field) or '')
        if value != value.strip():
            errors.append(f'第 {index} 行：{field} 存在首尾空格。')
        if '|' in value:
            errors.append(f'第 {index} 行：{field} 不能包含竖线字符。')
    for field in required:
        if not (row.get(field) or '').strip():
            errors.append(f'第 {index} 行：{phase} 阶段需要填写 {field}。')
    for field in ('BillingAccountName', 'EnrollmentAccountName'):
        if '/' in (row.get(field) or ''):
            errors.append(f'第 {index} 行：{field} 应填资源名称，而不是完整资源 ID。')

    name = (row.get('SubscriptionName') or '').strip()
    billing = (row.get('BillingAccountName') or '').strip()
    enrollment = (row.get('EnrollmentAccountName') or '').strip()
    if name:
        if name in sub_meta and sub_meta[name] != (billing, enrollment):
            errors.append(f'第 {index} 行：SubscriptionName「{name}」在其他行已配置了不同的计费账户或登记账户。')
        else:
            sub_meta[name] = (billing, enrollment)

    sub_id = (row.get('SubscriptionId') or '').strip()
    if sub_id:
        try:
            uuid.UUID(sub_id)
        except ValueError:
            errors.append(f'第 {index} 行：SubscriptionId 不是合法 GUID。')

    foundry = (row.get('FoundryResourceName') or '').strip()
    location = (row.get('Location') or '').strip().lower()
    rg = (row.get('ResourceGroupName') or '').strip().lower()
    if foundry:
        if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,62}[a-z0-9]', foundry):
            errors.append(f'第 {index} 行：FoundryResourceName「{foundry}」必须为 2-64 位小写字母、数字或连字符，且以字母或数字开头结尾。')
        foundry_key = f"{sub_id.lower()}|{rg}|{foundry.lower()}"
        if foundry_key in foundry_meta and foundry_meta[foundry_key] != location:
            errors.append(f'第 {index} 行：FoundryResourceName「{foundry}」在同一资源组中已配置了不同的区域。')
        else:
            foundry_meta[foundry_key] = location

if errors:
    raise SystemExit('\n'.join(errors))

for row in rows:
    print(json.dumps(row, ensure_ascii=False, separators=(',', ':')))
PY
}

# ModelNames 支持分号分隔，每项支持：
#   model
#   deployment_name=model
#   model:version
#   model:version:format
#   model:version:format:sku
#   deployment_name=model:version:format:sku
expand_models() {
  local row_json="$1"
  python3 - "$row_json" <<'PY'
import json, sys, re
row = json.loads(sys.argv[1])

def normalize_date(val):
    if not val:
        return ""
    val = val.strip()
    m = re.match(r'^(\d{4})[/-](\d{1,2})[/-](\d{1,2})$', val)
    if m:
        return f"{int(m.group(1)):04d}-{int(m.group(2)):02d}-{int(m.group(3)):02d}"
    return val

default_version = normalize_date(row.get('ModelVersion'))
default_format = (row.get('ModelFormat') or '').strip() or 'OpenAI'
default_sku = (row.get('DeploymentType') or '').strip() or 'GlobalStandard'
for item in (row.get('ModelNames') or '').split(';'):
    item = item.strip()
    if not item:
        continue
    dep_name = ''
    model_part = item
    if '=' in item:
        parts_eq = item.split('=', 1)
        dep_name = parts_eq[0].strip()
        model_part = parts_eq[1].strip()

    parts = model_part.split(':')
    name = parts[0].strip()
    if not dep_name:
        dep_name = name
    version = normalize_date(parts[1]) if len(parts) >= 2 and parts[1].strip() else default_version
    fmt = parts[2].strip() if len(parts) >= 3 and parts[2].strip() else default_format
    sku = parts[3].strip() if len(parts) >= 4 and parts[3].strip() else default_sku
    print(f'{dep_name}\t{name}\t{version}\t{fmt}\t{sku}')
PY
}

csv_field() { printf '%s' "$1" | jq -r --arg f "$2" '.[$f] // ""'; }

deployment_type_of() {
  local value
  value=$(csv_field "$1" 'DeploymentType')
  [[ -z "$value" ]] && value='GlobalStandard'
  printf '%s' "$value"
}

write_result_header() {
  RESULT_FILE="$RESULT_DIR/$1_${RUN_ID}.csv"
  shift
  python3 - "$RESULT_FILE" "$@" <<'PY'
import csv, sys
with open(sys.argv[1], 'w', encoding='utf-8', newline='') as handle:
    csv.writer(handle).writerow(sys.argv[2:])
PY
}

write_result_row() {
  python3 - "$RESULT_FILE" "$@" <<'PY'
import csv, sys
with open(sys.argv[1], 'a', encoding='utf-8', newline='') as handle:
    csv.writer(handle).writerow(sys.argv[2:])
PY
}

update_plan_subscription_id() {
  python3 - "$CSV_PATH" "$1" "$2" <<'PY'
import csv, os, shutil, sys, tempfile
from datetime import datetime

csv_path, name, subscription_id = sys.argv[1], sys.argv[2], sys.argv[3]
with open(csv_path, encoding='utf-8-sig', newline='') as handle:
    reader = csv.DictReader(handle)
    fields = reader.fieldnames
    rows = list(reader)

backup_dir = os.path.join(os.path.dirname(csv_path) or '.', 'csv_backups')
os.makedirs(backup_dir, exist_ok=True)
backup_name = f'{os.path.basename(csv_path)}.bak.{datetime.now():%Y%m%d_%H%M%S_%f}'
shutil.copy2(csv_path, os.path.join(backup_dir, backup_name))
for row in rows:
    if row['SubscriptionName'] == name:
        row['SubscriptionId'] = subscription_id

fd, tmp = tempfile.mkstemp(prefix=f'.{os.path.basename(csv_path)}.', suffix='.tmp',
                           dir=os.path.dirname(csv_path) or '.', text=True)
with os.fdopen(fd, 'w', encoding='utf-8', newline='') as handle:
    writer = csv.DictWriter(handle, fieldnames=fields)
    writer.writeheader()
    writer.writerows(rows)
    handle.flush()
    os.fsync(handle.fileno())
os.replace(tmp, csv_path)
PY
}

# ==================== 公共 Azure 辅助 ====================

ACCOUNT_LIST_JSON=""

load_account_list() { ACCOUNT_LIST_JSON=$(az_json account list --all); }

# 校验订阅 ID、订阅名和租户三者一致后，再切换当前订阅上下文。
resolve_subscription() {
  local row_json="$1"
  local subscription_id subscription_name actual_name actual_tenant
  subscription_id=$(csv_field "$row_json" 'SubscriptionId')
  subscription_name=$(csv_field "$row_json" 'SubscriptionName')

  local match
  match=$(printf '%s' "$ACCOUNT_LIST_JSON" | jq -c --arg id "$subscription_id" \
    'map(select((.id // "" | ascii_downcase) == ($id | ascii_downcase))) | .[0] // empty')
  if [[ -z "$match" ]]; then
    echo "订阅 '$subscription_id' 对当前登录账号不可见。" >&2
    return 1
  fi

  actual_name=$(printf '%s' "$match" | jq -r '.name // ""')
  if [[ "$actual_name" != "$subscription_name" ]]; then
    echo "SubscriptionId '$subscription_id' 实际属于订阅 '$actual_name'，与 CSV 中的 SubscriptionName '$subscription_name' 不一致。" >&2
    return 1
  fi

  actual_tenant=$(printf '%s' "$match" | jq -r '.tenantId // ""' | tr '[:upper:]' '[:lower:]')
  if [[ "$actual_tenant" != "$(printf '%s' "$TENANT_ID" | tr '[:upper:]' '[:lower:]')" ]]; then
    echo "订阅属于租户 ${actual_tenant}，与 --tenant-id $TENANT_ID 不一致。" >&2
    return 1
  fi

  az account set --subscription "$subscription_id" --only-show-errors
}

get_account_location() {
  local row_json="$1"
  az cognitiveservices account show \
    --resource-group "$(csv_field "$row_json" 'ResourceGroupName')" \
    --name "$(csv_field "$row_json" 'FoundryResourceName')" \
    --query location -o tsv --only-show-errors
}

# 同一订阅/区域/模型/SKU 的配额只查询一次，避免重复请求。
QUOTA_CACHE_KEYS=("")
QUOTA_CACHE_VALUES=("")

get_quota() {
  local subscription_id="$1" location="$2" model="$3" sku="$4"
  local key="${subscription_id}|${location}|${model}|${sku}"
  local i
  for ((i = 0; i < ${#QUOTA_CACHE_KEYS[@]}; i++)); do
    if [[ "${QUOTA_CACHE_KEYS[$i]}" == "$key" ]]; then
      printf '%s' "${QUOTA_CACHE_VALUES[$i]}"
      return 0
    fi
  done

  local usage candidates value
  usage=$(az_json cognitiveservices usage list --location "$location")
  candidates="AIServices.${sku}.${model}"$'\n'"OpenAI.${sku}.${model}"
  [[ "$model" == FW-* ]] && candidates="AIServices.${sku}.Fireworks"$'\n'"$candidates"

  value=""
  while IFS= read -r candidate; do
    [[ -z "$candidate" ]] && continue
    value=$(printf '%s' "$usage" | jq -r --arg k "$candidate" \
      'map(select((.name.value // "") == $k)) | .[0] // empty | "\(.limit // 0)|\(.currentValue // 0)"')
    [[ -n "$value" ]] && break
  done <<< "$candidates"

  [[ -z "$value" ]] && value="NOTFOUND"
  QUOTA_CACHE_KEYS+=("$key")
  QUOTA_CACHE_VALUES+=("$value")
  printf '%s' "$value"
}

get_existing_deployments() {
  local row_json="$1"
  az_json cognitiveservices account deployment list \
    --resource-group "$(csv_field "$row_json" 'ResourceGroupName')" \
    --name "$(csv_field "$row_json" 'FoundryResourceName')" |
    jq -r '.[]? | [.name, .properties.model.name, .properties.model.format, .properties.model.version, .sku.name, (.sku.capacity // 0)] | @tsv'
}

set_deployment() {
  local row_json="$1" deployment_name="$2" model_name="$3" model_version="$4" model_format="$5" sku_name="$6" capacity="$7"
  local args=(cognitiveservices account deployment create
    --resource-group "$(csv_field "$row_json" 'ResourceGroupName')"
    --name "$(csv_field "$row_json" 'FoundryResourceName')"
    --deployment-name "$deployment_name"
    --model-name "$model_name"
    --model-format "$model_format"
    --sku-name "$sku_name"
    --sku-capacity "$capacity"
    --only-show-errors)
  [[ -n "$model_version" ]] && args+=(--model-version "$model_version")

  if [[ "$DRY_RUN" == true ]]; then
    log_info "[DRY-RUN] az ${args[*]}"
    return 0
  fi
  az "${args[@]}" --output none
}

# ==================== 阶段 1：创建 EA 订阅 ====================

is_fatal_billing_error() {
  [[ "$1" =~ Permission|Forbidden|UserNotAuthorized|AuthorizationFailed|InvalidBillingScope|EnrollmentAccount ]]
}

stage_create_subscription() {
  log_info '========== 阶段：创建 Azure 订阅 =========='
  confirm_ea_only_stage || { log_info '已跳过阶段 1。'; return 0; }
  local rows_file="$TEMP_DIR/rows_stage1.jsonl"
  load_plan 'CreateSubscription' > "$rows_file"
  load_account_list

  local pending=0 row_json
  while IFS= read -r row_json; do
    [[ -z "$(csv_field "$row_json" 'SubscriptionId')" ]] && pending=$((pending + 1))
  done < "$rows_file"

  log_info "待创建订阅数：$pending"
  while IFS= read -r row_json; do
    local name id
    name=$(csv_field "$row_json" 'SubscriptionName')
    id=$(csv_field "$row_json" 'SubscriptionId')
    if [[ -n "$id" ]]; then
      printf '  [SKIP]   %s -> %s\n' "$name" "$id" >&2
    else
      printf '  [CREATE] %s | billingAccount=%s | enrollmentAccount=%s\n' \
        "$name" "$(csv_field "$row_json" 'BillingAccountName')" "$(csv_field "$row_json" 'EnrollmentAccountName')" >&2
    fi
  done < "$rows_file"

  if ((pending == 0)); then log_info '没有需要创建的订阅。'; return 0; fi

  # 订阅越多，累计租户级写请求越容易触发限流，未显式指定时按批量规模自动取间隔。
  if [[ "$CREATE_DELAY_EXPLICIT" == false ]]; then
    if ((pending > 50)); then
      CREATE_DELAY_SECONDS=30
    elif ((pending > 20)); then
      CREATE_DELAY_SECONDS=20
    else
      CREATE_DELAY_SECONDS=10
    fi
  fi
  log_info "每创建一个订阅后等待 ${CREATE_DELAY_SECONDS} 秒，用于避免租户级限流。"
  confirm_execution "将创建 $pending 个 EA 订阅" || return 0

  write_result_header 'stage1_subscription_creation' SubscriptionName SubscriptionId AliasName Status ErrorMessage
  local ok=0
  local created_sub_ids_keys=("")
  local created_sub_ids_vals=("")

  get_created_id() {
    local target_name="$1" i
    for ((i = 0; i < ${#created_sub_ids_keys[@]}; i++)); do
      if [[ "${created_sub_ids_keys[$i]}" == "$target_name" ]]; then
        printf '%s' "${created_sub_ids_vals[$i]}"
        return 0
      fi
    done
    return 1
  }

  while IFS= read -r row_json; do
    local name id billing enrollment
    name=$(csv_field "$row_json" 'SubscriptionName')
    id=$(csv_field "$row_json" 'SubscriptionId')
    billing=$(csv_field "$row_json" 'BillingAccountName')
    enrollment=$(csv_field "$row_json" 'EnrollmentAccountName')

    if [[ -n "$id" ]]; then
      write_result_row "$name" "$id" "" "SkippedExisting" ""
      continue
    fi

    local cached_id
    if cached_id=$(get_created_id "$name"); then
      write_result_row "$name" "$cached_id" "" "SkippedExisting" ""
      continue
    fi

    local existing
    existing=$(printf '%s' "$ACCOUNT_LIST_JSON" | jq --arg n "$name" '[.[]? | select(.name == $n)] | length')
    if ((existing > 0)); then
      log_error "$name: 已存在同名的可访问订阅，但 CSV 中 SubscriptionId 为空，不做猜测。"
      write_result_row "$name" "" "" "AmbiguousExisting" "已存在同名的可访问订阅。"
      ok=1
      continue
    fi

    if [[ "$DRY_RUN" == true ]]; then
      log_info "[DRY-RUN] 将创建订阅 '$name'"
      write_result_row "$name" "" "" "WhatIf" ""
      continue
    fi

    local alias_name alias_url body_file error_file
    alias_name="ea-$(python3 -c 'import uuid; print(uuid.uuid4())')"
    alias_url="https://management.azure.com/providers/Microsoft.Subscription/aliases/${alias_name}?api-version=2021-10-01"
    body_file="$TEMP_DIR/${alias_name}.json"
    error_file="$TEMP_DIR/${alias_name}.error"
    jq -n --arg scope "/providers/Microsoft.Billing/billingAccounts/${billing}/enrollmentAccounts/${enrollment}" \
      --arg name "$name" \
      '{properties:{billingScope:$scope, displayName:$name, workload:"Production"}}' > "$body_file"

    log_info "创建订阅 '$name'（billingAccount=${billing}，enrollmentAccount=${enrollment}）"
    local response=""
    if ! response=$(az_rest_retry PUT "$alias_url" "$body_file"); then
      local message; message=$(tr '\n' ' ' < "$AZ_REST_ERROR_FILE")
      log_error "$name: $message"
      write_result_row "$name" "" "$alias_name" "Failed" "$message"
      ok=1
      if is_fatal_billing_error "$message"; then
        log_error '计费或权限错误，停止本阶段。'
        break
      fi
      continue
    fi

    local state new_id started
    state=$(printf '%s' "$response" | jq -r '.properties.provisioningState // ""')
    started=$(date +%s)
    while [[ "$state" != "Succeeded" ]]; do
      if (($(date +%s) - started >= 900)); then
        log_error "$name: 订阅创建超时，最后状态为 $state"
        write_result_row "$name" "" "$alias_name" "Failed" "创建超时"
        ok=1
        break
      fi
      sleep 15
      response=$(az_rest_retry GET "$alias_url")
      state=$(printf '%s' "$response" | jq -r '.properties.provisioningState // ""')
    done
    [[ "$state" != "Succeeded" ]] && continue

    new_id=$(printf '%s' "$response" | jq -r '.properties.subscriptionId // ""')
    if [[ -z "$new_id" ]]; then
      log_error "$name: 订阅创建成功但未返回 SubscriptionId。"
      write_result_row "$name" "" "$alias_name" "Failed" "未返回 SubscriptionId"
      ok=1
      continue
    fi

    update_plan_subscription_id "$name" "$new_id"
    created_sub_ids_keys+=("$name")
    created_sub_ids_vals+=("$new_id")
    log_info "订阅 '$name' 创建完成，ID=$new_id"
    write_result_row "$name" "$new_id" "$alias_name" "Succeeded" ""

    # 批量创建时主动限速，避免触发租户级写限流。
    ((CREATE_DELAY_SECONDS > 0)) && sleep "$CREATE_DELAY_SECONDS"
  done < "$rows_file"

  log_info "结果文件：$RESULT_FILE"
  return $ok
}

# ==================== 阶段 2：创建 Foundry 资源 ====================

REGISTERED_SUBSCRIPTIONS="|"

ensure_provider_registered() {
  local subscription_id="$1" state started
  case "$REGISTERED_SUBSCRIPTIONS" in *"|$subscription_id|"*) return 0 ;; esac

  state=$(az_json provider show --namespace Microsoft.CognitiveServices | jq -r '.registrationState // ""')
  log_info "订阅 $subscription_id 的 Microsoft.CognitiveServices 注册状态：$state"
  if [[ "$state" != "Registered" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
      log_info "[DRY-RUN] 将在订阅 $subscription_id 中注册 Microsoft.CognitiveServices"
      return 2
    fi
    log_info "正在订阅 $subscription_id 中注册 Microsoft.CognitiveServices"
    az provider register --namespace Microsoft.CognitiveServices --only-show-errors >/dev/null
    started=$(date +%s)
    while true; do
      state=$(az_json provider show --namespace Microsoft.CognitiveServices | jq -r '.registrationState // ""')
      [[ "$state" == "Registered" ]] && break
      if (($(date +%s) - started >= 600)); then
        echo "订阅 $subscription_id 注册 Microsoft.CognitiveServices 超时。" >&2
        return 1
      fi
      sleep 5
    done
    log_info "订阅 $subscription_id 的 Microsoft.CognitiveServices 已注册完成"
  fi
  REGISTERED_SUBSCRIPTIONS="${REGISTERED_SUBSCRIPTIONS}${subscription_id}|"
  return 0
}

wait_arm_provisioning() {
  local description="$1" url="$2" started state
  started=$(date +%s)
  while true; do
    state=$(az_rest_retry GET "$url" | jq -r '.properties.provisioningState // ""')
    if [[ "$state" == "Succeeded" ]]; then log_info "$description 已就绪"; return 0; fi
    case "$state" in Failed|Canceled|Deleted) echo "$description 进入终止状态 $state" >&2; return 1 ;; esac
    if (($(date +%s) - started >= 900)); then echo "$description 超时，最后状态为 $state" >&2; return 1; fi
    sleep 5
  done
}

stage_create_foundry() {
  log_info '========== 阶段：创建 Foundry 服务和 Foundry 项目 =========='
  local rows_file="$TEMP_DIR/rows_stage2.jsonl"
  load_plan 'CreateFoundry' > "$rows_file"
  load_account_list

  local row_json count=0
  while IFS= read -r row_json; do
    count=$((count + 1))
    printf '  %s | %s | %s | %s | %s | %s\n' \
      "$(csv_field "$row_json" 'SubscriptionName')" "$(csv_field "$row_json" 'SubscriptionId')" \
      "$(csv_field "$row_json" 'ResourceGroupName')" "$(csv_field "$row_json" 'FoundryResourceName')" \
      "$(csv_field "$row_json" 'DefaultProjectName')" "$(csv_field "$row_json" 'Location')" >&2
  done < "$rows_file"
  confirm_execution "将为 $count 个订阅创建 Foundry 资源" || return 0

  write_result_header 'stage2_foundry_provisioning' SubscriptionName SubscriptionId ResourceGroupName \
    FoundryResourceName DefaultProjectName Location ResourceGroupStatus FoundryStatus ProjectStatus ErrorMessage

  local ok=0
  while IFS= read -r row_json; do
    local sub_name sub_id rg foundry project location
    sub_name=$(csv_field "$row_json" 'SubscriptionName')
    sub_id=$(csv_field "$row_json" 'SubscriptionId')
    rg=$(csv_field "$row_json" 'ResourceGroupName')
    foundry=$(csv_field "$row_json" 'FoundryResourceName')
    project=$(csv_field "$row_json" 'DefaultProjectName')
    location=$(csv_field "$row_json" 'Location')

    local group_status='Pending' foundry_status='Pending' project_status='Pending' error_message=''
    log_info "检查订阅 '$sub_name'（${sub_id}）"

    if ! error_message=$(resolve_subscription "$row_json" 2>&1 >/dev/null); then
      log_error "$error_message"
      write_result_row "$sub_name" "$sub_id" "$rg" "$foundry" "$project" "$location" NotStarted NotStarted NotStarted "$error_message"
      ok=1
      continue
    fi

    local location_count
    location_count=$(az_json account list-locations | jq --arg l "$(printf '%s' "$location" | tr '[:upper:]' '[:lower:]')" \
      '[.[]? | select((.name // "" | ascii_downcase) == $l)] | length')
    if ((location_count == 0)); then
      error_message="区域 '$location' 在订阅 $sub_id 中不可用。"
      log_error "$error_message"
      write_result_row "$sub_name" "$sub_id" "$rg" "$foundry" "$project" "$location" NotStarted NotStarted NotStarted "$error_message"
      ok=1
      continue
    fi

    local provider_state=0
    ensure_provider_registered "$sub_id" || provider_state=$?
    if ((provider_state == 1)); then
      write_result_row "$sub_name" "$sub_id" "$rg" "$foundry" "$project" "$location" NotStarted NotStarted NotStarted "Provider 注册失败"
      ok=1
      continue
    fi

    local group_json
    if group_json=$(az_json group show --name "$rg" 2>/dev/null); then
      local existing_location
      existing_location=$(printf '%s' "$group_json" | jq -r '.location // ""' | tr '[:upper:]' '[:lower:]')
      if [[ -n "$existing_location" && "$existing_location" != "$(printf '%s' "$location" | tr '[:upper:]' '[:lower:]')" ]]; then
        error_message="资源组 '$rg' 位于 '$existing_location'，与目标区域 '$location' 不一致。"
        log_error "$error_message"
        write_result_row "$sub_name" "$sub_id" "$rg" "$foundry" "$project" "$location" Conflict NotStarted NotStarted "$error_message"
        ok=1
        continue
      fi
      group_status='SkippedExisting'
    elif [[ "$DRY_RUN" == true ]]; then
      group_status='WhatIf'
    else
      az_json group create --name "$rg" --location "$location" >/dev/null
      group_status='Succeeded'
    fi

    if ((provider_state == 2)); then
      write_result_row "$sub_name" "$sub_id" "$rg" "$foundry" "$project" "$location" "$group_status" WhatIf WhatIf ""
      continue
    fi

    local encoded_rg encoded_account encoded_project account_url project_url
    encoded_rg=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$rg")
    encoded_account=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$foundry")
    encoded_project=$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$project")
    account_url="https://management.azure.com/subscriptions/${sub_id}/resourceGroups/${encoded_rg}/providers/Microsoft.CognitiveServices/accounts/${encoded_account}?api-version=2025-06-01"
    project_url="${account_url%%\?*}/projects/${encoded_project}?api-version=2025-06-01"

    local account_json=""
    if account_json=$(az_rest GET "$account_url" 2>/dev/null); then
      local kind existing_domain existing_location
      kind=$(printf '%s' "$account_json" | jq -r '.kind // ""')
      existing_domain=$(printf '%s' "$account_json" | jq -r '.properties.customSubDomainName // ""')
      existing_location=$(printf '%s' "$account_json" | jq -r '.location // ""' | tr '[:upper:]' '[:lower:]')
      if [[ "$kind" != "AIServices" || "$existing_domain" != "$foundry" || "$existing_location" != "$(printf '%s' "$location" | tr '[:upper:]' '[:lower:]')" ]]; then
        error_message="Foundry 账户 '$foundry' 已存在但类型、区域或自定义域名不一致。"
        log_error "$error_message"
        write_result_row "$sub_name" "$sub_id" "$rg" "$foundry" "$project" "$location" "$group_status" Conflict NotStarted "$error_message"
        ok=1
        continue
      fi
      foundry_status='SkippedExisting'
    elif [[ "$DRY_RUN" == true ]]; then
      write_result_row "$sub_name" "$sub_id" "$rg" "$foundry" "$project" "$location" "$group_status" WhatIf WhatIf ""
      continue
    else
      local body_file error_file
      body_file="$TEMP_DIR/account-${sub_id}.json"
      error_file="$TEMP_DIR/account-${sub_id}.error"
      jq -n --arg loc "$location" --arg domain "$foundry" \
        '{location:$loc, kind:"AIServices", sku:{name:"S0"}, identity:{type:"SystemAssigned"},
          properties:{customSubDomainName:$domain, allowProjectManagement:true}}' > "$body_file"
      if ! az_rest PUT "$account_url" "$body_file" >/dev/null 2>"$error_file"; then
        error_message=$(tr '\n' ' ' < "$error_file")
        if [[ "$error_message" == *CustomDomainInUse* ]]; then
          error_message="CustomDomainInUse：'$foundry' 已被占用，请更换 FoundryResourceName。"
        fi
        log_error "$error_message"
        write_result_row "$sub_name" "$sub_id" "$rg" "$foundry" "$project" "$location" "$group_status" Failed NotStarted "$error_message"
        ok=1
        continue
      fi
      if ! error_message=$(wait_arm_provisioning "Foundry 账户 '$foundry'" "$account_url" 2>&1 >/dev/null); then
        write_result_row "$sub_name" "$sub_id" "$rg" "$foundry" "$project" "$location" "$group_status" Failed NotStarted "$error_message"
        ok=1
        continue
      fi
      foundry_status='Succeeded'
    fi

    if az_rest GET "$project_url" >/dev/null 2>&1; then
      project_status='SkippedExisting'
    elif [[ "$DRY_RUN" == true ]]; then
      project_status='WhatIf'
    else
      local body_file error_file
      body_file="$TEMP_DIR/project-${sub_id}.json"
      error_file="$TEMP_DIR/project-${sub_id}.error"
      jq -n --arg loc "$location" --arg name "$project" \
        '{location:$loc, identity:{type:"SystemAssigned"}, properties:{displayName:$name}}' > "$body_file"
      if ! az_rest PUT "$project_url" "$body_file" >/dev/null 2>"$error_file"; then
        error_message=$(tr '\n' ' ' < "$error_file")
        log_error "$error_message"
        write_result_row "$sub_name" "$sub_id" "$rg" "$foundry" "$project" "$location" "$group_status" "$foundry_status" Failed "$error_message"
        ok=1
        continue
      fi
      wait_arm_provisioning "Foundry Project '$project'" "$project_url" || true
      project_status='Succeeded'
    fi

    write_result_row "$sub_name" "$sub_id" "$rg" "$foundry" "$project" "$location" "$group_status" "$foundry_status" "$project_status" ""
  done < "$rows_file"

  log_info "结果文件：$RESULT_FILE"
  return $ok
}

# ==================== 阶段 3：批量部署模型 ====================

stage_deploy_models() {
  log_info '========== 阶段：批量部署模型 =========='
  local rows_file="$TEMP_DIR/rows_stage3.jsonl"
  load_plan 'DeployModels' > "$rows_file"
  load_account_list

  local row_json count=0
  while IFS= read -r row_json; do
    count=$((count + 1))
    local deployments="" dep_name model version format sku_item
    while IFS=$'\t' read -r dep_name model version format sku_item; do
      [[ -z "$model" ]] && continue
      if [[ "$dep_name" == "$model" ]]; then
        deployments="${deployments}${deployments:+, }${model}"
      else
        deployments="${deployments}${deployments:+, }${dep_name}(${model})"
      fi
    done < <(expand_models "$row_json")
    printf '  %s | %s | 部署: %s | 类型: %s\n' \
      "$(csv_field "$row_json" 'SubscriptionName')" "$(csv_field "$row_json" 'FoundryResourceName')" \
      "$deployments" "$(deployment_type_of "$row_json")" >&2
  done < "$rows_file"
  confirm_execution "将在 $count 个 Foundry 账户中部署模型" || return 0

  write_result_header 'stage3_model_deployment' SubscriptionName FoundryResourceName ModelName DeploymentType CapacityK Status ErrorMessage

  local ok=0
  while IFS= read -r row_json; do
    local sub_name foundry sku location existing error_message
    sub_name=$(csv_field "$row_json" 'SubscriptionName')
    foundry=$(csv_field "$row_json" 'FoundryResourceName')
    sku=$(deployment_type_of "$row_json")

    log_info "处理 '$sub_name' / '$foundry'"
    if ! error_message=$(resolve_subscription "$row_json" 2>&1 >/dev/null); then
      log_error "$error_message"
      write_result_row "$sub_name" "$foundry" "" "$sku" 0 Failed "$error_message"
      ok=1
      continue
    fi
    if ! location=$(get_account_location "$row_json" 2>/dev/null); then
      log_error "$sub_name: 无法读取 Foundry 账户区域。"
      write_result_row "$sub_name" "$foundry" "" "$sku" 0 Failed "无法读取 Foundry 账户区域"
      ok=1
      continue
    fi
    local existing_raw=""
    existing_raw=$(get_existing_deployments "$row_json" || true)

    local dep_name model version format sku_item
    while IFS=$'\t' read -r dep_name model version format sku_item; do
      [[ -z "$model" ]] && continue
      local actual_sku="${sku_item:-$sku}"
      local target_dep_name="${dep_name:-$model}"

      # 必须同时匹配部署名、模型名以及 SKU 类型（忽略空格与大小写差异）
      local existing_match=""
      if [[ -n "$existing_raw" ]]; then
        while IFS=$'\t' read -r ex_name ex_model ex_fmt ex_ver ex_sku ex_cap; do
          local norm_ex_name norm_ex_model norm_ex_sku norm_target_sku norm_target_name norm_target_model
          norm_ex_name=$(printf '%s' "$ex_name" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
          norm_ex_model=$(printf '%s' "$ex_model" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
          norm_ex_sku=$(printf '%s' "$ex_sku" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
          norm_target_sku=$(printf '%s' "$actual_sku" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
          norm_target_name=$(printf '%s' "$target_dep_name" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
          norm_target_model=$(printf '%s' "$model" | tr -d ' ' | tr '[:upper:]' '[:lower:]')

          if [[ "$norm_ex_name" == "$norm_target_name" && "$norm_ex_model" == "$norm_target_model" && "$norm_ex_sku" == "$norm_target_sku" ]]; then
            existing_match="true"
            break
          fi
        done <<< "$existing_raw"
      fi

      if [[ "$existing_match" == "true" ]]; then
        log_info "  ${target_dep_name}（${actual_sku}）：部署已存在且类型一致，跳过"
        write_result_row "$sub_name" "$foundry" "$target_dep_name" "$actual_sku" 0 SkippedExisting ""
        continue
      fi

      local quota total used remaining configured capacity
      quota=$(get_quota "$(csv_field "$row_json" 'SubscriptionId')" "$location" "$model" "$actual_sku")
      if [[ "$quota" == "NOTFOUND" ]]; then
        error_message="区域 $location 没有 $actual_sku + $model 的配额项，请确认该区域是否提供此模型与 SKU。"
        log_error "  $error_message"
        write_result_row "$sub_name" "$foundry" "$target_dep_name" "$actual_sku" 0 Failed "$error_message"
        ok=1
        continue
      fi
      total=${quota%%|*}
      used=${quota##*|}
      total=${total%.*}
      used=${used%.*}
      remaining=$((total - used))
      ((remaining < 0)) && remaining=0

      configured=$(csv_field "$row_json" 'DeploymentCapacityK')
      if [[ "$configured" =~ ^[0-9]+$ ]] && ((configured > 0)) && ((configured < remaining)); then
        capacity=$configured
      else
        capacity=$remaining
      fi

      log_info "  ${target_dep_name}（${actual_sku}）：总配额 $(format_capacity "$total")，已分配 $(format_capacity "$used")，剩余 $(format_capacity "$remaining")，本次部署 $(format_capacity "$capacity")"
      if ((capacity <= 0)); then
        write_result_row "$sub_name" "$foundry" "$target_dep_name" "$actual_sku" 0 NoQuota "剩余配额为 0，已跳过。"
        continue
      fi

      if set_deployment "$row_json" "$target_dep_name" "$model" "$version" "$format" "$actual_sku" "$capacity"; then
        local status='Succeeded'
        [[ "$DRY_RUN" == true ]] && status='WhatIf'
        write_result_row "$sub_name" "$foundry" "$target_dep_name" "$actual_sku" "$capacity" "$status" ""
      else
        log_error "  ${target_dep_name}：部署创建失败。"
        write_result_row "$sub_name" "$foundry" "$target_dep_name" "$actual_sku" "$capacity" Failed "部署创建失败"
        ok=1
      fi
    done < <(expand_models "$row_json")
  done < "$rows_file"

  log_info "结果文件：$RESULT_FILE"
  return $ok
}

# ==================== 阶段 4：批量扩容配额 ====================

stage_scale_up_quota() {
  log_info '========== 阶段：批量扩容已有部署 =========='
  local rows_file="$TEMP_DIR/rows_stage4.jsonl"
  load_plan 'ScaleUpQuota' > "$rows_file"
  load_account_list

  local row_json count=0
  while IFS= read -r row_json; do
    count=$((count + 1))
    local models
    models=$(expand_models "$row_json" | cut -f2 | paste -sd ',' - | sed 's/,/, /g')
    printf '  %s | %s | 目标模型: %s\n' \
      "$(csv_field "$row_json" 'SubscriptionName')" "$(csv_field "$row_json" 'FoundryResourceName')" "$models" >&2
  done < "$rows_file"
  confirm_execution "将扩容 $count 个 Foundry 账户中的已有部署" || return 0

  write_result_header 'stage4_quota_scale_up' SubscriptionName FoundryResourceName DeploymentName CurrentK TargetK IncreaseK Status ErrorMessage

  local ok=0
  while IFS= read -r row_json; do
    local sub_name foundry location error_message targets
    sub_name=$(csv_field "$row_json" 'SubscriptionName')
    foundry=$(csv_field "$row_json" 'FoundryResourceName')

    log_info "处理 '$sub_name' / '$foundry'"
    if ! error_message=$(resolve_subscription "$row_json" 2>&1 >/dev/null); then
      log_error "$error_message"
      write_result_row "$sub_name" "$foundry" "" 0 0 0 Failed "$error_message"
      ok=1
      continue
    fi
    if ! location=$(get_account_location "$row_json" 2>/dev/null); then
      log_error "$sub_name: 无法读取 Foundry 账户区域。"
      write_result_row "$sub_name" "$foundry" "" 0 0 0 Failed "无法读取 Foundry 账户区域"
      ok=1
      continue
    fi

    targets=$(expand_models "$row_json" | cut -f2)
    local deployment_name model_name model_format model_version sku_name capacity
    while IFS=$'\t' read -r deployment_name model_name model_format model_version sku_name capacity; do
      [[ -z "$deployment_name" ]] && continue
      printf '%s\n' "$targets" | grep -Fxq "$model_name" || continue

      local quota total used remaining target increase
      quota=$(get_quota "$(csv_field "$row_json" 'SubscriptionId')" "$location" "$model_name" "$sku_name")
      if [[ "$quota" == "NOTFOUND" ]]; then
        log_warn "  ${deployment_name}：未找到配额项，跳过。"
        write_result_row "$sub_name" "$foundry" "$deployment_name" "$capacity" "$capacity" 0 Skipped "未找到配额项"
        continue
      fi
      total=${quota%%|*}
      used=${quota##*|}
      total=${total%.*}
      used=${used%.*}
      remaining=$((total - used))
      ((remaining < 0)) && remaining=0
      target=$((capacity + remaining))
      increase=$((target - capacity))

      log_info "  ${deployment_name}：当前 $(format_capacity "$capacity")，共享已分配 $(format_capacity "$used")，总配额 $(format_capacity "$total")，剩余 $(format_capacity "$remaining")，预计提升 $(format_capacity "$increase")"
      if ((remaining <= 0)); then
        write_result_row "$sub_name" "$foundry" "$deployment_name" "$capacity" "$target" 0 Skipped ""
        continue
      fi

      if set_deployment "$row_json" "$deployment_name" "$model_name" "$model_version" "$model_format" "$sku_name" "$target"; then
        local status='Succeeded'
        [[ "$DRY_RUN" == true ]] && status='WhatIf'
        write_result_row "$sub_name" "$foundry" "$deployment_name" "$capacity" "$target" "$increase" "$status" ""
      else
        log_error "  ${deployment_name}：扩容失败。"
        write_result_row "$sub_name" "$foundry" "$deployment_name" "$capacity" "$target" "$increase" Failed "扩容失败"
        ok=1
      fi
    done < <(get_existing_deployments "$row_json")
  done < "$rows_file"

  log_info "结果文件：$RESULT_FILE"
  return $ok
}

# ==================== 交互菜单与入口 ====================

show_menu() {
  cat >&2 <<'EOF'

========== Azure Foundry 全生命周期工具 ==========
  1) 创建 Azure 订阅（仅限 EA 企业协议订阅，回填 SubscriptionId）
  2) 创建 Foundry 服务和 Foundry 项目
  3) 批量部署模型（按剩余配额）
  4) 批量扩容已有部署配额
  5) 全流程（1 -> 2 -> 3）
  0) 退出

EOF
  printf '请选择要执行的阶段：' >&2
  local choice
  IFS= read -r choice
  case "$choice" in
    1) printf 'CreateSubscription' ;;
    2) printf 'CreateFoundry' ;;
    3) printf 'DeployModels' ;;
    4) printf 'ScaleUpQuota' ;;
    5) printf 'All' ;;
    0) printf '' ;;
    *) echo "无效选项：$choice" >&2; exit 2 ;;
  esac
}

confirm_environment
[[ -z "$STAGE" ]] && STAGE=$(show_menu)
if [[ -z "$STAGE" ]]; then log_info '已退出。'; exit 0; fi

log_info "租户：$TENANT_ID"
log_info "规划 CSV：$CSV_PATH"
log_info "执行阶段：$STAGE"
if [[ "$DRY_RUN" == true ]]; then
  log_info "运行模式：预演模式（DryRun）"
else
  log_info "运行模式：正式模式（Live）"
fi

azure_login

EXIT_CODE=0
case "$STAGE" in
  CreateSubscription) stage_create_subscription || EXIT_CODE=1 ;;
  CreateFoundry) stage_create_foundry || EXIT_CODE=1 ;;
  DeployModels) stage_deploy_models || EXIT_CODE=1 ;;
  ScaleUpQuota) stage_scale_up_quota || EXIT_CODE=1 ;;
  All)
    stage_create_subscription || EXIT_CODE=1
    stage_create_foundry || EXIT_CODE=1
    stage_deploy_models || EXIT_CODE=1
    ;;
  *) echo "未知阶段：$STAGE" >&2; exit 2 ;;
esac

log_info "日志文件：$LOG_FILE"
exit $EXIT_CODE
