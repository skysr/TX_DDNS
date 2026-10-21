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

readonly VERSION="2.4.0"                    # 脚本版本号
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
            run|status|test|history)
                command="$1"
                shift
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
  run       运行 DDNS 更新（默认）
  status    显示当前 DNS 记录和本地 IP 状态
  test      测试配置，不实际更新 DNS
  history   显示更新历史记录

选项:
  -v, --verbose     详细输出模式
  -q, --quiet       静默模式（仅输出错误）
  -c, --config      指定配置文件路径
  -V, --version     显示版本信息
  -h, --help        显示帮助信息

示例:
  $SCRIPT_NAME              # 运行更新
  $SCRIPT_NAME status       # 查看状态
  $SCRIPT_NAME test         # 测试配置
  $SCRIPT_NAME history      # 查看历史
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
            LOGIN_TOKEN|DOMAIN_ID|RECORD_ID|SUB_DOMAIN|RECORD_TYPE|NETWORK_INTERFACE|LOG_DIR|LOCK_DIR|FORCE_UPDATE_CYCLE|MAX_RETRY|RETRY_DELAY|RECORD_TTL|WEBHOOK_URL|WEBHOOK_METHOD|WEBHOOK_CHAT_ID|HISTORY_MAX)
                declare -g "$key=$value"
                ;;
        esac
    done < "$CONFIG_FILE"

    # 验证配置完整性
    validate_config
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
    [ -z "$LOGIN_TOKEN" ] && missing+=("LOGIN_TOKEN")
    [ -z "$DOMAIN_ID" ] && missing+=("DOMAIN_ID")
    [ -z "$RECORD_ID" ] && missing+=("RECORD_ID")
    [ -z "$SUB_DOMAIN" ] && missing+=("SUB_DOMAIN")
    [ -z "$RECORD_TYPE" ] && missing+=("RECORD_TYPE")

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
    if [[ ! "$RECORD_TYPE" =~ ^(A|AAAA)$ ]]; then
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
    DB_FILE="$LOG_DIR/db"                   # 存储 IP 地址
    FLAG_FILE="$LOG_DIR/flag"               # 更新计数器
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
    [ -f "$DB_FILE" ] || touch "$DB_FILE"
    [ -f "$FLAG_FILE" ] || echo "0" > "$FLAG_FILE"
    [ -f "$HISTORY_FILE" ] || touch "$HISTORY_FILE"

    log_debug "目录初始化完成: $LOG_DIR"
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
    local interface="$NETWORK_INTERFACE"
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
    local interface="$NETWORK_INTERFACE"
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
    status_block=$(printf '%s' "$json" | grep -oP '"status"\s*:\s*\{[^}]*\}' | head -1)

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
        value=$(printf '%s' "$json" | grep -oP "\"$field\"\s*:\s*\"[^\"]*\"" | \
                sed 's/.*: *"\([^"]*\)".*/\1/' | head -1)

        # 如果没有字符串值，尝试提取数值
        if [ -z "$value" ]; then
            value=$(printf '%s' "$json" | grep -oP "\"$field\"\s*:\s*[0-9]+" | \
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
{"text":"$emoji TX_DDNS: $message\nIP: $ip\n时间: $timestamp"}
EOF
)
            ;;
        *telegram.org*)
            # Telegram Bot API 格式
            # 纯 bash URL 编码，不依赖 jq（README 声明无外部依赖）
            local text="TX_DDNS 通知
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
  "domain": "$SUB_DOMAIN",
  "type": "$RECORD_TYPE"
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

    [ ! -f "$HISTORY_FILE" ] && touch "$HISTORY_FILE"

    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local entry="$timestamp | $status | $RECORD_TYPE | $old_ip -> $new_ip | $message"

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
    local attempt=1
    local response code message

    while [ $attempt -le $MAX_RETRY ]; do
        log_debug "API 调用尝试 $attempt/$MAX_RETRY"

        # 调用 DNSPod Record.Modify API
        # 文档: https://docs.dnspod.cn/api/record_modify/
        response=$(curl -s -X POST https://dnsapi.cn/Record.Modify \
            -d "login_token=$LOGIN_TOKEN" \
            -d "format=json" \
            -d "domain_id=$DOMAIN_ID" \
            -d "record_id=$RECORD_ID" \
            -d "record_line_id=0" \
            -d "sub_domain=$SUB_DOMAIN" \
            -d "value=$value" \
            -d "record_type=$RECORD_TYPE" \
            -d "ttl=$RECORD_TTL" \
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

    echo "=========================================="
    echo "         TX_DDNS 状态报告"
    echo "=========================================="
    echo ""

    echo "【DNS 记录状态】"
    echo "  子域名:    $SUB_DOMAIN"
    echo "  记录类型:  $RECORD_TYPE"
    echo "  TTL:       ${RECORD_TTL:-$DEFAULT_TTL} 秒"

    echo ""
    echo "【本地 IP 状态】"

    local local_ip=""
    if [ "$RECORD_TYPE" = "AAAA" ]; then
        local_ip=$(get_current_ipv6)
        echo "  本地 IPv6: ${local_ip:-未获取到}"
        [ -n "$local_ip" ] && is_valid_ipv6 "$local_ip" && echo "  格式验证:  有效" || echo "  格式验证:  无效"
    else
        local_ip=$(get_current_ipv4)
        echo "  本地 IPv4: ${local_ip:-未获取到}"
        [ -n "$local_ip" ] && is_valid_ipv4 "$local_ip" && echo "  格式验证:  有效" || echo "  格式验证:  无效"
    fi

    echo ""
    echo "【历史记录】"
    local old_ip=$(cat "$DB_FILE" 2>/dev/null || echo "")
    local update_flag=$(cat "$FLAG_FILE" 2>/dev/null || echo "0")
    echo "  上次 IP:   ${old_ip:-无}"
    echo "  更新计数:  ${update_flag}/${FORCE_UPDATE_CYCLE}"

    if [ -f "$HISTORY_FILE" ] && [ -s "$HISTORY_FILE" ]; then
        local last_update=$(tail -1 "$HISTORY_FILE" 2>/dev/null)
        echo "  最近更新:  $last_update"
    fi

    echo ""
    echo "【网络状态】"
    if check_network; then
        echo "  网络连接:  正常"
    else
        echo "  网络连接:  异常"
    fi

    echo ""
    echo "【配置信息】"
    echo "  配置文件:  $CONFIG_FILE"
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

    # 测试 3: 域名和记录访问权限
    echo ""
    echo "✓ 测试域名权限..."
    response=$(curl -s -X POST https://dnsapi.cn/Record.Info \
        -d "login_token=$LOGIN_TOKEN&format=json&domain_id=$DOMAIN_ID&record_id=$RECORD_ID" 2>&1)

    code=$(parse_json_field "$response" "code")
    if [ "$code" = "1" ]; then
        local record_name=$(parse_json_field "$response" "name")
        local record_type=$(parse_json_field "$response" "type")
        local record_value=$(parse_json_field "$response" "value")
        echo "  记录名称: $record_name"
        echo "  记录类型: $record_type"
        echo "  当前值:   $record_value"
        echo "  当前 TTL: ${RECORD_TTL:-$DEFAULT_TTL}"
    else
        local message=$(parse_json_field "$response" "message")
        echo "  ✗ 无法访问记录: $message"
        errors=$((errors + 1))
    fi

    # 测试 4: IP 获取
    echo ""
    echo "✓ 测试 IP 获取..."
    local current_ip
    if [ "$RECORD_TYPE" = "AAAA" ]; then
        current_ip=$(get_current_ipv6)
        if is_valid_ipv6 "$current_ip"; then
            echo "  IPv6 获取成功: $current_ip"
        else
            echo "  ✗ 无法获取有效 IPv6: '$current_ip'"
            errors=$((errors + 1))
        fi
    else
        current_ip=$(get_current_ipv4)
        if is_valid_ipv4 "$current_ip"; then
            echo "  IPv4 获取成功: $current_ip"
        else
            echo "  ✗ 无法获取有效 IPv4: '$current_ip'"
            errors=$((errors + 1))
        fi
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

    echo "最近 $HISTORY_MAX 条记录:"
    echo ""
    printf "%-20s | %-6s | %-5s | %-40s | %s\n" "时间" "状态" "类型" "IP 变化" "消息"
    echo "----------------------------------------------------------------------------------------"

    # 显示最近 20 条历史记录
    tail -n 20 "$HISTORY_FILE" | while IFS='|' read -r time status type ip msg; do
        printf "%-20s | %-6s | %-5s | %-40s | %s\n" "$time" "$status" "$type" "$ip" "$msg"
    done

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
    esac

    # === 以下是 run 命令的执行流程 ===

    load_config           # 加载配置文件
    init_dirs             # 初始化目录和文件
    acquire_lock || exit 1  # 获取锁（防止并发执行）
    rotate_log            # 日志轮转

    # 检查网络连通性
    if ! check_network; then
        exit 1
    fi

    # 读取之前保存的状态
    local old_ip=$(cat "$DB_FILE" 2>/dev/null || echo "")
    local update_flag=$(cat "$FLAG_FILE" 2>/dev/null || echo "0")

    # 获取当前 IP 地址
    local current_ip
    if [ "$RECORD_TYPE" = "AAAA" ]; then
        current_ip=$(get_current_ipv6)
        if ! is_valid_ipv6 "$current_ip"; then
            log_error "无法获取有效的 IPv6 地址"
            log_error "检测到: '$current_ip'"
            log_error "请检查 NETWORK_INTERFACE 配置或网络状态"
            exit 1
        fi
    elif [ "$RECORD_TYPE" = "A" ]; then
        current_ip=$(get_current_ipv4)
        if ! is_valid_ipv4 "$current_ip"; then
            log_error "无法获取有效的 IPv4 地址"
            log_error "检测到: '$current_ip'"
            log_error "请检查 NETWORK_INTERFACE 配置或网络状态"
            exit 1
        fi
    fi

    # 输出当前状态
    log_info "更新计数: ${update_flag}/${FORCE_UPDATE_CYCLE}"
    log_info "记录类型: $RECORD_TYPE"
    log_info "TTL: $RECORD_TTL 秒"
    log_info "旧 IP: ${old_ip:-无}"
    log_info "新 IP: $current_ip"

    # 判断是否需要更新 DNS
    # 条件 1: IP 地址发生变化
    # 条件 2: 达到强制更新周期（防止 DNS 记录被篡改或过期）
    if [ "$current_ip" = "$old_ip" ] && [ "${update_flag:-0}" -lt "$FORCE_UPDATE_CYCLE" ]; then
        log_info "IP 未变化，跳过更新"
        # 递增更新计数器
        safe_write "$((update_flag + 1))" "$FLAG_FILE"
        exit 0
    fi

    # 执行 DNS 更新
    log_info "正在更新 DNS 记录..."

    # 调用 DNSPod API
    # 注意：db/flag 必须在 API 成功后才落盘。若先写状态再调 API，API 失败时
    # db 里已是新 IP、flag 已归零，下一轮会判定"IP 未变化"而跳过更新，
    # 导致 DNS 永久停留在旧值。
    local response
    local exit_code=0
    response=$(call_dns_api "$current_ip") || exit_code=$?

    local code=$(parse_json_field "$response" "code")
    local message=$(parse_json_field "$response" "message")

    # 处理更新结果
    if [ "$code" = "1" ]; then
        # 成功后才写入状态：保存新 IP 并重置计数器
        safe_write "$current_ip" "$DB_FILE"
        safe_write "0" "$FLAG_FILE"

        log_info "更新成功: $SUB_DOMAIN -> $current_ip (TTL: $RECORD_TTL)"
        record_history "success" "${old_ip:-无}" "$current_ip" "$message"
        send_webhook "success" "$current_ip" "DNS 更新成功: $SUB_DOMAIN"
        exit 0
    else
        log_error "更新失败: $message"
        if [ "$VERBOSE" -eq 1 ]; then
            log_error "API 响应: $response"
        fi
        # 失败时保持 db/flag 原样，下一轮会重试
        record_history "error" "${old_ip:-无}" "${current_ip:-无}" "更新失败: $message"
        send_webhook "error" "${current_ip:-无}" "DNS 更新失败: $SUB_DOMAIN - $message"
        exit 1
    fi
}

#===============================================================================
# 脚本入口
#===============================================================================
main "$@"
