#!/bin/bash

# 配置信息（建议后续移到单独的配置文件中）
LOGIN_TOKEN='xxxxxxxx,xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
DOMAIN_ID='xxxxxxxxxxx'
RECORD_ID='xxxxxxxxxxxx'  # 修正了拼写错误 RECERD_ID
SUB_DOMAIN='xxxxxx'
RECORD_TYPE='AAAA'

# 文件路径
LOG_DIR='/var/log/ddns'
DB_FILE="$LOG_DIR/db"
FLAG_FILE="$LOG_DIR/flag"

# 创建日志目录（如果不存在）
mkdir -p "$LOG_DIR"

# 初始化文件（如果不存在）
[ -f "$DB_FILE" ] || echo "" > "$DB_FILE"
[ -f "$FLAG_FILE" ] || echo "0" > "$FLAG_FILE"

# 更可靠地获取当前IPv6地址
get_current_ipv6() {
    # 自动查找有效的全局IPv6地址
    ip -6 addr show scope global | grep -oP 'inet6 \K[0-9a-fA-F:]+' | head -1
}

# 验证IPv6地址格式
is_valid_ipv6() {
    [[ $1 =~ ^([0-9a-fA-F]{0,4}:){2,7}([0-9a-fA-F]{0,4})?$ ]] && [[ -n $1 ]]
}

# 安全的文件写入（带错误处理）
safe_write() {
    echo "$1" > "$2" 2>/dev/null || {
        echo "错误: 无法写入文件 $2" >&2
        exit 1
    }
}

# 读取之前的值
oldIPv6=$(cat "$DB_FILE" 2>/dev/null)
update_flag=$(cat "$FLAG_FILE" 2>/dev/null)

# 获取当前IPv6
currentIPv6=$(get_current_ipv6)

# 验证IPv6地址有效性
if ! is_valid_ipv6 "$currentIPv6"; then
    echo "错误: 无法获取有效的IPv6地址" >&2
    exit 1
fi

# 显示状态信息
echo "--- DDNS更新状态 ---"
echo "更新计数: ${update_flag:-0}/60"
echo "当前DNS: $(host "$SUB_DOMAIN.gdberry.cn" 2>/dev/null | grep -oE 'address [0-9a-fA-F:]+' || echo 'N/A')"
echo "旧IPv6: $oldIPv6"
echo "新IPv6: $currentIPv6"

# 判断是否需要更新
if [ "$currentIPv6" = "$oldIPv6" ] && [ "${update_flag:-0}" -lt 60 ]; then
    echo "IP未变化，跳过更新"
    safe_write $((update_flag + 1)) "$FLAG_FILE"
    exit 0
fi

# 重置计数器并执行更新
echo "正在更新DNS记录..."
safe_write "0" "$FLAG_FILE"
safe_write "$currentIPv6" "$DB_FILE"

# 调用API更新
response=$(curl -s -X POST https://dnsapi.cn/Record.Modify \
    -d "login_token=$LOGIN_TOKEN" \
    -d "format=json" \
    -d "domain_id=$DOMAIN_ID" \
    -d "record_id=$RECORD_ID" \
    -d "record_line_id=0" \
    -d "sub_domain=$SUB_DOMAIN" \
    -d "value=$currentIPv6" \
    -d "record_type=$RECORD_TYPE")

# 检查API返回结果
if echo "$response" | grep -q '"status":{"code":"1"'; then
    echo "更新成功"
else
    echo "更新失败: $response" >&2
    exit 1
fi
