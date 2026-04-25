#!/bin/bash

set -e

# 脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/ddnsv2.conf"

# 默认值
LOG_DIR='/var/log/ddns'
FORCE_UPDATE_CYCLE=60
VERBOSE=0
QUIET=0

# 日志函数
log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if [ "$QUIET" -eq 1 ] && [ "$level" != "ERROR" ]; then
        return
    fi
    
    if [ "$VERBOSE" -eq 1 ] || [ "$level" = "ERROR" ] || [ "$level" = "INFO" ]; then
        echo "[$timestamp] [$level] $msg"
    fi
    
    # 写入日志文件
    echo "[$timestamp] [$level] $msg" >> "$LOG_DIR/ddns.log" 2>/dev/null || true
}

log_info() { log "INFO" "$@"; }
log_warn() { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

# 解析命令行参数
parse_args() {
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
            -h|--help)
                echo "用法: $0 [选项]"
                echo "选项:"
                echo "  -v, --verbose    详细输出"
                echo "  -q, --quiet      静默模式（仅输出错误）"
                echo "  -c, --config     指定配置文件路径"
                echo "  -h, --help       显示帮助信息"
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                exit 1
                ;;
        esac
    done
}

# 加载配置文件
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "配置文件不存在: $CONFIG_FILE"
        log_error "请复制 ddnsv2.conf.example 为 ddnsv2.conf 并填写配置"
        exit 1
    fi
    
    source "$CONFIG_FILE"
    
    # 验证必要配置
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
}

# 创建日志目录
init_dirs() {
    mkdir -p "$LOG_DIR" 2>/dev/null || {
        log_error "无法创建日志目录: $LOG_DIR"
        exit 1
    }
    
    DB_FILE="$LOG_DIR/db"
    FLAG_FILE="$LOG_DIR/flag"
    
    [ -f "$DB_FILE" ] || echo "" > "$DB_FILE"
    [ -f "$FLAG_FILE" ] || echo "0" > "$FLAG_FILE"
}

# 检查网络连通性
check_network() {
    if ! ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        if ! ping -c 1 -W 3 2001:4860:4860::8888 >/dev/null 2>&1; then
            log_error "网络不可用，无法更新 DNS"
            return 1
        fi
    fi
    log_info "网络检查通过"
    return 0
}

# 获取当前 IPv6 地址
get_current_ipv6() {
    local interface="$NETWORK_INTERFACE"
    local ip
    
    if [ -n "$interface" ]; then
        ip=$(ip -6 addr show dev "$interface" scope global 2>/dev/null | grep -oP 'inet6 \K[0-9a-fA-F:]+' | head -1)
    else
        # 自动检测全局 IPv6
        ip=$(ip -6 addr show scope global 2>/dev/null | grep -oP 'inet6 \K[0-9a-fA-F:]+' | head -1)
    fi
    
    echo "$ip"
}

# 获取当前 IPv4 地址
get_current_ipv4() {
    local interface="$NETWORK_INTERFACE"
    local ip
    
    if [ -n "$interface" ]; then
        ip=$(ip -4 addr show dev "$interface" scope global 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
    else
        ip=$(ip -4 addr show scope global 2>/dev/null | grep -oP 'inet \K[0-9.]+' | head -1)
    fi
    
    echo "$ip"
}

# 验证 IPv6 地址格式
is_valid_ipv6() {
    [[ $1 =~ ^([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}$ ]] || \
    [[ $1 =~ ^(([0-9a-fA-F]{1,4}:){0,6}[0-9a-fA-F]{1,4})?::(([0-9a-fA-F]{1,4}:){0,6}[0-9a-fA-F]{1,4})?$ ]]
}

# 验证 IPv4 地址格式
is_valid_ipv4() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && \
    IFS='.' read -ra octets <<< "$1" && \
    [[ ${octets[0]} -le 255 && ${octets[1]} -le 255 && ${octets[2]} -le 255 && ${octets[3]} -le 255 ]]
}

# 安全的文件写入
safe_write() {
    echo "$1" > "$2" 2>/dev/null || {
        log_error "无法写入文件: $2"
        exit 1
    }
}

# 解析 API JSON 响应
parse_api_response() {
    local response="$1"
    python3 -c "
import sys, json
try:
    data = json.loads(sys.stdin.read())
    code = data.get('status', {}).get('code', '-1')
    message = data.get('status', {}).get('message', 'Unknown error')
    print(f'{code}|{message}')
except:
    print('-1|Invalid JSON response')
" <<< "$response"
}

# 调用 DNSPod API
call_dns_api() {
    local value="$1"
    
    curl -s -X POST https://dnsapi.cn/Record.Modify \
        -d "login_token=$LOGIN_TOKEN" \
        -d "format=json" \
        -d "domain_id=$DOMAIN_ID" \
        -d "record_id=$RECORD_ID" \
        -d "record_line_id=0" \
        -d "sub_domain=$SUB_DOMAIN" \
        -d "value=$value" \
        -d "record_type=$RECORD_TYPE"
}

# 主函数
main() {
    parse_args "$@"
    load_config
    init_dirs
    
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
            exit 1
        fi
    elif [ "$RECORD_TYPE" = "A" ]; then
        current_ip=$(get_current_ipv4)
        if ! is_valid_ipv4 "$current_ip"; then
            log_error "无法获取有效的 IPv4 地址"
            exit 1
        fi
    else
        log_error "不支持的记录类型: $RECORD_TYPE"
        exit 1
    fi
    
    # 显示状态
    log_info "更新计数: ${update_flag:-0}/${FORCE_UPDATE_CYCLE}"
    log_info "当前 DNS: ${SUB_DOMAIN}.<domain>"
    log_info "旧 IP: $old_ip"
    log_info "新 IP: $current_ip"
    
    # 判断是否需要更新
    if [ "$current_ip" = "$old_ip" ] && [ "${update_flag:-0}" -lt "$FORCE_UPDATE_CYCLE" ]; then
        log_info "IP 未变化，跳过更新"
        safe_write $((update_flag + 1)) "$FLAG_FILE"
        exit 0
    fi
    
    # 执行更新
    log_info "正在更新 DNS 记录..."
    safe_write "0" "$FLAG_FILE"
    safe_write "$current_ip" "$DB_FILE"
    
    local response=$(call_dns_api "$current_ip")
    local result=$(parse_api_response "$response")
    local code="${result%%|*}"
    local message="${result##*|}"
    
    if [ "$code" = "1" ]; then
        log_info "更新成功: $current_ip"
    else
        log_error "更新失败: $message"
        log_error "API 响应: $response"
        exit 1
    fi
}

main "$@"
