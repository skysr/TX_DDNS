#!/bin/bash
#
# TX_DDNS 一键安装脚本
# 自动配置并部署 DDNS 服务
#

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 版本信息
VERSION="2.3.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 安装路径
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/ddns"
LOG_DIR="/var/log/ddns"
SERVICE_DIR="/etc/systemd/system"

# 打印函数
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
prompt() { echo -en "${BLUE}[?]${NC} $*"; }

# 检查 root 权限
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "请使用 root 权限运行此脚本"
        echo "使用: sudo $0"
        exit 1
    fi
}

# 检查依赖
check_dependencies() {
    local missing=()

    command -v curl >/dev/null || missing+=("curl")
    command -v ip >/dev/null || missing+=("iproute2")

    if [ ${#missing[@]} -gt 0 ]; then
        error "缺少依赖: ${missing[*]}"
        echo ""
        echo "安装依赖:"
        echo "  Debian/Ubuntu: apt install ${missing[*]}"
        echo "  CentOS/RHEL:   yum install ${missing[*]}"
        echo "  Arch Linux:    pacman -S ${missing[*]}"
        exit 1
    fi

    info "依赖检查通过"
}

# 交互式配置
interactive_config() {
    echo ""
    echo "=========================================="
    echo "       TX_DDNS 配置向导"
    echo "=========================================="
    echo ""

    # DNSPod API Token
    prompt "请输入 DNSPod API Token (格式: ID,Token): "
    read -r LOGIN_TOKEN

    if [[ ! "$LOGIN_TOKEN" =~ ^[0-9]+,[a-zA-Z0-9]+$ ]]; then
        error "Token 格式错误，应为: ID,Token"
        exit 1
    fi

    # 域名 ID
    prompt "请输入域名 ID (domain_id): "
    read -r DOMAIN_ID

    # 记录 ID
    prompt "请输入记录 ID (record_id): "
    read -r RECORD_ID

    # 子域名
    prompt "请输入子域名 (如 www, 留空为 @): "
    read -r SUB_DOMAIN
    [ -z "$SUB_DOMAIN" ] && SUB_DOMAIN="@"

    # 记录类型
    echo ""
    echo "记录类型:"
    echo "  1) AAAA (IPv6) - 推荐"
    echo "  2) A (IPv4)"
    prompt "请选择 [1/2]: "
    read -r record_choice

    case "$record_choice" in
        2) RECORD_TYPE="A";;
        *) RECORD_TYPE="AAAA";;
    esac

    # 网卡
    echo ""
    echo "可用网卡:"
    ip -br link show | grep -v "lo" | awk '{print "  - "$1}'
    prompt "请输入网卡名称 (留空自动检测): "
    read -r NETWORK_INTERFACE

    # 更新间隔
    prompt "更新间隔分钟数 [1]: "
    read -r interval
    INTERVAL="${interval:-1}"

    # TTL
    prompt "DNS TTL 秒数 [600]: "
    read -r ttl
    RECORD_TTL="${ttl:-600}"

    # Webhook
    echo ""
    echo "Webhook 通知配置 (可选，留空跳过)"
    prompt "Webhook URL: "
    read -r WEBHOOK_URL

    echo ""
    echo "=========================================="
    echo "配置摘要:"
    echo "  Token:          ${LOGIN_TOKEN%%,*}****"
    echo "  域名 ID:        $DOMAIN_ID"
    echo "  记录 ID:        $RECORD_ID"
    echo "  子域名:         $SUB_DOMAIN"
    echo "  记录类型:       $RECORD_TYPE"
    echo "  网卡:           ${NETWORK_INTERFACE:-自动检测}"
    echo "  TTL:            $RECORD_TTL 秒"
    echo "  更新间隔:       每 ${INTERVAL} 分钟"
    echo "  Webhook:        ${WEBHOOK_URL:-未配置}"
    echo "=========================================="
    echo ""

    prompt "确认安装? [Y/n]: "
    read -r confirm
    [[ "$confirm" =~ ^[Nn] ]] && { warn "安装已取消"; exit 0; }
}

# 生成配置文件
generate_config() {
    mkdir -p "$CONFIG_DIR"

    cat > "$CONFIG_DIR/ddns.conf" << EOF
# TX_DDNS 配置文件
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

# DNSPod API Token
LOGIN_TOKEN='$LOGIN_TOKEN'

# 域名信息
DOMAIN_ID='$DOMAIN_ID'
RECORD_ID='$RECORD_ID'
SUB_DOMAIN='$SUB_DOMAIN'

# 记录类型: A 或 AAAA
RECORD_TYPE='$RECORD_TYPE'

# 网卡名称（留空自动检测）
NETWORK_INTERFACE='$NETWORK_INTERFACE'

# DNS TTL (秒)
RECORD_TTL='$RECORD_TTL'

# 日志目录
LOG_DIR='$LOG_DIR'

# 强制更新周期（间隔分钟数 × 60）
FORCE_UPDATE_CYCLE=$(((INTERVAL > 0 ? INTERVAL : 1) * 60))

# Webhook 通知 (可选)
WEBHOOK_URL='$WEBHOOK_URL'

# 更新历史最大记录数
HISTORY_MAX=100
EOF

    chmod 600 "$CONFIG_DIR/ddns.conf"
    info "配置文件已生成: $CONFIG_DIR/ddns.conf"
}

# 安装脚本
install_script() {
    # 复制脚本
    cp "$SCRIPT_DIR/ddnsv2.sh" "$INSTALL_DIR/ddnsv2.sh"
    chmod +x "$INSTALL_DIR/ddnsv2.sh"

    # 创建符号链接
    ln -sf "$INSTALL_DIR/ddnsv2.sh" /usr/local/bin/tx-ddns

    info "脚本已安装: $INSTALL_DIR/ddnsv2.sh"
}

# 安装 systemd 服务
install_service() {
    # 创建服务文件
    cat > "$SERVICE_DIR/ddns.service" << EOF
[Unit]
Description=TX_DDNS Dynamic DNS Updater
Documentation=https://github.com/skysr/TX_DDNS
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$INSTALL_DIR/ddnsv2.sh -q -c $CONFIG_DIR/ddns.conf
StandardOutput=journal
StandardError=journal

NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=$LOG_DIR

[Install]
WantedBy=multi-user.target
EOF

    # 创建定时器
    cat > "$SERVICE_DIR/ddns.timer" << EOF
[Unit]
Description=TX_DDNS Timer - Run DDNS update every minute
Documentation=https://github.com/skysr/TX_DDNS

[Timer]
OnCalendar=*:0/${INTERVAL:-1}
Persistent=true
RandomizedDelaySec=30

[Install]
WantedBy=timers.target
EOF

    # 创建日志目录
    mkdir -p "$LOG_DIR"
    chmod 755 "$LOG_DIR"

    # 重载 systemd
    systemctl daemon-reload

    info "Systemd 服务已安装"
}

# 安装 bash 补全
install_completion() {
    local completion_dir="/etc/bash_completion.d"
    
    if [ -d "$completion_dir" ]; then
        cp "$SCRIPT_DIR/ddns-completion.bash" "$completion_dir/ddns"
        info "Bash 补全已安装: $completion_dir/ddns"
        
        # 提示用户重新加载
        echo ""
        echo "  补全功能将在下次登录生效，或执行:"
        echo "  source $completion_dir/ddns"
    else
        warn "未找到 bash-completion 目录，跳过补全安装"
        warn "如需补全功能，请安装: apt install bash-completion"
    fi
}

# 启动服务
start_service() {
    # 停止旧服务（如果存在）
    systemctl stop ddns.timer 2>/dev/null || true
    systemctl stop ddns.service 2>/dev/null || true

    # 启用并启动
    systemctl enable ddns.timer
    systemctl start ddns.timer

    info "服务已启动"

    echo ""
    echo "=========================================="
    echo "安装完成!"
    echo "=========================================="
    echo ""
    echo "使用命令:"
    echo "  查看状态:   systemctl status ddns.timer"
    echo "  查看日志:   journalctl -u ddns.service -f"
    echo "  手动更新:   tx-ddns -v"
    echo "  停止服务:   systemctl stop ddns.timer"
    echo ""
    echo "配置文件:     $CONFIG_DIR/ddns.conf"
    echo "日志目录:     $LOG_DIR"
    echo ""
}

# 卸载
uninstall() {
    info "正在卸载..."

    systemctl stop ddns.timer 2>/dev/null || true
    systemctl disable ddns.timer 2>/dev/null || true
    systemctl stop ddns.service 2>/dev/null || true
    systemctl disable ddns.service 2>/dev/null || true

    rm -f "$SERVICE_DIR/ddns.service"
    rm -f "$SERVICE_DIR/ddns.timer"
    rm -f "$INSTALL_DIR/ddnsv2.sh"
    rm -f /usr/local/bin/tx-ddns
    rm -f /etc/bash_completion.d/ddns

    systemctl daemon-reload

    warn "配置文件保留在: $CONFIG_DIR/ddns.conf"
    warn "日志文件保留在: $LOG_DIR"

    info "卸载完成"
}

# 显示帮助
show_help() {
    cat << EOF
TX_DDNS 安装脚本 v${VERSION}

用法: $0 [命令]

命令:
  install     交互式安装（默认）
  uninstall   卸载服务
  help        显示帮助信息

示例:
  $0              # 交互式安装
  $0 install      # 同上
  $0 uninstall    # 卸载

更多信息: https://github.com/skysr/TX_DDNS
EOF
}

# 主函数
main() {
    local cmd="${1:-install}"

    case "$cmd" in
        install)
            check_root
            check_dependencies
            interactive_config
            generate_config
            install_script
            install_completion
            install_service
            start_service
            ;;
        uninstall)
            check_root
            uninstall
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "未知命令: $cmd"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
