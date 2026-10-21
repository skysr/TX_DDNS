#!/bin/bash
#===============================================================================
#
#          FILE: ddnsv2.sh
#
#         USAGE: ./ddnsv2.sh [选项] [命令]
#
#   DESCRIPTION: TX_DDNS - DNSPod 动态 DNS 更新脚本
#                自动检测本机 IP 变化并更新腾讯云 DNSPod 的 DNS 记录
#                支持 IPv4 (A记录) 和 IPv6 (AAAA记录)
#
#        AUTHOR: skysr
#       VERSION: 2.3.0
#       CREATED: 2024
#      REPOSITORY: https://github.com/skysr/TX_DDNS
#
#       FEATURES:
#         - 自动检测本地 IPv4/IPv6 地址变化
#         - 支持 DNSPod API 更新 DNS 记录
#         - 支持多网卡指定（NETWORK_INTERFACE）
#         - 支持强制周期更新（防止 DNS 记录过期）
#         - 支持 Webhook 通知（Discord/Slack/Telegram/自定义）
#         - 完善的日志记录和历史追踪
#         - 防止并发执行的锁机制
#         - 自动日志轮转
#
#       DEPENDENCIES:
#         - bash 4.0+
#         - curl (HTTP 请求)
#         - ip (iproute2, 获取本地 IP)
#         - ping (网络连通性测试)
#
#       CRON EXAMPLE:
#         # 每 5 分钟检查一次 IP 变化
#         */5 * * * * /path/to/ddnsv2.sh -q
#
#===============================================================================
#
# 配置说明:
#
#   在 ddnsv2.conf 中配置以下必填项:
#
#   LOGIN_TOKEN     - DNSPod API Token，格式: "ID,Token"
#                     获取方式: https://console.dnspod.cn/account/token/token
#
#   DOMAIN_ID       - 域名 ID，通过 DNSPod API 获取
#                     或在 DNSPod 控制台 URL 中查看
#
#   RECORD_ID       - 记录 ID，通过 DNSPod API 获取
#                     或在 DNSPod 控制台 URL 中查看
#
#   SUB_DOMAIN      - 子域名，如 "www"、"@"（主域名）、"*"（泛解析）
#
#   RECORD_TYPE     - 记录类型，支持 "A" (IPv4) 或 "AAAA" (IPv6)
#
#   NETWORK_INTERFACE - 可选，指定网卡名称，如 "eth0"、"ens33"
#                       不填则自动选择第一个公网 IP
#
#===============================================================================

set -e  # 遇到错误立即退出

#-------------------------------------------------------------------------------
# 全局常量定义
#-------------------------------------------------------------------------------

readonly VERSION="2.6.0"                    # 脚本版本号
readonly SCRIPT_NAME=$(basename "$0")        # 脚本名称

# 脚本所在目录（用于定位配置文件）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 默认配置文件路径：优先使用系统安装路径 /etc/ddns/ddns.conf，
# 其次回退到脚本同目录的 ddnsv2.conf（便于源码目录直接运行）
if [ -f "/etc/ddns/ddns.conf" ]; then
    CONFIG_FILE="/etc/ddns/ddns.conf"
else
    CONFIG_FILE="${SCRIPT_DIR}/ddnsv2.conf"
fi

#-------------------------------------------------------------------------------
# 记录列表（多记录模式）
#
# 每条记录由 6 个字段组成，以 "|" 分隔：
#   子域名|域名ID|记录ID|记录类型|网卡|TTL
#
# 子域名可为 www / @ (主域名) / * (泛解析)
# 后三个字段留空时回退到全局配置
#
# 统一用并行数组存储，索引即记录编号
#-------------------------------------------------------------------------------
declare -a REC_SUB=()        # 子域名
declare -a REC_DOMAIN=()     # 域名 ID
declare -a REC_ID=()         # 记录 ID
declare -a REC_TYPE=()       # 记录类型 (A/AAAA)
declare -a REC_IFACE=()      # 网卡
declare -a REC_TTL=()        # TTL
REC_COUNT=0                 # 记录总数

# 每条记录的状态文件后缀（用于隔离 db/flag）
declare -a REC_KEY=()

# 当前正在处理的记录（供 send_webhook 等函数读取）
CURRENT_REC_TYPE=""

# history 命令的子域名过滤条件
HISTORY_FILTER=""

# records 命令参数
RECORDS_TARGET=""
RECORDS_GENERATE=0

#-------------------------------------------------------------------------------
# 默认配置值
# 可在配置文件中覆盖
#-------------------------------------------------------------------------------

LOG_DIR='/var/log/ddns'           # 日志存储目录
LOCK_DIR='/var/lock'              # 锁文件目录
FORCE_UPDATE_CYCLE=60             # 强制更新周期（次）
                                  # 即使 IP 未变化，每 N 次检查也强制更新一次
                                  # 防止 DNS 记录因 TTL 过期或被篡改
LOG_MAX_SIZE=1048576              # 日志文件最大大小（字节），默认 1MB
MAX_RETRY=3                       # API 调用失败时的最大重试次数
RETRY_DELAY=2                     # 重试间隔（秒）
VERBOSE=0                         # 详细输出模式（0=关闭，1=开启）
QUIET=0                           # 静默模式（0=关闭，1=开启，仅输出错误）

DEFAULT_TTL=600                   # DNS 记录默认 TTL（秒）

#-------------------------------------------------------------------------------
# 运行时变量（延迟初始化）
#-------------------------------------------------------------------------------

DB_FILE=""                        # 存储 IP 地址的数据库文件
FLAG_FILE=""                      # 更新计数器文件
LOG_FILE=""                       # 日志文件路径
LOCK_FILE=""                      # 锁文件路径
PID_FILE=""                       # PID 文件路径
HISTORY_FILE=""   # 更新历史记录文件

#===============================================================================
# 信号处理与清理
#===============================================================================

#-------------------------------------------------------------------------------
# FUNCTION: cleanup
# DESCRIPTION: 脚本退出时的清理函数，由 trap 自动调用
#              - 释放文件锁
#              - 清理 PID 文件
#              - 输出调试信息（verbose 模式）
# PARAMETERS: 无
# RETURNS: 脚本的原始退出码
#-------------------------------------------------------------------------------
cleanup() {
    local exit_code=$?

    # 释放锁：只有当前 PID 拥有锁时才清理
    if [ -f "$PID_FILE" ]; then
        local lock_pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ "$lock_pid" = "$$" ]; then
            # LOCK_FILE 是目录（mkdir 原子锁），必须用 rm -rf，rm -f 删不掉目录
            rm -f "$PID_FILE" 2>/dev/null || true
            rm -rf "$LOCK_FILE" 2>/dev/null || true
        fi
    fi

    # 详细模式下输出退出信息
    if [ $VERBOSE -eq 1 ] && [ $exit_code -ne 0 ]; then
        echo "[INFO] 脚本退出 (code: $exit_code)"
    fi
    exit $exit_code
}

# 注册信号处理：EXIT（正常退出）、INT（Ctrl+C）、TERM（kill 命令）
trap cleanup EXIT INT TERM

#===============================================================================
# 日志系统
#===============================================================================

#-------------------------------------------------------------------------------
# FUNCTION: log
# DESCRIPTION: 核心日志函数，统一处理日志输出
# PARAMETERS:
#   $1 - 日志级别 (INFO/WARN/ERROR/DEBUG)
#   $@ - 日志内容
# OUTPUT:
#   - 控制台输出（根据 verbose/quiet 设置过滤）
#   - 文件输出（写入 LOG_FILE）
#-------------------------------------------------------------------------------
log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # 静默模式：只输出 ERROR 级别
    if [ "$QUIET" -eq 1 ] && [ "$level" != "ERROR" ]; then
        return
    fi

    # 详细模式输出所有级别，否则只输出 INFO 和 ERROR
    if [ "$VERBOSE" -eq 1 ] || [ "$level" = "ERROR" ] || [ "$level" = "INFO" ]; then
        echo "[$timestamp] [$level] $msg"
    fi

    # 写入日志文件
    if [ -n "$LOG_FILE" ] && [ -d "$LOG_DIR" ]; then
        echo "[$timestamp] [$level] $msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# 日志级别快捷函数
log_info()  { log "INFO" "$@"; }   # 一般信息
log_warn()  { log "WARN" "$@"; }   # 警告信息
log_error() { log "ERROR" "$@"; }  # 错误信息
log_debug() { log "DEBUG" "$@"; }  # 调试信息（仅 verbose 模式）

#===============================================================================
# 命令行解析
#===============================================================================

#-------------------------------------------------------------------------------
# FUNCTION: parse_args
# DESCRIPTION: 解析命令行参数，设置全局变量
# PARAMETERS: $@ - 命令行参数
# GLOBALS:
#   VERBOSE      - 设置为 1 表示详细输出
#   QUIET        - 设置为 1 表示静默模式
#   CONFIG_FILE  - 配置文件路径
#   COMMAND      - 要执行的命令 (run/status/test/history)
#-------------------------------------------------------------------------------
parse_args() {
    local command=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            -q|--quiet)
                QUIET=1
                shift
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -V|--version)
                echo "TX_DDNS v${VERSION}"
                exit 0
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            run|status|test|history|list|records)
                command="$1"
                shift
                # history 支持按子域名过滤: ddnsv2.sh history www
                if [ "$command" = "history" ] && [ $# -gt 0 ] && [[ "$1" != -* ]]; then
                    HISTORY_FILTER="$1"
                    shift
                fi
                # records 支持指定域名与 --generate: ddnsv2.sh records example.com --generate
                # 全局选项 (-c/-v/-q) 仍由外层 case 处理，此处只取子命令自己的参数
                if [ "$command" = "records" ]; then
                    while [ $# -gt 0 ]; do
                        case "$1" in
                            --generate)
                                RECORDS_GENERATE=1
                                shift
                                ;;
                            -c|-v|-q|-V|-h|--verbose|--quiet|--config|--version|--help)
                                # 全局选项：交回外层处理
                                break
                                ;;
                            -*)
                                log_error "未知选项: $1"
                                exit 1
                                ;;
                            *)
                                RECORDS_TARGET="$1"
                                shift
                                ;;
                        esac
                    done
                fi
                ;;
            *)
                log_error "未知参数: $1"
                echo "使用 -h 查看帮助信息"
                exit 1
                ;;
        esac
    done

    # 默认命令是 run（执行 DDNS 更新）
    COMMAND="${command:-run}"
}

#-------------------------------------------------------------------------------
# FUNCTION: show_help
# DESCRIPTION: 显示帮助信息和使用示例
#-------------------------------------------------------------------------------
show_help() {
    cat << EOF
TX_DDNS v${VERSION} - DNSPod 动态 DNS 更新脚本

用法: $SCRIPT_NAME [选项] [命令]

命令:
  run       运行 DDNS 更新（默认，更新所有记录）
  status    显示当前 DNS 记录和本地 IP 状态
  test      测试配置，不实际更新 DNS
  history   显示更新历史记录
  list      列出已配置的记录
  records   从 DNSPod 拉取域名的解析记录

选项:
  -v, --verbose     详细输出模式
  -q, --quiet       静默模式（仅输出错误）
  -c, --config      指定配置文件路径
  -V, --version     显示版本信息
  -h, --help        显示帮助信息

示例:
  $SCRIPT_NAME              # 运行更新（所有记录）
  $SCRIPT_NAME status       # 查看状态
  $SCRIPT_NAME test         # 测试配置
  $SCRIPT_NAME list         # 列出所有记录
  $SCRIPT_NAME records example.com             # 查看域名的解析记录
  $SCRIPT_NAME records example.com --generate  # 生成记录列表文件
  $SCRIPT_NAME history      # 查看历史
  $SCRIPT_NAME history www  # 只看 www 子域名的历史
  $SCRIPT_NAME -v           # 详细输出

更多信息: https://github.com/skysr/TX_DDNS
EOF
}

#===============================================================================
# 配置管理
#===============================================================================

#-------------------------------------------------------------------------------
# FUNCTION: load_config
# DESCRIPTION: 从配置文件加载配置项
#              使用安全的解析方式，防止命令注入
# PARAMETERS: 无
# RETURNS: 成功返回 0，配置文件不存在则退出
#-------------------------------------------------------------------------------
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "配置文件不存在: $CONFIG_FILE"
        log_error "请复制 ddnsv2.conf.example 为 ddnsv2.conf 并填写配置"
        exit 1
    fi

    # 安全加载配置：逐行解析，只允许特定变量
    while IFS='=' read -r key value || [ -n "$key" ]; do
        # 跳过注释行（以 # 开头）
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        # 跳过空行
        [[ -z "$key" ]] && continue

        # 去除首尾空格
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)

        # 去除引号（单引号和双引号）
        value="${value#\'}"
        value="${value%\'}"
        value="${value#\"}"
        value="${value%\"}"

        # 只允许预定义的配置项（安全白名单）
        case "$key" in
            LOGIN_TOKEN|DOMAIN_ID|RECORD_ID|SUB_DOMAIN|RECORD_TYPE|NETWORK_INTERFACE|LOG_DIR|LOCK_DIR|FORCE_UPDATE_CYCLE|MAX_RETRY|RETRY_DELAY|RECORD_TTL|WEBHOOK_URL|WEBHOOK_METHOD|WEBHOOK_CHAT_ID|HISTORY_MAX|RECORDS_FILE)
                declare -g "$key=$value"
                ;;
        esac
    done < "$CONFIG_FILE"

    # 验证配置完整性
    validate_config
}

#-------------------------------------------------------------------------------
# FUNCTION: record_key
# DESCRIPTION: 为一条记录生成唯一的状态文件标识
#              用于隔离每条记录的 db/flag 文件
# PARAMETERS:
#   $1 - 子域名
#   $2 - 记录类型
#   $3 - 域名 ID
# OUTPUT: 安全的文件名片段
#-------------------------------------------------------------------------------
record_key() {
    local sub="$1"
    local type="$2"
    local domain="$3"
    # 子域名可能含 @ (主域名) 和 * (泛解析)，需要转义成安全字符。
    # 注意：不能简单地把所有非字母数字字符都替换成 '_'，因为 '@' 和 '*'
    # 都会变成 '_'，导致不同记录生成相同的 key、状态文件互相覆盖。
    # 这里做一一映射，保证不同子域名产生不同 key。
    local safe_sub
    safe_sub=$(printf '%s' "$sub" | sed -e 's/@/_at_/g' -e 's/\*/_star_/g' \
                                 -e 's/[^a-zA-Z0-9._-]/_/g')
    printf '%s_%s_%s' "$safe_sub" "$type" "$domain"
}

#-------------------------------------------------------------------------------
# FUNCTION: parse_record_line
# DESCRIPTION: 解析一行记录定义，填充全局记录数组
#              格式: 子域名|域名ID|记录ID|记录类型|网卡|TTL
#              后三个字段留空时回退到全局配置
# PARAMETERS: $1 - 记录行内容
# RETURNS: 成功返回 0，格式错误返回 1
#-------------------------------------------------------------------------------
parse_record_line() {
    local line="$1"

    # 按 | 分割，最多 6 段
    IFS='|' read -r sub domain rid rtype iface ttl extra <<< "$line"

    # 第 7 段说明格式错误
    if [ -n "${extra:-}" ]; then
        log_error "记录格式错误（字段过多）: $line"
        log_error "正确格式: 子域名|域名ID|记录ID|记录类型|网卡|TTL"
        return 1
    fi

    # 前三个字段必填
    if [ -z "${sub:-}" ] || [ -z "${domain:-}" ] || [ -z "${rid:-}" ]; then
        log_error "记录缺少必要字段（子域名/域名ID/记录ID）: $line"
        return 1
    fi

    # 后三个字段回退到全局配置
    [ -z "${rtype:-}" ] && rtype="$RECORD_TYPE"
    [ -z "${iface:-}" ] && iface="$NETWORK_INTERFACE"
    [ -z "${ttl:-}" ] && ttl="$RECORD_TTL"

    # 校验记录类型
    if [[ ! "$rtype" =~ ^(A|AAAA)$ ]]; then
        log_error "记录类型必须是 A 或 AAAA: $line"
        return 1
    fi

    # 校验 TTL 为正整数
    if ! [[ "$ttl" =~ ^[0-9]+$ ]] || [ "$ttl" -lt 1 ]; then
        log_error "TTL 必须是正整数: $line"
        return 1
    fi

    # 追加到数组
    REC_SUB+=("$sub")
    REC_DOMAIN+=("$domain")
    REC_ID+=("$rid")
    REC_TYPE+=("$rtype")
    REC_IFACE+=("$iface")
    REC_TTL+=("$ttl")
    REC_KEY+=("$(record_key "$sub" "$rtype" "$domain")")
    REC_COUNT=$((REC_COUNT + 1))

    log_debug "加载记录 $REC_COUNT: $sub ($rtype) domain=$domain id=$rid"
    return 0
}

#-------------------------------------------------------------------------------
# FUNCTION: load_records
# DESCRIPTION: 加载记录列表
#              优先读取 RECORDS_FILE 指定的多记录文件；
#              若未配置或文件不存在，则回退到配置文件中的单条记录
#              （保持与 v2.4.0 的向后兼容）
# PARAMETERS: 无
# RETURNS: 成功返回 0，无有效记录返回 1
#-------------------------------------------------------------------------------
load_records() {
    REC_COUNT=0
    REC_SUB=(); REC_DOMAIN=(); REC_ID=(); REC_TYPE=()
    REC_IFACE=(); REC_TTL=(); REC_KEY=()

    if [ -n "${RECORDS_FILE:-}" ] && [ -f "$RECORDS_FILE" ]; then
        local line
        local lineno=0
        while IFS= read -r line || [ -n "$line" ]; do
            lineno=$((lineno + 1))
            # 去除首尾空白
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            # 跳过空行和注释
            [ -z "$line" ] && continue
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            if ! parse_record_line "$line"; then
                log_error "记录文件第 $lineno 行解析失败: $RECORDS_FILE"
                return 1
            fi
        done < "$RECORDS_FILE"

        if [ "$REC_COUNT" -gt 0 ]; then
            log_info "已加载 $REC_COUNT 条记录: $RECORDS_FILE"
            return 0
        fi
        log_error "记录文件为空或无有效记录: $RECORDS_FILE"
        return 1
    fi

    # 配置了记录文件但文件不存在
    if [ -n "${RECORDS_FILE:-}" ]; then
        log_error "记录文件不存在: $RECORDS_FILE"
        log_error "可执行 '$SCRIPT_NAME records <域名> --generate' 自动生成"
        return 1
    fi

    # 回退：配置文件的单条记录
    if [ -z "${DOMAIN_ID:-}" ] || [ -z "${RECORD_ID:-}" ] || [ -z "${SUB_DOMAIN:-}" ]; then
        log_error "未配置记录：请设置 RECORDS_FILE，或填写 DOMAIN_ID/RECORD_ID/SUB_DOMAIN"
        return 1
    fi

    if ! parse_record_line "${SUB_DOMAIN}|${DOMAIN_ID}|${RECORD_ID}|${RECORD_TYPE}|${NETWORK_INTERFACE}|${RECORD_TTL}"; then
        return 1
    fi
    log_info "已加载 1 条记录（单记录模式）"
    return 0
}

#-------------------------------------------------------------------------------
# FUNCTION: validate_config
# DESCRIPTION: 验证配置项的完整性和格式正确性
#              检查必填项、格式、数值范围
# PARAMETERS: 无
# RETURNS: 配置有效返回 0，无效则退出
#-------------------------------------------------------------------------------
validate_config() {
    local missing=()

    # 检查必填配置项
    # LOGIN_TOKEN 始终必填
    [ -z "$LOGIN_TOKEN" ] && missing+=("LOGIN_TOKEN")

    # 多记录模式下，记录信息来自 RECORDS_FILE，配置文件的
    # DOMAIN_ID/RECORD_ID/SUB_DOMAIN/RECORD_TYPE 不再必填
    if [ -z "${RECORDS_FILE:-}" ]; then
        # 完全未配置记录文件 → 必须是单记录模式
        [ -z "$DOMAIN_ID" ] && missing+=("DOMAIN_ID")
        [ -z "$RECORD_ID" ] && missing+=("RECORD_ID")
        [ -z "$SUB_DOMAIN" ] && missing+=("SUB_DOMAIN")
        [ -z "$RECORD_TYPE" ] && missing+=("RECORD_TYPE")
    elif [ ! -f "${RECORDS_FILE}" ]; then
        # 配置了记录文件但文件不存在：允许运行（records --generate 可创建它），
        # 但若同时提供了单记录字段则按单记录模式处理
        if [ -z "$DOMAIN_ID" ] && [ -z "$SUB_DOMAIN" ]; then
            log_warn "记录文件不存在: $RECORDS_FILE"
            log_warn "可执行 '$SCRIPT_NAME records <域名> --generate' 自动生成"
        fi
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "配置文件缺少必要字段: ${missing[*]}"
        exit 1
    fi

    # 验证 LOGIN_TOKEN 格式：应为 "ID,Token"
    # 示例: "12345,abcd1234efgh5678"
    if ! [[ "$LOGIN_TOKEN" =~ ^[0-9]+,[a-zA-Z0-9]+$ ]]; then
        log_error "LOGIN_TOKEN 格式错误，应为: ID,Token"
        log_error "当前值: ${LOGIN_TOKEN:0:4}****"
        exit 1
    fi

    # 验证记录类型：只支持 A 和 AAAA
    # 多记录模式下每条记录的类型在 parse_record_line 中单独校验
    if [ -n "$RECORD_TYPE" ] && [[ ! "$RECORD_TYPE" =~ ^(A|AAAA)$ ]]; then
        log_error "RECORD_TYPE 必须是 A 或 AAAA，当前: $RECORD_TYPE"
        exit 1
    fi

    # 验证强制更新周期（必须为数字）
    if ! [[ "$FORCE_UPDATE_CYCLE" =~ ^[0-9]+$ ]]; then
        FORCE_UPDATE_CYCLE=60
    fi

    # 验证重试参数
    if ! [[ "$MAX_RETRY" =~ ^[0-9]+$ ]]; then
        MAX_RETRY=3
    fi
    if ! [[ "$RETRY_DELAY" =~ ^[0-9]+$ ]]; then
        RETRY_DELAY=2
    fi

    # 验证 TTL（生存时间）
    # TTL 决定 DNS 记录在 DNS 服务器上的缓存时间
    if ! [[ "$RECORD_TTL" =~ ^[0-9]+$ ]] || [ "$RECORD_TTL" -lt 1 ]; then
        RECORD_TTL=$DEFAULT_TTL
    fi

    # 验证历史记录最大条数
    if ! [[ "$HISTORY_MAX" =~ ^[0-9]+$ ]] || [ "$HISTORY_MAX" -lt 1 ]; then
        HISTORY_MAX=100
    fi

    log_debug "配置验证通过"
}

#===============================================================================
# 初始化
#===============================================================================

#-------------------------------------------------------------------------------
# FUNCTION: init_dirs
# DESCRIPTION: 初始化日志目录、锁目录和各运行时文件
#              - 创建必要的目录
#              - 初始化数据库文件、计数器文件等
# PARAMETERS: 无
#-------------------------------------------------------------------------------
init_dirs() {
    # 创建日志目录
    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        log_error "无法创建日志目录: $LOG_DIR"
        exit 1
    fi

    # 创建锁目录
    if ! mkdir -p "$LOCK_DIR" 2>/dev/null; then
        log_warn "无法创建锁目录: $LOCK_DIR，使用 /tmp"
        LOCK_DIR="/tmp"
    fi

    # 初始化文件路径
    LOG_FILE="$LOG_DIR/ddns.log"            # 主日志文件
    LOCK_FILE="$LOCK_DIR/ddns.lock"         # 锁文件（目录形式）
    PID_FILE="$LOCK_DIR/ddns.pid"           # PID 文件
    HISTORY_FILE="$LOG_DIR/history.log"     # 更新历史

    # 锁目录可能已被上次异常退出残留，且 PID 文件已丢失——主动清理僵尸锁
    if [ -d "$LOCK_FILE" ] && [ ! -f "$PID_FILE" ]; then
        log_warn "发现残留锁目录（无 PID 文件），清理: $LOCK_FILE"
        rm -rf "$LOCK_FILE" 2>/dev/null || true
    fi

    # 初始化文件（如果不存在）
    # 写入失败必须明确报错——否则后续的状态落盘会静默失败，
    # 而脚本会一直报告"更新成功"。
    if [ ! -f "$LOG_FILE" ] && ! touch "$LOG_FILE" 2>/dev/null; then
        log_error "无法创建日志文件: $LOG_FILE"
        log_error "请检查目录权限与磁盘空间: $LOG_DIR"
        exit 1
    fi
    if [ ! -f "$HISTORY_FILE" ] && ! touch "$HISTORY_FILE" 2>/dev/null; then
        log_error "无法创建历史记录文件: $HISTORY_FILE"
        log_error "请检查目录权限与磁盘空间: $LOG_DIR"
        exit 1
    fi

    # 目录必须可写，否则后续状态文件无法落盘
    if [ ! -w "$LOG_DIR" ]; then
        log_error "日志目录不可写: $LOG_DIR"
        log_error "状态文件（IP 记录、更新计数）无法保存，DDNS 将无法正常工作"
        exit 1
    fi

    log_debug "目录初始化完成: $LOG_DIR"
}

#-------------------------------------------------------------------------------
# FUNCTION: record_state_files
# DESCRIPTION: 设置某条记录的状态文件路径（db / flag）
#              多记录模式下每条记录使用独立的状态文件，互不干扰
# PARAMETERS: $1 - 记录索引
# OUTPUT: 设置 DB_FILE / FLAG_FILE 全局变量
#-------------------------------------------------------------------------------
record_state_files() {
    local idx="$1"
    local key="${REC_KEY[$idx]}"

    # 单记录模式（配置文件的 DOMAIN_ID 等）保持原有的 db / flag 文件名，向后兼容
    # 使用 RECORDS_FILE 时按记录隔离状态文件，即使只有一条记录
    if [ -z "${RECORDS_FILE:-}" ] || [ ! -f "${RECORDS_FILE}" ]; then
        DB_FILE="$LOG_DIR/db"
        FLAG_FILE="$LOG_DIR/flag"
    else
        DB_FILE="$LOG_DIR/db.$key"
        FLAG_FILE="$LOG_DIR/flag.$key"
    fi

    [ -f "$DB_FILE" ] || touch "$DB_FILE"
    [ -f "$FLAG_FILE" ] || echo "0" > "$FLAG_FILE"
}

#-------------------------------------------------------------------------------
# FUNCTION: acquire_lock
# DESCRIPTION: 获取执行锁，防止脚本并发执行
#              使用目录作为锁（原子操作）
# PARAMETERS: 无
# RETURNS: 获取成功返回 0，超时返回 1
#-------------------------------------------------------------------------------
acquire_lock() {
    local timeout=30                         # 获取锁的超时时间（秒）
    local start_time=$(date +%s)

    while true; do
        # 尝试创建锁目录（mkdir 是原子操作）
        if mkdir "$LOCK_FILE" 2>/dev/null; then
            echo "$$" > "$PID_FILE"         # 记录当前进程 PID
            log_debug "获取锁成功 (PID: $$)"
            return 0
        fi

        # 检查是否有旧进程在运行
        # 注意：不能只依赖 PID 文件——PID 文件可能已被删除，此时仍需判断锁目录
        # 是否为僵尸锁。用 /proc/<pid> 判断进程是否真实存在（不依赖 kill 权限）。
        local old_pid=""
        [ -f "$PID_FILE" ] && old_pid=$(cat "$PID_FILE" 2>/dev/null)

        if [ -z "$old_pid" ] || [ ! -d "/proc/$old_pid" ]; then
            # 无 PID 或 PID 对应进程已不存在 → 僵尸锁，安全清理
            log_warn "清理僵尸锁 (PID: ${old_pid:-unknown})"
            rm -rf "$LOCK_FILE" 2>/dev/null || true
            rm -f "$PID_FILE" 2>/dev/null || true
            continue
        fi

        # 检查超时
        local elapsed=$(( $(date +%s) - start_time ))
        if [ "$elapsed" -ge "$timeout" ]; then
            log_error "获取锁超时，可能有其他实例在运行"
            log_error "如果确认无其他实例，请删除: $LOCK_FILE"
            return 1
        fi

        sleep 1
    done
}

#-------------------------------------------------------------------------------
# FUNCTION: rotate_log
# DESCRIPTION: 日志轮转，当日志文件超过大小时自动备份
#              - 备份旧日志文件（带时间戳）
#              - 尝试压缩备份文件
# PARAMETERS: 无
#-------------------------------------------------------------------------------
rotate_log() {
    if [ ! -f "$LOG_FILE" ]; then
        return
    fi

    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo "0")

    if [ "$size" -gt "$LOG_MAX_SIZE" ]; then
        local backup="${LOG_FILE}.$(date +%Y%m%d%H%M%S)"
        mv "$LOG_FILE" "$backup" 2>/dev/null || return

        # 后台压缩旧日志（不阻塞主流程）
        if command -v gzip &>/dev/null; then
            gzip "$backup" 2>/dev/null &
        fi

        log_info "日志已轮转: $backup"
    fi
}

#===============================================================================
# 网络工具函数
#===============================================================================

#-------------------------------------------------------------------------------
# FUNCTION: check_network
# DESCRIPTION: 检查网络连通性
#              依次尝试 IPv4 和 IPv6 的公共 DNS 服务器
# PARAMETERS: 无
# RETURNS: 网络可用返回 0，不可用返回 1
#-------------------------------------------------------------------------------
check_network() {
    local attempts=3
    local timeout=3

    # ping 可能未安装（精简容器/静态系统），此时退化为 curl 连通性探测
    if ! command -v ping >/dev/null 2>&1; then
        log_debug "ping 不可用，改用 curl 探测"
        for ((i=1; i<=attempts; i++)); do
            if curl -s -o /dev/null --connect-timeout "$timeout" https://dnsapi.cn 2>/dev/null; then
                log_debug "网络检查通过 (curl)"
                return 0
            fi
            [ $i -lt $attempts ] && sleep 1
        done
        log_error "网络不可用"
        return 1
    fi

    for ((i=1; i<=attempts; i++)); do
        # 尝试 IPv4：ping Google DNS
        if ping -c 1 -W $timeout 8.8.8.8 >/dev/null 2>&1; then
            log_debug "网络检查通过 (IPv4)"
            return 0
        fi
        # 尝试 IPv6：ping Google DNS
        if ping -c 1 -W $timeout 2001:4860:4860::8888 >/dev/null 2>&1; then
            log_debug "网络检查通过 (IPv6)"
            return 0
        fi
        [ $i -lt $attempts ] && sleep 1
    done

    log_error "网络不可用"
    return 1
}

#-------------------------------------------------------------------------------
# FUNCTION: is_valid_ipv6
# DESCRIPTION: 验证 IPv6 地址格式的正确性
#              支持完整格式和缩写格式（::）
# PARAMETERS:
#   $1 - IPv6 地址字符串
# RETURNS: 有效返回 0，无效返回 1
# EXAMPLES:
#   is_valid_ipv6 "2001:db8::1"      # 返回 0
#   is_valid_ipv6 "invalid"          # 返回 1
#-------------------------------------------------------------------------------
is_valid_ipv6() {
    local ip="$1"

    [ -z "$ip" ] && return 1

    # 完整格式：8 组 16 位十六进制数
    [[ "$ip" =~ ^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$ ]] && return 0
    # 缩写格式：各种 :: 的位置
    [[ "$ip" =~ ^([0-9a-fA-F]{1,4}:){1,7}:$ ]] && return 0
    [[ "$ip" =~ ^:([0-9a-fA-F]{1,4}:){1,7}$ ]] && return 0
    [[ "$ip" =~ ^([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}$ ]] && return 0
    [[ "$ip" =~ ^([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}$ ]] && return 0
    [[ "$ip" =~ ^([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}$ ]] && return 0
    [[ "$ip" =~ ^([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}$ ]] && return 0
    [[ "$ip" =~ ^([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}$ ]] && return 0
    [[ "$ip" =~ ^[0-9a-fA-F]{1,4}(:[0-9a-fA-F]{1,4}){0,5}::([0-9a-fA-F]{1,4}(:[0-9a-fA-F]{1,4}){0,5})?$ ]] && return 0
    [[ "$ip" =~ ^::$ ]] && return 0

    return 1
}

#-------------------------------------------------------------------------------
# FUNCTION: is_valid_ipv4
# DESCRIPTION: 验证 IPv4 地址格式的正确性
#              检查四个八位组的格式和范围（0-255）
# PARAMETERS:
#   $1 - IPv4 地址字符串
# RETURNS: 有效返回 0，无效返回 1
# EXAMPLES:
#   is_valid_ipv4 "192.168.1.1"      # 返回 0
#   is_valid_ipv4 "256.1.1.1"        # 返回 1（超出范围）
#-------------------------------------------------------------------------------
is_valid_ipv4() {
    local ip="$1"

    [ -z "$ip" ] && return 1

    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            # 拒绝前导零（如 010），避免被当作八进制解析成 8，绕过范围校验
            if [[ "$octet" =~ ^0[0-9] ]]; then
                return 1
            fi
            # 10# 强制十进制解释
            if [ "$((10#$octet))" -gt 255 ]; then
                return 1
            fi
        done
        return 0
    fi
    return 1
}

#===============================================================================
# IP 地址获取
#===============================================================================

#-------------------------------------------------------------------------------
# FUNCTION: get_current_ipv6
# DESCRIPTION: 获取本机当前的公网 IPv6 地址
#              优先从指定网卡获取，否则获取所有网卡的第一个
# PARAMETERS: 无（使用全局变量 NETWORK_INTERFACE）
# OUTPUT: IPv6 地址字符串
#-------------------------------------------------------------------------------
get_current_ipv6() {
    local interface="${1:-$NETWORK_INTERFACE}"
    local ip=""

    if [ -n "$interface" ]; then
        # 从指定网卡获取 global scope 的 IPv6 地址
        ip=$(ip -6 addr show dev "$interface" scope global 2>/dev/null | \
             grep -oP 'inet6 \K[0-9a-fA-F:]+' | head -1)
    else
        # 从所有网卡获取第一个 global scope 的 IPv6 地址
        ip=$(ip -6 addr show scope global 2>/dev/null | \
             grep -oP 'inet6 \K[0-9a-fA-F:]+' | head -1)
    fi

    echo "$ip"
}

#-------------------------------------------------------------------------------
# FUNCTION: get_current_ipv4
# DESCRIPTION: 获取本机当前的公网 IPv4 地址
#              优先从指定网卡获取，否则获取所有网卡的第一个
# PARAMETERS: 无（使用全局变量 NETWORK_INTERFACE）
# OUTPUT: IPv4 地址字符串
#-------------------------------------------------------------------------------
get_current_ipv4() {
    local interface="${1:-$NETWORK_INTERFACE}"
    local ip=""

    if [ -n "$interface" ]; then
        # 从指定网卡获取 global scope 的 IPv4 地址
        ip=$(ip -4 addr show dev "$interface" scope global 2>/dev/null | \
             grep -oP 'inet \K[0-9.]+' | head -1)
    else
        # 从所有网卡获取第一个 global scope 的 IPv4 地址
        ip=$(ip -4 addr show scope global 2>/dev/null | \
             grep -oP 'inet \K[0-9.]+' | head -1)
    fi

    echo "$ip"
}

#-------------------------------------------------------------------------------
# FUNCTION: get_public_ip
# DESCRIPTION: 通过外部服务获取公网 IP 地址
#              作为备选方案，当本地 IP 获取失败时使用
# PARAMETERS:
#   $1 - IP 类型 (ipv6/ipv4 或 AAAA/A)
# OUTPUT: IP 地址字符串
#-------------------------------------------------------------------------------
get_public_ip() {
    local ip_type="$1"
    local ip

    case "$ip_type" in
        ipv6|AAAA)
            # 使用多个服务确保可用性
            ip=$(curl -s -6 --connect-timeout 5 https://api64.ipify.org 2>/dev/null || \
                 curl -s -6 --connect-timeout 5 https://ifconfig.me 2>/dev/null || \
                 curl -s -6 --connect-timeout 5 https://ip.sb 2>/dev/null)
            ;;
        ipv4|A)
            ip=$(curl -s -4 --connect-timeout 5 https://api64.ipify.org 2>/dev/null || \
                 curl -s -4 --connect-timeout 5 https://ifconfig.me 2>/dev/null || \
                 curl -s -4 --connect-timeout 5 https://ip.sb 2>/dev/null)
            ;;
    esac

    echo "$ip"
}

#===============================================================================
# API 工具函数
#===============================================================================

#-------------------------------------------------------------------------------
# FUNCTION: urlencode
# DESCRIPTION: 纯 bash 实现 URL 编码（不依赖 jq / python）
# PARAMETERS: $1 - 原始字符串
# OUTPUT: 百分号编码后的字符串
#-------------------------------------------------------------------------------
urlencode() {
    local str="$1"
    local out=""
    local i ch
    # 强制 C locale：否则 bash 按字符（而非字节）切分，UTF-8 多字节字符会被截断
    local LC_ALL=C
    for ((i=0; i<${#str}; i++)); do
        ch="${str:i:1}"
        case "$ch" in
            [a-zA-Z0-9.~_-]) out+="$ch" ;;
            ' ')             out+="%20" ;;
            *)               out+="%"$(printf '%02X' "'$ch") ;;
        esac
    done
    echo "$out"
}

#-------------------------------------------------------------------------------
# FUNCTION: parse_json_field
# DESCRIPTION: 从 JSON 字符串中提取指定字段的值
#              使用纯 Bash 实现，避免依赖 jq
# PARAMETERS:
#   $1 - JSON 字符串
#   $2 - 字段名
# OUTPUT: 字段值（字符串或数字）
# EXAMPLE:
#   parse_json_field '{"code":1,"message":"success"}' "code"
#   # 输出: 1
#-------------------------------------------------------------------------------
parse_json_field() {
    local json="$1"
    local field="$2"
    local value

    # DNSPod API v2 的响应是嵌套结构：{"status":{"code":1,"message":"操作成功"}}
    # 优先从 status 对象里取，避免误取到 record 等其它层级同名字段
    local status_block
    # 压成单行，避免格式化过的 JSON 因换行导致匹配失败
    local flat
    flat=$(printf '%s' "$json" | tr -d '\n\r' | tr -s ' ')
    status_block=$(printf '%s' "$flat" | grep -oP '"status"\s*:\s*\{[^}]*\}' | head -1)

    if [ -n "$status_block" ]; then
        value=$(printf '%s' "$status_block" | grep -oP "\"$field\"\s*:\s*\"[^\"]*\"" | \
                sed 's/.*: *"\([^"]*\)".*/\1/' | head -1)
        if [ -z "$value" ]; then
            value=$(printf '%s' "$status_block" | grep -oP "\"$field\"\s*:\s*[0-9]+" | \
                    sed 's/.*: *\([0-9]*\).*/\1/' | head -1)
        fi
    fi

    # status 里没有则回退到全文档搜索
    if [ -z "$value" ]; then
        # 尝试提取字符串值
        value=$(printf '%s' "$flat" | grep -oP "\"$field\"\s*:\s*\"[^\"]*\"" | \
                sed 's/.*: *"\([^"]*\)".*/\1/' | head -1)

        # 如果没有字符串值，尝试提取数值
        if [ -z "$value" ]; then
            value=$(printf '%s' "$flat" | grep -oP "\"$field\"\s*:\s*[0-9]+" | \
                    sed 's/.*: *\([0-9]*\).*/\1/' | head -1)
        fi
    fi

    # 解码 \uXXXX 转义（部分 API 会返回转义后的中文）
    # 用纯 bash 逐个替换：printf '%b' 会把 \x64 误当八进制，sed 的 \xNN 替换
    # 在部分 sed 实现上也不可靠，故手工换算
    if printf '%s' "$value" | grep -qP '\\u[0-9a-fA-F]{4}'; then
        local decoded=""
        local rest="$value"
        while [[ "$rest" =~ \\u([0-9a-fA-F]{4})(.*) ]]; do
            local hex="${BASH_REMATCH[1]}"
            rest="${BASH_REMATCH[2]}"
            local code=$((16#$hex))
            # 按 UTF-8 编码该码点
            if [ "$code" -lt 128 ]; then
                decoded+=$(printf "\\$(printf '%03o' "$code")")
            elif [ "$code" -lt 2048 ]; then
                decoded+=$(printf "\\$(printf '%03o' $((0xC0 | (code >> 6))))\\$(printf '%03o' $((0x80 | (code & 0x3F))))")
            else
                decoded+=$(printf "\\$(printf '%03o' $((0xE0 | (code >> 12))))\\$(printf '%03o' $((0x80 | ((code >> 6) & 0x3F))))\\$(printf '%03o' $((0x80 | (code & 0x3F))))")
            fi
        done
        value="$decoded$rest"
    fi

    echo "$value"
}

#===============================================================================
# 通知系统
#===============================================================================

#-------------------------------------------------------------------------------
# FUNCTION: send_webhook
# DESCRIPTION: 发送 Webhook 通知
#              支持多种平台：Discord、Slack、Telegram、自定义
# PARAMETERS:
#   $1 - 状态 (success/error)
#   $2 - IP 地址
#   $3 - 消息内容
# NOTE: 需要在配置文件中设置 WEBHOOK_URL
#-------------------------------------------------------------------------------
send_webhook() {
    local status="$1"
    local ip="$2"
    local message="$3"
    local sub="${4:-$SUB_DOMAIN}"

    # 未配置 Webhook URL 则跳过
    [ -z "$WEBHOOK_URL" ] && return 0

    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local method="${WEBHOOK_METHOD:-POST}"

    # 根据不同的 Webhook 平台构建不同格式的消息
    local payload
    case "$WEBHOOK_URL" in
        *discord.com*|*discordapp.com*)
            # Discord Webhook 格式（使用 Embed）
            local color="5814783"  # 绿色
            [ "$status" = "error" ] && color="15548997"  # 红色
            payload=$(cat <<EOF
{
  "embeds": [{
    "title": "TX_DDNS 通知",
    "description": "$message",
    "color": $color,
    "fields": [
      {"name": "子域名", "value": "$sub", "inline": true},
      {"name": "状态", "value": "$status", "inline": true},
      {"name": "IP", "value": "$ip", "inline": true},
      {"name": "时间", "value": "$timestamp"}
    ]
  }]
}
EOF
)
            ;;
        *slack.com*)
            # Slack Webhook 格式（Slack 接受纯 JSON body）
            local emoji=":white_check_mark:"
            [ "$status" = "error" ] && emoji=":x:"
            payload=$(cat <<EOF
{"text":"$emoji TX_DDNS [$sub]: $message\nIP: $ip\n时间: $timestamp"}
EOF
)
            ;;
        *telegram.org*)
            # Telegram Bot API 格式
            # 纯 bash URL 编码，不依赖 jq（README 声明无外部依赖）
            local text="TX_DDNS 通知
子域名: $sub
状态: $status
IP: $ip
时间: $timestamp
$message"
            local encoded
            encoded=$(urlencode "$text")
            # chat_id 优先取 WEBHOOK_CHAT_ID，未配置时从 URL 查询串解析 ?chat_id=xxx
            local chat_id="${WEBHOOK_CHAT_ID:-}"
            if [ -z "$chat_id" ]; then
                chat_id=$(printf '%s' "$WEBHOOK_URL" | sed -n 's/.*[?&]chat_id=\([^&]*\).*/\1/p')
            fi
            if [ -z "$chat_id" ]; then
                log_warn "Telegram Webhook 缺少 chat_id，跳过发送"
                return 0
            fi
            payload="chat_id=$(urlencode "$chat_id")&text=$encoded"
            ;;
        *)
            # 通用 JSON 格式
            payload=$(cat <<EOF
{
  "status": "$status",
  "ip": "$ip",
  "message": "$message",
  "timestamp": "$timestamp",
  "domain": "$sub",
  "type": "${CURRENT_REC_TYPE:-$RECORD_TYPE}"
}
EOF
)
            ;;
    esac

    # 发送 HTTP 请求
    # Telegram 使用 form-urlencoded，其余平台使用 JSON
    local content_type="application/json"
    case "$WEBHOOK_URL" in
        *telegram.org*) content_type="application/x-www-form-urlencoded" ;;
    esac

    local response
    local rc=0
    response=$(curl -s -X "$method" \
        -H "Content-Type: $content_type" \
        -d "$payload" \
        --connect-timeout 10 \
        --max-time 30 \
        "$WEBHOOK_URL" 2>&1) || rc=$?

    if [ "$rc" -eq 0 ]; then
        log_debug "Webhook 发送成功"
    else
        log_warn "Webhook 发送失败: $response"
    fi
}

#===============================================================================
# 历史记录
#===============================================================================

#-------------------------------------------------------------------------------
# FUNCTION: record_history
# DESCRIPTION: 记录 DNS 更新历史
#              保存时间戳、状态、IP 变化等信息
# PARAMETERS:
#   $1 - 状态 (success/error)
#   $2 - 旧 IP 地址
#   $3 - 新 IP 地址
#   $4 - 消息内容
#-------------------------------------------------------------------------------
record_history() {
    local status="$1"
    local old_ip="$2"
    local new_ip="$3"
    local message="$4"
    local sub="${5:-$SUB_DOMAIN}"
    # 多记录模式下每条记录的类型不同，优先用当前记录的类型
    local rtype="${6:-${CURRENT_REC_TYPE:-$RECORD_TYPE}}"

    [ ! -f "$HISTORY_FILE" ] && touch "$HISTORY_FILE"

    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    # 格式: 时间 | 子域名 | 状态 | 类型 | 旧IP -> 新IP | 消息
    local entry="$timestamp | $sub | $status | $rtype | $old_ip -> $new_ip | $message"

    # 追加记录
    echo "$entry" >> "$HISTORY_FILE"

    # 限制历史记录条数（删除最旧的记录）
    local count=$(wc -l < "$HISTORY_FILE")
    if [ "$count" -gt "$HISTORY_MAX" ]; then
        tail -n "$HISTORY_MAX" "$HISTORY_FILE" > "${HISTORY_FILE}.tmp"
        mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
    fi
}

#===============================================================================
# DNSPod API 调用
#===============================================================================

#-------------------------------------------------------------------------------
# FUNCTION: call_dns_api
# DESCRIPTION: 调用 DNSPod API 更新 DNS 记录
#              带自动重试机制
# PARAMETERS:
#   $1 - 新的 IP 地址值
# OUTPUT: API 响应 JSON
# RETURNS: 成功返回 0，失败返回 1
# API DOC: https://docs.dnspod.cn/api/record_modify/
#-------------------------------------------------------------------------------
call_dns_api() {
    local value="$1"
    local api_domain="${2:-$DOMAIN_ID}"
    local api_record="${3:-$RECORD_ID}"
    local api_sub="${4:-$SUB_DOMAIN}"
    local api_type="${5:-$RECORD_TYPE}"
    local api_ttl="${6:-$RECORD_TTL}"
    local attempt=1
    local response code message

    while [ $attempt -le $MAX_RETRY ]; do
        log_debug "API 调用尝试 $attempt/$MAX_RETRY"

        # 调用 DNSPod Record.Modify API
        # 文档: https://docs.dnspod.cn/api/record_modify/
        response=$(curl -s -X POST https://dnsapi.cn/Record.Modify \
            -d "login_token=$LOGIN_TOKEN" \
            -d "format=json" \
            -d "domain_id=$api_domain" \
            -d "record_id=$api_record" \
            -d "record_line_id=0" \
            -d "sub_domain=$api_sub" \
            -d "value=$value" \
            -d "record_type=$api_type" \
            -d "ttl=$api_ttl" \
            --connect-timeout 10 \
            --max-time 30 2>&1)

        code=$(parse_json_field "$response" "code")
        message=$(parse_json_field "$response" "message")

        # code=1 表示成功
        if [ "$code" = "1" ]; then
            log_debug "API 调用成功"
            echo "$response"
            return 0
        fi

        # 认证错误不重试（Token 无效或 ID 错误）
        if [[ "$message" =~ "Token" ]] || [[ "$message" =~ "ID" ]]; then
            log_error "认证失败: $message"
            return 1
        fi

        log_warn "API 调用失败 (尝试 $attempt/$MAX_RETRY): $message"

        if [ $attempt -lt $MAX_RETRY ]; then
            sleep $RETRY_DELAY
        fi

        attempt=$((attempt + 1))
    done

    log_error "API 调用失败，已达最大重试次数"
    echo "$response"
    return 1
}

#===============================================================================
# 命令实现
#===============================================================================

#-------------------------------------------------------------------------------
# FUNCTION: do_status
# DESCRIPTION: 执行 status 命令，显示当前 DNS 记录和本地 IP 状态
#              用于调试和监控
#-------------------------------------------------------------------------------
do_status() {
    load_config
    init_dirs

    if ! load_records; then
        echo "✗ 没有可用的记录"
        return 1
    fi

    echo "=========================================="
    echo "         TX_DDNS 状态报告"
    echo "=========================================="
    echo ""

    echo "【记录列表】共 $REC_COUNT 条"
    echo ""

    local idx
    for ((idx=0; idx<REC_COUNT; idx++)); do
        local sub="${REC_SUB[$idx]}"
        local rtype="${REC_TYPE[$idx]}"
        local iface="${REC_IFACE[$idx]}"
        local ttl="${REC_TTL[$idx]}"

        record_state_files "$idx"

        local old_ip
        old_ip=$(cat "$DB_FILE" 2>/dev/null || echo "")
        local update_flag
        update_flag=$(cat "$FLAG_FILE" 2>/dev/null || echo "0")
        [ -n "$update_flag" ] || update_flag=0

        # 本地 IP
        local local_ip=""
        if [ "$rtype" = "AAAA" ]; then
            local_ip=$(get_current_ipv6 "$iface")
        else
            local_ip=$(get_current_ipv4 "$iface")
        fi

        echo "  [$((idx + 1))] $sub ($rtype)"
        echo "      域名ID/记录ID: ${REC_DOMAIN[$idx]} / ${REC_ID[$idx]}"
        echo "      TTL: $ttl 秒 | 网卡: ${iface:-自动}"
        echo "      本地 IP: ${local_ip:-未获取到}"
        echo "      上次 IP: ${old_ip:-无}"
        echo "      更新计数: ${update_flag}/${FORCE_UPDATE_CYCLE}"

        if [ -f "$HISTORY_FILE" ] && [ -s "$HISTORY_FILE" ]; then
            local last_update
            last_update=$(grep -F "| $sub |" "$HISTORY_FILE" 2>/dev/null | tail -1)
            [ -n "$last_update" ] && echo "      最近更新: $last_update"
        fi
        echo ""
    done

    echo "【网络状态】"
    if check_network; then
        echo "  网络连接:  正常"
    else
        echo "  网络连接:  异常"
    fi

    echo ""
    echo "【配置信息】"
    echo "  配置文件:  $CONFIG_FILE"
    echo "  记录文件:  ${RECORDS_FILE:-未配置（单记录模式）}"
    echo "  日志目录:  $LOG_DIR"
    echo "  API 重试:  $MAX_RETRY 次"
    echo "  Webhook:   ${WEBHOOK_URL:-未配置}"

    echo ""
    echo "=========================================="
}

#-------------------------------------------------------------------------------
# FUNCTION: do_test
# DESCRIPTION: 执行 test 命令，测试配置的正确性
#              不实际更新 DNS，只验证各项配置
# RETURNS: 所有测试通过返回 0，有错误返回 1
#-------------------------------------------------------------------------------
do_test() {
    load_config
    init_dirs

    echo "=========================================="
    echo "         TX_DDNS 配置测试"
    echo "=========================================="
    echo ""

    local errors=0

    # 测试 1: 网络连通性
    echo "✓ 测试网络连通性..."
    if check_network; then
        echo "  网络正常"
    else
        echo "  ✗ 网络不可用"
        errors=$((errors + 1))
    fi

    # 测试 2: API Token 有效性
    echo ""
    echo "✓ 测试 API Token..."
    local response
    response=$(curl -s -X POST https://dnsapi.cn/Info.Version \
        -d "login_token=$LOGIN_TOKEN&format=json" 2>&1)

    local code=$(parse_json_field "$response" "code")
    if [ "$code" = "1" ]; then
        echo "  Token 有效"
    else
        local message=$(parse_json_field "$response" "message")
        echo "  ✗ Token 无效: $message"
        errors=$((errors + 1))
    fi

    # 测试 3: 逐条验证记录访问权限
    if ! load_records; then
        echo ""
        echo "✗ 没有可用的记录"
        errors=$((errors + 1))
    else
        local idx
        for ((idx=0; idx<REC_COUNT; idx++)); do
            local sub="${REC_SUB[$idx]}"
            local rtype="${REC_TYPE[$idx]}"
            local iface="${REC_IFACE[$idx]}"
            local ttl="${REC_TTL[$idx]}"

            echo ""
            echo "✓ 测试记录 $((idx + 1))/$REC_COUNT: $sub ($rtype)"

            # 域名和记录访问权限
            response=$(curl -s -X POST https://dnsapi.cn/Record.Info \
                -d "login_token=$LOGIN_TOKEN&format=json&domain_id=${REC_DOMAIN[$idx]}&record_id=${REC_ID[$idx]}" 2>&1)

            code=$(parse_json_field "$response" "code")
            if [ "$code" = "1" ]; then
                local record_name=$(parse_json_field "$response" "name")
                local record_type=$(parse_json_field "$response" "type")
                local record_value=$(parse_json_field "$response" "value")
                echo "  记录名称: $record_name"
                echo "  记录类型: $record_type"
                echo "  当前值:   $record_value"
                echo "  当前 TTL: $ttl"
            else
                local message=$(parse_json_field "$response" "message")
                echo "  ✗ 无法访问记录: $message"
                errors=$((errors + 1))
            fi

            # IP 获取
            local current_ip
            if [ "$rtype" = "AAAA" ]; then
                current_ip=$(get_current_ipv6 "$iface")
                if is_valid_ipv6 "$current_ip"; then
                    echo "  IPv6 获取成功: $current_ip"
                else
                    echo "  ✗ 无法获取有效 IPv6: '$current_ip'"
                    errors=$((errors + 1))
                fi
            else
                current_ip=$(get_current_ipv4 "$iface")
                if is_valid_ipv4 "$current_ip"; then
                    echo "  IPv4 获取成功: $current_ip"
                else
                    echo "  ✗ 无法获取有效 IPv4: '$current_ip'"
                    errors=$((errors + 1))
                fi
            fi
        done
    fi

    # 测试 5: 日志目录权限
    echo ""
    echo "✓ 测试日志目录..."
    if [ -w "$LOG_DIR" ]; then
        echo "  日志目录可写"
    else
        echo "  ✗ 日志目录不可写: $LOG_DIR"
        errors=$((errors + 1))
    fi

    # 测试 6: Webhook 可达性（可选）
    if [ -n "$WEBHOOK_URL" ]; then
        echo ""
        echo "✓ 测试 Webhook..."
        if curl -s -X HEAD --connect-timeout 5 "$WEBHOOK_URL" &>/dev/null; then
            echo "  Webhook URL 可达"
        else
            echo "  ⚠ Webhook URL 可能不可达"
        fi
    fi

    echo ""
    echo "=========================================="
    if [ $errors -eq 0 ]; then
        echo "✓ 所有测试通过，配置正确"
        return 0
    else
        echo "✗ 发现 $errors 个错误，请检查配置"
        return 1
    fi
}

#-------------------------------------------------------------------------------
# FUNCTION: do_list
# DESCRIPTION: 执行 list 命令，列出已配置的所有记录
#              不发起任何网络请求，纯本地查看
#-------------------------------------------------------------------------------
do_list() {
    load_config
    init_dirs

    if ! load_records; then
        echo "✗ 没有可用的记录"
        return 1
    fi

    echo "=========================================="
    echo "         TX_DDNS 记录列表"
    echo "=========================================="
    echo ""
    echo "来源: ${RECORDS_FILE:-配置文件（单记录模式）}"
    echo ""
    printf "%-4s | %-16s | %-6s | %-10s | %-10s | %-6s | %s\n" \
        "序号" "子域名" "类型" "域名ID" "记录ID" "TTL" "网卡"
    echo "--------------------------------------------------------------------------------------------"

    local idx
    for ((idx=0; idx<REC_COUNT; idx++)); do
        printf "%-4s | %-16s | %-6s | %-10s | %-10s | %-6s | %s\n" \
            "$((idx + 1))" "${REC_SUB[$idx]}" "${REC_TYPE[$idx]}" \
            "${REC_DOMAIN[$idx]}" "${REC_ID[$idx]}" "${REC_TTL[$idx]}" \
            "${REC_IFACE[$idx]:-自动}"
    done

    echo ""
    echo "共计 $REC_COUNT 条记录"
    echo "=========================================="
}

#-------------------------------------------------------------------------------
# FUNCTION: parse_domain_info
# DESCRIPTION: 从 API 响应中提取域名信息
# PARAMETERS: $1 - API 响应 JSON
# OUTPUT: "域名ID|域名"
#-------------------------------------------------------------------------------
parse_domain_info() {
    local json="$1"
    local flat
    flat=$(printf '%s' "$json" | tr -d '\n\r' | tr -s ' ')

    local block
    block=$(printf '%s' "$flat" | grep -oP '"domain"\s*:\s*\{[^}]*\}' | head -1)
    if [ -z "$block" ]; then
        echo "|"
        return 1
    fi

    local did dname
    did=$(printf '%s' "$block" | grep -oP '"id"\s*:\s*"?[^",}]*' | head -1 | sed 's/.*: *"*//')
    dname=$(printf '%s' "$block" | grep -oP '"name"\s*:\s*"[^"]*"' | head -1 | sed 's/.*: *"\(.*\)"/\1/')
    printf '%s|%s\n' "$did" "$dname"
}

#-------------------------------------------------------------------------------
# FUNCTION: parse_json_records
# DESCRIPTION: 解析 DNSPod Record.List 响应中的 records 数组
#              逐条输出: 记录ID|子域名|类型|TTL
#              纯 bash 实现，不依赖 jq
# PARAMETERS: $1 - API 响应 JSON
# OUTPUT: 每行一条 "id|name|type|ttl"
#-------------------------------------------------------------------------------
parse_json_records() {
    local json="$1"

    # 先把 JSON 压成单行，消除换行对正则的影响
    # （DNSPod 返回紧凑 JSON，但格式化过的响应会导致 .* 不跨行而匹配失败）
    local flat
    flat=$(printf '%s' "$json" | tr -d '\n\r' | tr -s ' ')

    # 提取 records 数组
    local arr
    arr=$(printf '%s' "$flat" | grep -oP '"records"\s*:\s*\[.*\]' | head -1)
    if [ -z "$arr" ]; then
        return 1
    fi

    # 按 },{ 切成多行，每行一个对象，再逐个提取字段
    # 记录对象内部不含嵌套对象，{[^}]*} 可以安全匹配
    local obj id nm ty ttl
    while IFS= read -r obj; do
        [ -z "$obj" ] && continue
        id=$(printf '%s' "$obj" | grep -oP '"id"\s*:\s*"[^"]*"' | head -1 | sed 's/.*: *"\(.*\)"/\1/')
        nm=$(printf '%s' "$obj" | grep -oP '"name"\s*:\s*"[^"]*"' | head -1 | sed 's/.*: *"\(.*\)"/\1/')
        ty=$(printf '%s' "$obj" | grep -oP '"type"\s*:\s*"[^"]*"' | head -1 | sed 's/.*: *"\(.*\)"/\1/')
        ttl=$(printf '%s' "$obj" | grep -oP '"ttl"\s*:\s*"[^"]*"' | head -1 | sed 's/.*: *"\(.*\)"/\1/')
        [ -z "$id" ] && continue
        printf '%s|%s|%s|%s\n' "$id" "$nm" "$ty" "$ttl"
    done < <(printf '%s' "$arr" | sed 's/},{/}\n{/g' | grep -oP '\{[^{}]*\}')
}

#-------------------------------------------------------------------------------
# FUNCTION: fetch_records
# DESCRIPTION: 调用 DNSPod Record.List 获取域名下的解析记录
# PARAMETERS:
#   $1 - 域名或域名 ID
# OUTPUT: API 响应 JSON
#-------------------------------------------------------------------------------
fetch_records() {
    local target="$1"

    curl -s -X POST https://dnsapi.cn/Record.List \
        -d "login_token=$LOGIN_TOKEN" \
        -d "format=json" \
        -d "domain=$target" \
        --connect-timeout 10 \
        --max-time 30 2>&1
}

#-------------------------------------------------------------------------------
# FUNCTION: do_records
# DESCRIPTION: 执行 records 命令
#              从 DNSPod 拉取域名下的真实解析记录，列出可更新的记录
#              并可生成记录列表文件（省去手工抄写域名ID/记录ID）
# PARAMETERS: $1 - 域名（可选）
# RETURNS: 成功返回 0，失败返回 1
#-------------------------------------------------------------------------------
do_records() {
    load_config
    init_dirs

    local domain="${1:-}"

    if [ -z "$domain" ]; then
        # 未指定域名：尝试用配置里的 DOMAIN_ID
        if [ -n "${DOMAIN_ID:-}" ]; then
            domain="$DOMAIN_ID"
        else
            echo "用法: $SCRIPT_NAME records <域名>"
            echo "  示例: $SCRIPT_NAME records example.com"
            return 1
        fi
    fi

    echo "正在获取 $domain 的解析记录..."
    local response
    response=$(fetch_records "$domain")

    local code=$(parse_json_field "$response" "code")
    if [ "$code" != "1" ]; then
        local message=$(parse_json_field "$response" "message")
        echo "✗ 获取记录失败: ${message:-未知错误}"
        return 1
    fi

    # 域名信息
    local dom_info
    dom_info=$(parse_domain_info "$response")
    local domain_id="${dom_info%%|*}"
    local real_domain="${dom_info##*|}"

    echo ""
    echo "域名: ${real_domain:-$domain} (ID: ${domain_id:-未知})"
    echo ""

    # 解析记录
    local entries
    entries=$(parse_json_records "$response")
    if [ -z "$entries" ]; then
        echo "该域名下没有解析记录"
        return 1
    fi

    echo "可更新的记录（A / AAAA 类型）:"
    echo ""
    printf "%-4s | %-16s | %-6s | %-12s | %s\n" "序号" "子域名" "类型" "记录ID" "TTL"
    echo "----------------------------------------------------------------------"

    local idx=0
    local id nm ty ttl
    local usable=""
    while IFS='|' read -r id nm ty ttl; do
        [ -z "$id" ] && continue
        idx=$((idx + 1))
        if [ "$ty" = "A" ] || [ "$ty" = "AAAA" ]; then
            printf "%-4s | %-16s | %-6s | %-12s | %s\n" "$idx" "$nm" "$ty" "$id" "$ttl"
            usable+="${nm}|${domain_id}|${id}|${ty}||${ttl}"$'\n'
        else
            printf "%-4s | %-16s | %-6s | %-12s | %s\n" "$idx" "$nm" "$ty" "$id" "$ttl"
        fi
    done <<< "$entries"

    echo ""
    echo "共计 $idx 条记录（其中 A/AAAA 类型可用于 DDNS）"

    # 提示如何生成记录列表
    if [ -n "$usable" ]; then
        echo ""
        echo "生成记录列表文件请执行:"
        echo "  $SCRIPT_NAME records $domain --generate"
    fi

    return 0
}

#-------------------------------------------------------------------------------
# FUNCTION: do_records_generate
# DESCRIPTION: 从 DNSPod 拉取记录并生成记录列表文件
# PARAMETERS: $1 - 域名
# RETURNS: 成功返回 0，失败返回 1
#-------------------------------------------------------------------------------
do_records_generate() {
    load_config
    init_dirs

    local domain="$1"
    local outfile="${2:-$RECORDS_FILE}"

    if [ -z "$domain" ]; then
        echo "用法: $SCRIPT_NAME records <域名> --generate"
        return 1
    fi
    if [ -z "$outfile" ]; then
        echo "✗ 未指定输出文件（请在配置中设置 RECORDS_FILE）"
        return 1
    fi

    echo "正在获取 $domain 的解析记录..."
    local response
    response=$(fetch_records "$domain")

    local code=$(parse_json_field "$response" "code")
    if [ "$code" != "1" ]; then
        echo "✗ 获取记录失败: $(parse_json_field "$response" "message")"
        return 1
    fi

    local dom_info
    dom_info=$(parse_domain_info "$response")
    local domain_id="${dom_info%%|*}"

    local entries
    entries=$(parse_json_records "$response")

    # 只保留 A / AAAA
    local lines=""
    local count=0
    local id nm ty ttl
    while IFS='|' read -r id nm ty ttl; do
        [ -z "$id" ] && continue
        if [ "$ty" = "A" ] || [ "$ty" = "AAAA" ]; then
            lines+="${nm}|${domain_id}|${id}|${ty}||${ttl}"$'\n'
            count=$((count + 1))
        fi
    done <<< "$entries"

    if [ "$count" -eq 0 ]; then
        echo "✗ 没有找到 A / AAAA 类型的记录"
        return 1
    fi

    # 备份已有文件
    if [ -f "$outfile" ]; then
        cp "$outfile" "${outfile}.bak.$(date +%Y%m%d%H%M%S)"
        echo "已备份原文件: ${outfile}.bak.$(date +%Y%m%d%H%M%S)"
    fi

    {
        echo "# TX_DDNS 记录列表"
        echo "# 自动生成: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# 来源: DNSPod Record.List ($domain)"
        echo "#"
        echo "# 格式: 子域名|域名ID|记录ID|记录类型|网卡|TTL"
        echo ""
        printf '%s' "$lines"
    } > "$outfile"

    chmod 600 "$outfile"
    echo ""
    echo "✓ 已生成 $outfile（$count 条记录）"
    echo ""
    echo "查看: $SCRIPT_NAME list -c \$CONFIG_FILE"
    return 0
}

#-------------------------------------------------------------------------------
# FUNCTION: do_history
# DESCRIPTION: 执行 history 命令，显示 DNS 更新历史记录
#-------------------------------------------------------------------------------
do_history() {
    load_config
    init_dirs

    echo "=========================================="
    echo "         TX_DDNS 更新历史"
    echo "=========================================="
    echo ""

    if [ ! -f "$HISTORY_FILE" ] || [ ! -s "$HISTORY_FILE" ]; then
        echo "暂无更新历史记录"
        return 0
    fi

    # 支持按子域名过滤：ddnsv2.sh history www
    local filter="${HISTORY_FILTER:-}"

    echo "最近 $HISTORY_MAX 条记录${filter:+ (子域名: $filter)}:"
    echo ""
    printf "%-20s | %-12s | %-6s | %-5s | %-40s | %s\n" "时间" "子域名" "状态" "类型" "IP 变化" "消息"
    echo "----------------------------------------------------------------------------------------------"

    # 显示最近 20 条历史记录
    # 格式: 时间 | 子域名 | 状态 | 类型 | 旧IP -> 新IP | 消息
    local shown=0
    while IFS='|' read -r time sub status type ip msg; do
        # 去除字段两侧空格
        time="${time#"${time%%[![:space:]]*}"}"; time="${time%"${time##*[![:space:]]}"}"
        sub="${sub#"${sub%%[![:space:]]*}"}"; sub="${sub%"${sub##*[![:space:]]}"}"
        status="${status#"${status%%[![:space:]]*}"}"; status="${status%"${status##*[![:space:]]}"}"
        type="${type#"${type%%[![:space:]]*}"}"; type="${type%"${type##*[![:space:]]}"}"

        # 过滤
        if [ -n "$filter" ] && [ "$sub" != "$filter" ]; then
            continue
        fi

        printf "%-20s | %-12s | %-6s | %-5s | %-40s | %s\n" "$time" "$sub" "$status" "$type" "$ip" "$msg"
        shown=$((shown + 1))
    done < <(tail -n 20 "$HISTORY_FILE")

    if [ "$shown" -eq 0 ]; then
        echo "（无匹配记录）"
    fi

    echo ""
    echo "共计 $(wc -l < "$HISTORY_FILE") 条记录"
    echo "=========================================="
}

#===============================================================================
# 工具函数
#===============================================================================

#-------------------------------------------------------------------------------
# FUNCTION: safe_write
# DESCRIPTION: 安全地写入文件
#              先写入临时文件，再原子性地移动到目标位置
#              防止写入过程中断导致文件损坏
# PARAMETERS:
#   $1 - 要写入的内容
#   $2 - 目标文件路径
# RETURNS: 成功返回 0，失败返回 1
#-------------------------------------------------------------------------------
safe_write() {
    local content="$1"
    local file="$2"

    # 使用 $$ 作为临时文件后缀（进程 ID，保证唯一性）
    local tmp_file="${file}.tmp.$$"
    if echo "$content" > "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$file" 2>/dev/null || {
            rm -f "$tmp_file"
            log_error "无法写入文件: $file"
            return 1
        }
    else
        rm -f "$tmp_file"
        log_error "无法写入文件: $file"
        return 1
    fi
    return 0
}

#===============================================================================
# 单条记录处理
#===============================================================================

#-------------------------------------------------------------------------------
# FUNCTION: process_record
# DESCRIPTION: 处理单条记录的 DDNS 更新
#              该记录失败时只影响自身，不中断其它记录
# PARAMETERS: $1 - 记录索引
# RETURNS: 成功返回 0，失败返回 1
#-------------------------------------------------------------------------------
process_record() {
    local idx="$1"
    local sub="${REC_SUB[$idx]}"
    local rtype="${REC_TYPE[$idx]}"
    local iface="${REC_IFACE[$idx]}"
    local ttl="${REC_TTL[$idx]}"
    local domain="${REC_DOMAIN[$idx]}"
    local rid="${REC_ID[$idx]}"

    # 设置该记录的状态文件
    record_state_files "$idx"

    # 记录当前类型，供通知等函数使用
    CURRENT_REC_TYPE="$rtype"

    # 读取之前保存的状态
    local old_ip
    old_ip=$(cat "$DB_FILE" 2>/dev/null || echo "")
    local update_flag
    update_flag=$(cat "$FLAG_FILE" 2>/dev/null || echo "0")
    [ -n "$update_flag" ] || update_flag=0

    log_info "----- 记录 $((idx + 1))/$REC_COUNT: $sub ($rtype) -----"

    # 获取当前 IP 地址
    local current_ip
    if [ "$rtype" = "AAAA" ]; then
        current_ip=$(get_current_ipv6 "$iface")
        if ! is_valid_ipv6 "$current_ip"; then
            log_error "[$sub] 无法获取有效的 IPv6 地址"
            log_error "[$sub] 检测到: '$current_ip'"
            log_error "[$sub] 请检查网卡配置或网络状态"
            record_history "error" "${old_ip:-无}" "无" "获取 IPv6 失败" "$sub"
            return 1
        fi
    else
        current_ip=$(get_current_ipv4 "$iface")
        if ! is_valid_ipv4 "$current_ip"; then
            log_error "[$sub] 无法获取有效的 IPv4 地址"
            log_error "[$sub] 检测到: '$current_ip'"
            log_error "[$sub] 请检查网卡配置或网络状态"
            record_history "error" "${old_ip:-无}" "无" "获取 IPv4 失败" "$sub"
            return 1
        fi
    fi

    # 输出当前状态
    log_info "[$sub] 更新计数: ${update_flag}/${FORCE_UPDATE_CYCLE}"
    log_info "[$sub] 记录类型: $rtype | TTL: $ttl 秒"
    log_info "[$sub] 旧 IP: ${old_ip:-无}"
    log_info "[$sub] 新 IP: $current_ip"

    # 判断是否需要更新 DNS
    # 条件 1: IP 地址发生变化
    # 条件 2: 达到强制更新周期（防止 DNS 记录被篡改或过期）
    if [ "$current_ip" = "$old_ip" ] && [ "$update_flag" -lt "$FORCE_UPDATE_CYCLE" ]; then
        log_info "[$sub] IP 未变化，跳过更新"
        # 递增更新计数器。写入失败不影响本次跳过判断的正确性
        #（IP 确实没变），但意味着下次无法准确判断强制更新周期，
        # 因此记录为失败并告警。
        if ! safe_write "$((update_flag + 1))" "$FLAG_FILE"; then
            log_error "[$sub] 更新计数器写入失败: $FLAG_FILE"
            log_error "[$sub] DNS 未受影响，但强制更新周期判断已失准"
            record_history "error" "${old_ip:-无}" "$current_ip" "状态写入失败（计数器）" "$sub"
            return 1
        fi
        return 0
    fi

    # 执行 DNS 更新
    log_info "[$sub] 正在更新 DNS 记录..."

    # 调用 DNSPod API
    # 注意：db/flag 必须在 API 成功后才落盘。若先写状态再调 API，API 失败时
    # db 里已是新 IP、flag 已归零，下一轮会判定"IP 未变化"而跳过更新，
    # 导致 DNS 永久停留在旧值。
    local response
    local exit_code=0
    response=$(call_dns_api "$current_ip" "$domain" "$rid" "$sub" "$rtype" "$ttl") || exit_code=$?

    local code=$(parse_json_field "$response" "code")
    local message=$(parse_json_field "$response" "message")

    # 处理更新结果
    if [ "$code" = "1" ]; then
        # 成功后才写入状态：保存新 IP 并重置计数器
        #
        # 状态写入失败必须报错：DNS 虽然已经更新成功，但脚本的"已同步"
        # 状态没有落盘，下一轮会重复推送同一 IP。属于状态不一致，
        # 不能报成功。
        local state_ok=1
        if ! safe_write "$current_ip" "$DB_FILE"; then
            log_error "[$sub] 状态写入失败: $DB_FILE"
            state_ok=0
        fi
        if ! safe_write "0" "$FLAG_FILE"; then
            log_error "[$sub] 状态写入失败: $FLAG_FILE"
            state_ok=0
        fi

        if [ "$state_ok" -eq 0 ]; then
            log_error "[$sub] DNS 更新成功但状态落盘失败，下一轮将重复推送"
            record_history "error" "${old_ip:-无}" "$current_ip" "状态写入失败" "$sub"
            send_webhook "error" "$current_ip" "DNS 已更新但状态写入失败: $sub" "$sub"
            return 1
        fi

        log_info "[$sub] 更新成功: $sub -> $current_ip (TTL: $ttl)"
        record_history "success" "${old_ip:-无}" "$current_ip" "$message" "$sub"
        send_webhook "success" "$current_ip" "DNS 更新成功: $sub" "$sub"
        return 0
    else
        log_error "[$sub] 更新失败: $message"
        if [ "$VERBOSE" -eq 1 ]; then
            log_error "[$sub] API 响应: $response"
        fi
        # 失败时保持 db/flag 原样，下一轮会重试
        record_history "error" "${old_ip:-无}" "${current_ip:-无}" "更新失败: $message" "$sub"
        send_webhook "error" "${current_ip:-无}" "DNS 更新失败: $sub - $message" "$sub"
        return 1
    fi
}

#===============================================================================
# 主函数
#===============================================================================

#-------------------------------------------------------------------------------
# FUNCTION: main
# DESCRIPTION: 脚本主入口函数
#              协调所有组件的执行流程
# FLOW:
#   1. 解析命令行参数
#   2. 执行特定命令（status/test/history）或继续
#   3. 加载配置
#   4. 初始化目录和锁
#   5. 检查网络
#   6. 获取当前 IP
#   7. 判断是否需要更新
#   8. 调用 API 更新 DNS
#   9. 记录历史和发送通知
#-------------------------------------------------------------------------------
main() {
    parse_args "$@"

    # 处理非 run 命令
    case "$COMMAND" in
        status)
            do_status
            exit $?
            ;;
        test)
            do_test
            exit $?
            ;;
        history)
            do_history
            exit $?
            ;;
        list)
            do_list
            exit $?
            ;;
        records)
            if [ "$RECORDS_GENERATE" -eq 1 ]; then
                do_records_generate "$RECORDS_TARGET"
            else
                do_records "$RECORDS_TARGET"
            fi
            exit $?
            ;;
    esac

    # === 以下是 run 命令的执行流程 ===

    load_config           # 加载配置文件
    init_dirs             # 初始化目录和文件
    acquire_lock || exit 1  # 获取锁（防止并发执行）
    rotate_log            # 日志轮转

    # 加载记录列表（多记录文件优先，回退到配置文件的单条记录）
    if ! load_records; then
        log_error "没有可用的记录，退出"
        exit 1
    fi

    # 检查网络连通性
    if ! check_network; then
        exit 1
    fi

    # 逐条处理记录：单条失败不影响其它记录
    local idx
    local failed=0
    local updated=0
    local skipped=0

    for ((idx=0; idx<REC_COUNT; idx++)); do
        if process_record "$idx"; then
            updated=$((updated + 1))
        else
            failed=$((failed + 1))
        fi
    done

    echo ""
    log_info "===== 汇总 ====="
    log_info "记录总数: $REC_COUNT | 成功: $updated | 失败: $failed"
    [ "$skipped" -gt 0 ] && log_info "跳过: $skipped"

    [ "$failed" -gt 0 ] && exit 1
    exit 0
}

#===============================================================================
# 脚本入口
#===============================================================================
main "$@"
