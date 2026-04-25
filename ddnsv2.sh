#!/bin/bash
#
# TX_DDNS - DNSPod 动态 DNS 更新脚本
# https://github.com/skysr/TX_DDNS
#

set -e

# 版本信息
readonly VERSION="2.3.0"
readonly SCRIPT_NAME=$(basename "$0")

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/ddnsv2.conf"

# 默认值
LOG_DIR='/var/log/ddns'
LOCK_DIR='/var/lock'
FORCE_UPDATE_CYCLE=60
LOG_MAX_SIZE=1048576  # 1MB
MAX_RETRY=3
RETRY_DELAY=2
VERBOSE=0
QUIET=0

# TTL 默认值
DEFAULT_TTL=600

# 日志文件路径（延迟初始化）
DB_FILE=""
FLAG_FILE=""
LOG_FILE=""
LOCK_FILE=""
PID_FILE=""
HISTORY_FILE=""

# 清理函数 - 信号处理
cleanup() {
    local exit_code=$?
    
    # 释放锁
    if [ -f "$PID_FILE" ]; then
        local lock_pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ "$lock_pid" = "$$" ]; then
            rm -f "$PID_FILE" "$LOCK_FILE" 2>/dev/null || true
        fi
    fi
    
    if [ $VERBOSE -eq 1 ] && [ $exit_code -ne 0 ]; then
        echo "[INFO] 脚本退出 (code: $exit_code)"
    fi
    exit $exit_code
}
trap cleanup EXIT INT TERM

# 日志函数
log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # 静默模式下只输出错误
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

log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }
log_debug() { log "DEBUG" "$@"; }

# 解析命令行参数
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
            status|test|history)
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
    
    # 保存命令供后续使用
    COMMAND="${command:-run}"
}

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

# 加载配置文件
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "配置文件不存在: $CONFIG_FILE"
        log_error "请复制 ddnsv2.conf.example 为 ddnsv2.conf 并填写配置"
        exit 1
    fi

    # 安全加载配置（防止命令注入）
    while IFS='=' read -r key value || [ -n "$key" ]; do
        # 跳过注释和空行
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue

        # 去除首尾空格
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)

        # 去除引号
        value="${value#\'}"
        value="${value%\'}"
        value="${value#\"}"
        value="${value%\"}"

        # 设置变量
        case "$key" in
            LOGIN_TOKEN|DOMAIN_ID|RECORD_ID|SUB_DOMAIN|RECORD_TYPE|NETWORK_INTERFACE|LOG_DIR|FORCE_UPDATE_CYCLE|MAX_RETRY|RETRY_DELAY|RECORD_TTL|WEBHOOK_URL|WEBHOOK_METHOD|HISTORY_MAX)
                declare -g "$key=$value"
                ;;
        esac
    done < "$CONFIG_FILE"

    # 验证必要配置
    validate_config
}

# 配置验证
validate_config() {
    local missing=()
    [ -z "$LOGIN_TOKEN" ] && missing+=("LOGIN_TOKEN")
    [ -z "$DOMAIN_ID" ] && missing+=("DOMAIN_ID")
    [ -z "$RECORD_ID" ] && missing+=("RECORD_ID")
    [ -z "$SUB_DOMAIN" ] && missing+=("SUB_DOMAIN")
    [ -z "$RECORD_TYPE" ] && missing+=("RECORD_TYPE")

    if [ ${#missing[@]} -gt 0 ]; then
        log_error "配置文件缺少必要字段: ${missing[*]}"
        exit 1
    fi

    # 验证 LOGIN_TOKEN 格式
    if ! [[ "$LOGIN_TOKEN" =~ ^[0-9]+,[a-zA-Z0-9]+$ ]]; then
        log_error "LOGIN_TOKEN 格式错误，应为: ID,Token"
        log_error "当前值: ${LOGIN_TOKEN:0:4}****"
        exit 1
    fi

    # 验证记录类型
    if [[ ! "$RECORD_TYPE" =~ ^(A|AAAA)$ ]]; then
        log_error "RECORD_TYPE 必须是 A 或 AAAA，当前: $RECORD_TYPE"
        exit 1
    fi

    # 验证强制更新周期
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

    # 验证 TTL
    if ! [[ "$RECORD_TTL" =~ ^[0-9]+$ ]] || [ "$RECORD_TTL" -lt 1 ]; then
        RECORD_TTL=$DEFAULT_TTL
    fi
    # TTL 必须 >= 1 或特定值
    if [ "$RECORD_TTL" -lt 1 ]; then
        RECORD_TTL=$DEFAULT_TTL
    fi

    # 验证历史记录最大条数
    if ! [[ "$HISTORY_MAX" =~ ^[0-9]+$ ]] || [ "$HISTORY_MAX" -lt 1 ]; then
        HISTORY_MAX=100
    fi

    log_debug "配置验证通过"
}

# 创建日志目录和锁目录
init_dirs() {
    if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
        log_error "无法创建日志目录: $LOG_DIR"
        exit 1
    fi

    if ! mkdir -p "$LOCK_DIR" 2>/dev/null; then
        log_warn "无法创建锁目录: $LOCK_DIR，使用 /tmp"
        LOCK_DIR="/tmp"
    fi

    DB_FILE="$LOG_DIR/db"
    FLAG_FILE="$LOG_DIR/flag"
    LOG_FILE="$LOG_DIR/ddns.log"
    LOCK_FILE="$LOCK_DIR/ddns.lock"
    PID_FILE="$LOCK_DIR/ddns.pid"
    HISTORY_FILE="$LOG_DIR/history.log"

    # 初始化文件
    [ -f "$DB_FILE" ] || touch "$DB_FILE"
    [ -f "$FLAG_FILE" ] || echo "0" > "$FLAG_FILE"
    [ -f "$HISTORY_FILE" ] || touch "$HISTORY_FILE"

    log_debug "目录初始化完成: $LOG_DIR"
}

# 获取锁（防止并发执行）
acquire_lock() {
    local timeout=30
    local start_time=$(date +%s)

    while true; do
        # 尝试创建锁文件
        if mkdir "$LOCK_FILE" 2>/dev/null; then
            echo "$$" > "$PID_FILE"
            log_debug "获取锁成功 (PID: $$)"
            return 0
        fi

        # 检查是否有旧进程在运行
        if [ -f "$PID_FILE" ]; then
            local old_pid=$(cat "$PID_FILE" 2>/dev/null)
            if [ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null; then
                log_warn "清理僵尸锁 (PID: $old_pid)"
                rm -rf "$LOCK_FILE" "$PID_FILE" 2>/dev/null
                continue
            fi
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

# 日志轮转
rotate_log() {
    if [ ! -f "$LOG_FILE" ]; then
        return
    fi

    local size
    size=$(stat -c%s "$LOG_FILE" 2>/dev/null || echo "0")

    if [ "$size" -gt "$LOG_MAX_SIZE" ]; then
        local backup="${LOG_FILE}.$(date +%Y%m%d%H%M%S)"
        mv "$LOG_FILE" "$backup" 2>/dev/null || return

        # 尝试压缩旧日志
        if command -v gzip &>/dev/null; then
            gzip "$backup" 2>/dev/null &
        fi

        log_info "日志已轮转: $backup"
    fi
}

# 检查网络连通性
check_network() {
    local attempts=3
    local timeout=3

    for ((i=1; i<=attempts; i++)); do
        # 尝试 IPv4
        if ping -c 1 -W $timeout 8.8.8.8 >/dev/null 2>&1; then
            log_debug "网络检查通过 (IPv4)"
            return 0
        fi
        # 尝试 IPv6
        if ping -c 1 -W $timeout 2001:4860:4860::8888 >/dev/null 2>&1; then
            log_debug "网络检查通过 (IPv6)"
            return 0
        fi
        [ $i -lt $attempts ] && sleep 1
    done

    log_error "网络不可用"
    return 1
}

# 验证 IPv6 地址格式
is_valid_ipv6() {
    local ip="$1"

    [ -z "$ip" ] && return 1

    [[ "$ip" =~ ^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$ ]] && return 0
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

# 验证 IPv4 地址格式
is_valid_ipv4() {
    local ip="$1"

    [ -z "$ip" ] && return 1

    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        read -ra octets <<< "$ip"
        for octet in "${octets[@]}"; do
            [ "$octet" -gt 255 ] && return 1
        done
        return 0
    fi
    return 1
}

# 获取当前 IPv6 地址
get_current_ipv6() {
    local interface="$NETWORK_INTERFACE"
    local ip=""

    if [ -n "$interface" ]; then
        ip=$(ip -6 addr show dev "$interface" scope global 2>/dev/null | \
             grep -oP 'inet6 \K[0-9a-fA-F:]+' | head -1)
    else
        ip=$(ip -6 addr show scope global 2>/dev/null | \
             grep -oP 'inet6 \K[0-9a-fA-F:]+' | head -1)
    fi

    echo "$ip"
}

# 获取当前 IPv4 地址
get_current_ipv4() {
    local interface="$NETWORK_INTERFACE"
    local ip=""

    if [ -n "$interface" ]; then
        ip=$(ip -4 addr show dev "$interface" scope global 2>/dev/null | \
             grep -oP 'inet \K[0-9.]+' | head -1)
    else
        ip=$(ip -4 addr show scope global 2>/dev/null | \
             grep -oP 'inet \K[0-9.]+' | head -1)
    fi

    echo "$ip"
}

# 获取公网 IP（通过外部服务）
get_public_ip() {
    local ip_type="$1"
    local ip
    
    case "$ip_type" in
        ipv6|AAAA)
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

# 纯 Bash JSON 字段提取
parse_json_field() {
    local json="$1"
    local field="$2"
    local value

    value=$(echo "$json" | grep -oP "\"$field\"\s*:\s*\"[^\"]*\"" | \
            sed 's/.*: *"\([^"]*\)".*/\1/' | head -1)

    if [ -z "$value" ]; then
        value=$(echo "$json" | grep -oP "\"$field\"\s*:\s*[0-9]+" | \
                sed 's/.*: *\([0-9]*\).*/\1/' | head -1)
    fi

    echo "$value"
}

# 发送 Webhook 通知
send_webhook() {
    local status="$1"
    local ip="$2"
    local message="$3"
    
    [ -z "$WEBHOOK_URL" ] && return 0
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local method="${WEBHOOK_METHOD:-POST}"
    
    # 构建通知内容
    local payload
    case "$WEBHOOK_URL" in
        *discord.com*|*discordapp.com*)
            # Discord Webhook 格式
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
            # Slack Webhook 格式
            local emoji=":white_check_mark:"
            [ "$status" = "error" ] && emoji=":x:"
            payload="payload={\"text\":\"$emoji TX_DDNS: $message\nIP: $ip\n时间: $timestamp\"}"
            ;;
        *telegram.org*|*api.telegram.org*)
            # Telegram Bot API 格式
            local text="TX_DDNS 通知\n状态: $status\nIP: $ip\n时间: $timestamp\n$message"
            # 如果 URL 不包含 sendMessage，添加它
            if [[ "$WEBHOOK_URL" == *sendMessage* ]]; then
                payload="chat_id=&text=$(echo "$text" | jq -sRr @uri)"
            else
                payload=$(cat <<EOF
{"chat_id": "", "text": "$text"}
EOF
)
            fi
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
    
    # 发送请求
    local response
    response=$(curl -s -X "$method" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --connect-timeout 10 \
        --max-time 30 \
        "$WEBHOOK_URL" 2>&1)
    
    if [ $? -eq 0 ]; then
        log_debug "Webhook 发送成功"
    else
        log_warn "Webhook 发送失败: $response"
    fi
}

# 记录更新历史
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
    
    # 限制历史记录条数
    local count=$(wc -l < "$HISTORY_FILE")
    if [ "$count" -gt "$HISTORY_MAX" ]; then
        tail -n "$HISTORY_MAX" "$HISTORY_FILE" > "${HISTORY_FILE}.tmp"
        mv "${HISTORY_FILE}.tmp" "$HISTORY_FILE"
    fi
}

# 带重试的 API 调用
call_dns_api() {
    local value="$1"
    local attempt=1
    local response code message

    while [ $attempt -le $MAX_RETRY ]; do
        log_debug "API 调用尝试 $attempt/$MAX_RETRY"
        
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

        if [ "$code" = "1" ]; then
            log_debug "API 调用成功"
            echo "$response"
            return 0
        fi

        # 特定错误不重试
        if [[ "$message" =~ "Token" ]] || [[ "$message" =~ "ID" ]]; then
            log_error "认证失败: $message"
            return 1
        fi

        log_warn "API 调用失败 (尝试 $attempt/$MAX_RETRY): $message"
        
        if [ $attempt -lt $MAX_RETRY ]; then
            sleep $RETRY_DELAY
        fi
        
        ((attempt++))
    done

    log_error "API 调用失败，已达最大重试次数"
    echo "$response"
    return 1
}

# 执行状态查询命令
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

# 执行测试命令
do_test() {
    load_config
    init_dirs
    
    echo "=========================================="
    echo "         TX_DDNS 配置测试"
    echo "=========================================="
    echo ""
    
    local errors=0
    
    echo "✓ 测试网络连通性..."
    if check_network; then
        echo "  网络正常"
    else
        echo "  ✗ 网络不可用"
        ((errors++))
    fi
    
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
        ((errors++))
    fi
    
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
        ((errors++))
    fi
    
    echo ""
    echo "✓ 测试 IP 获取..."
    local current_ip
    if [ "$RECORD_TYPE" = "AAAA" ]; then
        current_ip=$(get_current_ipv6)
        if is_valid_ipv6 "$current_ip"; then
            echo "  IPv6 获取成功: $current_ip"
        else
            echo "  ✗ 无法获取有效 IPv6: '$current_ip'"
            ((errors++))
        fi
    else
        current_ip=$(get_current_ipv4)
        if is_valid_ipv4 "$current_ip"; then
            echo "  IPv4 获取成功: $current_ip"
        else
            echo "  ✗ 无法获取有效 IPv4: '$current_ip'"
            ((errors++))
        fi
    fi
    
    echo ""
    echo "✓ 测试日志目录..."
    if [ -w "$LOG_DIR" ]; then
        echo "  日志目录可写"
    else
        echo "  ✗ 日志目录不可写: $LOG_DIR"
        ((errors++))
    fi
    
    # 测试 Webhook
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

# 显示更新历史
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
    
    # 显示历史记录（最多20条）
    tail -n 20 "$HISTORY_FILE" | while IFS='|' read -r time status type ip msg; do
        printf "%-20s | %-6s | %-5s | %-40s | %s\n" "$time" "$status" "$type" "$ip" "$msg"
    done
    
    echo ""
    echo "共计 $(wc -l < "$HISTORY_FILE") 条记录"
    echo "=========================================="
}

# 安全的文件写入
safe_write() {
    local content="$1"
    local file="$2"

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

# 主函数
main() {
    parse_args "$@"
    
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
    
    load_config
    init_dirs
    acquire_lock || exit 1
    rotate_log

    # 检查网络
    if ! check_network; then
        exit 1
    fi

    # 读取之前的值
    local old_ip=$(cat "$DB_FILE" 2>/dev/null || echo "")
    local update_flag=$(cat "$FLAG_FILE" 2>/dev/null || echo "0")

    # 获取当前 IP
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

    # 显示状态
    log_info "更新计数: ${update_flag}/${FORCE_UPDATE_CYCLE}"
    log_info "记录类型: $RECORD_TYPE"
    log_info "TTL: $RECORD_TTL 秒"
    log_info "旧 IP: ${old_ip:-无}"
    log_info "新 IP: $current_ip"

    # 判断是否需要更新
    if [ "$current_ip" = "$old_ip" ] && [ "${update_flag:-0}" -lt "$FORCE_UPDATE_CYCLE" ]; then
        log_info "IP 未变化，跳过更新"
        safe_write "$((update_flag + 1))" "$FLAG_FILE"
        exit 0
    fi

    # 执行更新
    log_info "正在更新 DNS 记录..."
    safe_write "0" "$FLAG_FILE"
    safe_write "$current_ip" "$DB_FILE"

    local response=$(call_dns_api "$current_ip")
    local exit_code=$?
    
    local code=$(parse_json_field "$response" "code")
    local message=$(parse_json_field "$response" "message")

    if [ "$code" = "1" ]; then
        log_info "更新成功: $SUB_DOMAIN -> $current_ip (TTL: $RECORD_TTL)"
        record_history "success" "${old_ip:-无}" "$current_ip" "$message"
        send_webhook "success" "$current_ip" "DNS 更新成功: $SUB_DOMAIN"
        exit 0
    else
        log_error "更新失败: $message"
        if [ "$VERBOSE" -eq 1 ]; then
            log_error "API 响应: $response"
        fi
        record_history "error" "${old_ip:-无}" "${current_ip:-无}" "更新失败: $message"
        send_webhook "error" "${current_ip:-无}" "DNS 更新失败: $SUB_DOMAIN - $message"
        exit 1
    fi
}

main "$@"
