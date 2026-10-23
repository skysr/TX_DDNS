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
VERSION="2.7.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 安装路径
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/etc/ddns"
RECORDS_PATH="/etc/ddns/records.list"
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

    # 网卡（全局默认，单条记录可单独覆盖）
    # 带编号列出可用网卡及其当前公网地址，辅助选择
    echo ""
    echo "可用网卡:"
    local -a IFACE_NAMES=()
    local recommend=""
    local n=1 ifname v6 v4 mark
    while read -r ifname; do
        [ -z "$ifname" ] && continue
        v6=$(ip -6 addr show dev "$ifname" scope global 2>/dev/null | grep -v deprecated | \
             grep -oP 'inet6 \K[0-9a-fA-F:]+' | head -1)
        v4=$(ip -4 addr show dev "$ifname" scope global 2>/dev/null | \
             grep -oP 'inet \K[0-9.]+' | head -1)
        IFACE_NAMES+=("$ifname")
        mark=""
        if [ -n "$v6" ]; then
            mark=" [推荐]"
            [ -z "$recommend" ] && recommend="$ifname"
        fi
        echo "  $n) $ifname$mark  IPv6: ${v6:-无}  IPv4: ${v4:-无}"
        n=$((n + 1))
    done < <(ip -br link show | awk '{print $1}' | grep -v '^lo$')

    echo ""
    if [ -n "$recommend" ]; then
        prompt "请选择默认网卡 (编号或名称，留空自动检测，推荐: $recommend): "
    else
        prompt "请选择默认网卡 (编号或名称，留空自动检测): "
    fi
    read -r iface_sel
    NETWORK_INTERFACE=""
    if [ -n "$iface_sel" ]; then
        if [[ "$iface_sel" =~ ^[0-9]+$ ]] && [ "$iface_sel" -ge 1 ] && [ "$iface_sel" -le "${#IFACE_NAMES[@]}" ]; then
            NETWORK_INTERFACE="${IFACE_NAMES[$((iface_sel - 1))]}"
        elif [[ "$iface_sel" =~ ^[a-zA-Z0-9._-]+$ ]] && ip link show "$iface_sel" &>/dev/null; then
            NETWORK_INTERFACE="$iface_sel"
        else
            warn "未识别的网卡: $iface_sel，改为自动检测"
        fi
    fi
    echo "  网卡默认值: ${NETWORK_INTERFACE:-自动检测}"

    # 全局固定 IPv6（可选）：填写后直接以此地址更新，不做网卡检测
    local ip_hint=""
    if [ -n "$NETWORK_INTERFACE" ]; then
        ip_hint=$(ip -6 addr show dev "$NETWORK_INTERFACE" scope global 2>/dev/null | grep -v deprecated | \
                  grep -oP 'inet6 \K[0-9a-fA-F:]+' | head -1)
    fi
    echo ""
    if [ -n "$ip_hint" ]; then
        prompt "请输入默认 IPv6 地址 (留空使用该网卡当前: $ip_hint): "
    else
        prompt "请输入默认 IPv6 地址 (留空则按网卡自动检测): "
    fi
    read -r IP_ADDRESS
    if [ -n "$IP_ADDRESS" ]; then
        if ! { [[ "$IP_ADDRESS" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$IP_ADDRESS" == *:* ]]; }; then
            error "IPv6 地址格式错误: $IP_ADDRESS（仅支持 IPv6）"
            exit 1
        fi
        echo "  IP 默认值: $IP_ADDRESS（固定地址，不做网卡检测）"
    fi

    # ---- 收集记录列表 ----
    RECORDS_LINES=()
    RECORD_COUNT=0

    echo ""
    echo "=========================================="
    echo "       记录配置（可添加多条）"
    echo "=========================================="
    echo ""
    echo "每条记录需要: 子域名、域名ID、记录ID"
    echo "  子域名: www / nas / @ (主域名) / * (泛解析)"
    echo "  留空子域名则直接回车结束录入"
    echo ""

    while true; do
        prompt "子域名 (留空结束): "
        read -r sub
        [ -z "$sub" ] && break

        prompt "  域名 ID (domain_id): "
        read -r domain

        prompt "  记录 ID (record_id): "
        read -r rid

        if [ -z "$domain" ] || [ -z "$rid" ]; then
            error "域名 ID 和记录 ID 不能为空，该条记录已跳过"
            continue
        fi

        # 记录类型（默认 AAAA）
        echo "  记录类型: 1) AAAA (IPv6, 推荐)  2) A (IPv4)"
        prompt "  选择 [1/2]: "
        read -r rchoice
        case "$rchoice" in
            2) rtype="A";;
            *) rtype="AAAA";;
        esac

        # 单条记录的网卡与 TTL（留空则用全局值）
        prompt "  网卡 (留空用默认 ${NETWORK_INTERFACE:-自动}): "
        read -r riface
        [ -z "$riface" ] && riface="$NETWORK_INTERFACE"

        prompt "  TTL 秒数 (留空用默认 600): "
        read -r rttl
        [ -z "$rttl" ] && rttl=600
        [[ "$rttl" =~ ^[0-9]+$ ]] && [ "$rttl" -ge 1 ] || rttl=600

        # 单条记录的固定 IPv6（留空用全局 IP_ADDRESS，再留空则自动检测；A 记录不支持固定）
        local rip=""
        if [ "$rtype" = "AAAA" ]; then
            local rhint=""
            if [ -n "$riface" ]; then
                rhint=$(ip -6 addr show dev "$riface" scope global 2>/dev/null | grep -v deprecated | \
                         grep -oP 'inet6 \K[0-9a-fA-F:]+' | head -1)
            fi
            if [ -n "$rhint" ]; then
                prompt "  IP (留空用该网卡当前: $rhint): "
            else
                prompt "  IP (留空用全局默认 ${IP_ADDRESS:-自动检测}): "
            fi
            read -r rip
            [ -z "$rip" ] && rip="${IP_ADDRESS:-}"
            if [ -n "$rip" ]; then
                { [[ "$rip" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$rip" == *:* ]] || { error "IPv6 地址无效: $rip，该条记录已跳过"; continue; }; }
            fi
        fi

        RECORDS_LINES+=("${sub}|${domain}|${rid}|${rtype}|${riface}|${rttl}|${rip}")
        RECORD_COUNT=$((RECORD_COUNT + 1))
        echo "  ✓ 已添加: ${sub} (${rtype})"
        echo ""
    done

    if [ "$RECORD_COUNT" -eq 0 ]; then
        error "至少需要配置一条记录"
        exit 1
    fi

    # 用第一条记录填充兼容字段（单记录模式下生效）
    # 记录行格式: 子域名|域名ID|记录ID|记录类型|网卡|TTL|IP
    IFS='|' read -r SUB_DOMAIN DOMAIN_ID RECORD_ID RECORD_TYPE _ _ _ <<< "${RECORDS_LINES[0]}"

    # 更新间隔（分钟）
    prompt "更新间隔分钟数 [1]: "
    read -r interval
    INTERVAL="${interval:-1}"
    [ "$INTERVAL" -ge 1 ] 2>/dev/null || INTERVAL=1

    # 强制更新周期（分钟）：无论 IP 是否变化，都至少每 N 分钟重推一次
    prompt "强制更新周期分钟数 [60]: "
    read -r force_interval
    FORCE_INTERVAL="${force_interval:-60}"
    [ "$FORCE_INTERVAL" -ge 1 ] 2>/dev/null || FORCE_INTERVAL=60

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
    echo "  记录数量:       $RECORD_COUNT"
    for line in "${RECORDS_LINES[@]}"; do
        IFS='|' read -r s1 s2 s3 s4 s5 s6 s7 <<< "$line"
        echo "    - $s1 ($s4) 域名=$s2 记录=$s3 TTL=$s6 网卡=${s5:-自动} IP=${s7:-自动检测}"
    done
    echo "  网卡默认值:     ${NETWORK_INTERFACE:-自动检测}"
    echo "  IP 默认值:      ${IP_ADDRESS:-自动检测}"
    echo "  更新间隔:       每 ${INTERVAL} 分钟"
    echo "  Webhook:        ${WEBHOOK_URL:-未配置}"
    echo "=========================================="
    echo ""

    prompt "确认安装? [Y/n]: "
    read -r confirm
    # 注意：不能写成 [[ ... ]] && { ...; }，该表达式在条件为假时返回 1，
    # 配合 set -e 会直接终止脚本（且不打印任何错误，看起来像静默退出）。
    if [[ "$confirm" =~ ^[Nn] ]]; then
        warn "安装已取消"
        exit 0
    fi
}

# 生成记录列表文件
generate_records_file() {
    cat > "$RECORDS_PATH" << EOF
# TX_DDNS 记录列表
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')
#
# 格式: 子域名|域名ID|记录ID|记录类型|网卡|TTL|IP
# 子域名可为 www / nas / @ (主域名) / * (泛解析)
# IP 字段留空 = 按网卡自动检测；固定某个公网 IPv6 地址时填入（仅支持 IPv6，A 记录不支持）

EOF
    local line
    for line in "${RECORDS_LINES[@]}"; do
        echo "$line" >> "$RECORDS_PATH"
    done
    chmod 600 "$RECORDS_PATH"
    info "记录列表已生成: $RECORDS_PATH ($RECORD_COUNT 条)"
}

# 生成配置文件
generate_config() {
    mkdir -p "$CONFIG_DIR"

    # 强制更新周期换算并夹紧到最小 1
    FORCE_UPDATE_CYCLE=$(( (FORCE_INTERVAL + INTERVAL - 1) / INTERVAL ))
    [ "$FORCE_UPDATE_CYCLE" -ge 1 ] || FORCE_UPDATE_CYCLE=1

    # 先生成记录列表
    generate_records_file

    cat > "$CONFIG_DIR/ddns.conf" << EOF
# TX_DDNS 配置文件
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

# DNSPod API Token
LOGIN_TOKEN='$LOGIN_TOKEN'

# 记录列表（多记录模式）
RECORDS_FILE='$RECORDS_PATH'

# 以下为单记录模式的兼容字段，多记录模式下不生效
DOMAIN_ID='$DOMAIN_ID'
RECORD_ID='$RECORD_ID'
SUB_DOMAIN='$SUB_DOMAIN'

# 记录类型: A 或 AAAA
RECORD_TYPE='$RECORD_TYPE'

# 网卡名称（留空自动检测）
NETWORK_INTERFACE='$NETWORK_INTERFACE'

# 固定 IPv6 地址（全局默认，留空则按网卡自动检测；记录列表第 7 字段可逐条覆盖，仅支持 IPv6）
IP_ADDRESS='$IP_ADDRESS'

# DNS TTL (秒)
RECORD_TTL='$RECORD_TTL'

# 日志目录
LOG_DIR='$LOG_DIR'

# 强制更新周期（以「检查次数」计）
# 脚本每运行一次计数 +1，计数达到 FORCE_UPDATE_CYCLE 时强制重推一次。
# 检查间隔 = INTERVAL 分钟，因此 N 分钟强制周期对应 N/INTERVAL 次检查。
FORCE_UPDATE_CYCLE=$(( (FORCE_INTERVAL + INTERVAL - 1) / INTERVAL ))

# Webhook 通知 (可选)
WEBHOOK_URL='$WEBHOOK_URL'
WEBHOOK_METHOD='POST'

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

    # 安装配置模板
    [ -f "$SCRIPT_DIR/ddnsv2.conf.example" ] && \
        cp "$SCRIPT_DIR/ddnsv2.conf.example" "$CONFIG_DIR/ddnsv2.conf.example" 2>/dev/null || true
    [ -f "$SCRIPT_DIR/records.list.example" ] && \
        cp "$SCRIPT_DIR/records.list.example" "$CONFIG_DIR/records.list.example" 2>/dev/null || true

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
ReadWritePaths=$LOG_DIR /var/lock

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
    warn "记录列表保留在: $RECORDS_PATH"
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
