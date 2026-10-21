#!/bin/bash
#===============================================================================
# TX_DDNS 回归测试
#
# 用法: ./tests/run_tests.sh
#
# 覆盖 v2.4.0 修复的缺陷:
#   1. 锁目录泄漏（cleanup 用 rm -f 删目录导致锁永不释放）
#   2. 僵尸锁无法自愈（PID 文件先被删）
#   3. API 失败后 db/flag 被提前写入，导致后续永久跳过更新
#   4. set -e 配合 ((errors++)) 导致 test 命令首次报错即中断
#   5. 'run' 不是合法参数
#   6. Telegram 分支依赖 jq 且 chat_id 为空
#   7. is_valid_ipv4 接受前导零绕过范围校验
#===============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DDNS="$SCRIPT_DIR/../ddnsv2.sh"
TMPROOT="$(mktemp -d)"
PASS=0
FAIL=0

cleanup_test() { rm -rf "$TMPROOT"; }
trap cleanup_test EXIT

#-------------------------------------------------------------------------------
# 测试框架
#-------------------------------------------------------------------------------
ok()   { PASS=$((PASS + 1)); printf '  \033[0;32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[0;31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; }
head2() { printf '\n\033[1;34m── %s\033[0m\n' "$1"; }

# 生成一份测试配置
mkconf() {
    local dir="$TMPROOT/$1"
    mkdir -p "$dir/log"
    cat > "$dir/ddns.conf" <<EOF
LOGIN_TOKEN='12345,abcdef123456'
DOMAIN_ID='999'
RECORD_ID='888'
SUB_DOMAIN='www'
RECORD_TYPE='AAAA'
LOG_DIR='$dir/log'
NETWORK_INTERFACE=''
EOF
    echo "$dir/ddns.conf"
}

#-------------------------------------------------------------------------------
# 测试 1: 锁必须在运行后释放
#-------------------------------------------------------------------------------
head2 "测试 1: 锁目录在运行后正确释放"
CONF=$(mkconf t1)
# 用一个必然失败的 API 调用触发完整流程
LOGIN_TOKEN='1,invalidtoken000' bash "$DDNS" -q -c "$CONF" >/dev/null 2>&1
if [ -d /var/lock/ddns.lock ]; then
    bad "锁目录 /var/lock/ddns.lock 运行后残留" "第二次运行会卡满 30 秒超时"
    rm -rf /var/lock/ddns.lock /var/lock/ddns.pid
else
    ok "锁目录运行后已释放"
fi

#-------------------------------------------------------------------------------
# 测试 2: 僵尸锁（残留目录 + 无 PID 文件）能被自动清理
#-------------------------------------------------------------------------------
head2 "测试 2: 僵尸锁自动清理"
CONF=$(mkconf t2)
mkdir -p /var/lock/ddns.lock            # 模拟异常退出残留
rm -f /var/lock/ddns.pid
START=$(date +%s)
LOGIN_TOKEN='1,invalidtoken000' timeout 10 bash "$DDNS" -q -c "$CONF" >/dev/null 2>&1
ELAPSED=$(( $(date +%s) - START ))
rm -rf /var/lock/ddns.lock /var/lock/ddns.pid
if [ "$ELAPSED" -lt 8 ]; then
    ok "僵尸锁被识别并清理（耗时 ${ELAPSED}s，未触发 30s 超时）"
else
    bad "僵尸锁未被清理，耗时 ${ELAPSED}s"
fi

#-------------------------------------------------------------------------------
# 测试 3: API 失败后状态不得被写坏
#-------------------------------------------------------------------------------
head2 "测试 3: API 失败后 db/flag 保持原样"
CONF=$(mkconf t3)
LOGDIR="$TMPROOT/t3/log"
echo "2409:8a00::dead" > "$LOGDIR/db"     # 旧 IP
echo "7"                   > "$LOGDIR/flag" # 已有计数
LOGIN_TOKEN='1,invalidtoken000' bash "$DDNS" -q -c "$CONF" >/dev/null 2>&1
DB_AFTER=$(cat "$LOGDIR/db")
FLAG_AFTER=$(cat "$LOGDIR/flag")
if [ "$DB_AFTER" = "2409:8a00::dead" ] && [ "$FLAG_AFTER" = "7" ]; then
    ok "失败后 db/flag 未被污染（db=$DB_AFTER flag=$FLAG_AFTER），下轮会重试"
else
    bad "失败后状态被写坏" "db=$DB_AFTER (期望 2409:8a00::dead)  flag=$FLAG_AFTER (期望 7)"
fi

#-------------------------------------------------------------------------------
# 测试 4: set -e 下 ((x++)) 不应中断脚本
#-------------------------------------------------------------------------------
head2 "测试 4: 错误计数不受 set -e 影响"
CONF=$(mkconf t4)
OUT=$(LOGIN_TOKEN='1,invalidtoken000' bash "$DDNS" test -c "$CONF" 2>&1)
RC=$?
if echo "$OUT" | grep -q "发现 .* 个错误"; then
    ok "test 命令跑完全部用例并输出错误汇总"
elif echo "$OUT" | grep -q "测试 IP 获取"; then
    bad "test 命令在首个错误处中断" "后续用例未执行"
else
    bad "test 命令输出异常" "$(echo "$OUT" | tail -3 | tr '\n' ' ')"
fi
[ "$RC" -ne 0 ] && ok "test 命令在有错误时返回非零退出码 ($RC)" \
                || bad "test 命令在有错误时应返回非零退出码"

#-------------------------------------------------------------------------------
# 测试 5: run 是合法子命令
#-------------------------------------------------------------------------------
head2 "测试 5: run 子命令可用"
CONF=$(mkconf t5)
OUT=$(LOGIN_TOKEN='1,invalidtoken000' bash "$DDNS" run -c "$CONF" 2>&1)
if echo "$OUT" | grep -q "未知参数"; then
    bad "'run' 被当作未知参数拒绝"
else
    ok "'run' 被正确接受"
fi

#-------------------------------------------------------------------------------
# 测试 6: 无 jq 依赖 + Telegram chat_id
#-------------------------------------------------------------------------------
head2 "测试 6: 纯 bash 实现，无 jq 依赖"
if grep -q "jq -sRr @uri" "$DDNS"; then
    bad "Telegram 分支仍依赖 jq"
else
    ok "Telegram 分支不再调用 jq"
fi
# 提取 urlencode 函数做独立验证（写入临时文件再 source，避免变量被提前展开）
sed -n '/^urlencode()/,/^}/p' "$DDNS" > "$TMPROOT/urlencode.sh"
ENC=$(bash -c "source '$TMPROOT/urlencode.sh'; urlencode 'a b&c=d中文'")
if [ "$ENC" = "a%20b%26c%3Dd%E4%B8%AD%E6%96%87" ]; then
    ok "urlencode 编码正确: $ENC"
else
    bad "urlencode 编码错误" "得到: $ENC"
fi

#-------------------------------------------------------------------------------
# 测试 7: IPv4 前导零必须被拒绝
#-------------------------------------------------------------------------------
head2 "测试 7: IPv4 校验拒绝前导零"
sed -n '/^is_valid_ipv4()/,/^}/p' "$DDNS" > "$TMPROOT/v4.sh"
check() {
    bash -c "source '$TMPROOT/v4.sh'; is_valid_ipv4 '$1'"
}
if check "010.1.1.1"; then
    bad "接受 010.1.1.1（前导零绕过校验）"
else
    ok "拒绝 010.1.1.1"
fi
if check "256.1.1.1"; then
    bad "接受 256.1.1.1（超出范围）"
else
    ok "拒绝 256.1.1.1"
fi
if check "192.168.1.1"; then
    ok "接受合法地址 192.168.1.1"
else
    bad "错误拒绝了合法地址 192.168.1.1"
fi

#-------------------------------------------------------------------------------
# 测试 8: IPv6 校验仍然有效
#-------------------------------------------------------------------------------
head2 "测试 8: IPv6 校验"
sed -n '/^is_valid_ipv6()/,/^}/p' "$DDNS" > "$TMPROOT/v6.sh"
check6() {
    bash -c "source '$TMPROOT/v6.sh'; is_valid_ipv6 '$1'"
}
if check6 "2409:8a00::1"; then
    ok "接受 2409:8a00::1"
else
    bad "错误拒绝了 2409:8a00::1"
fi
if check6 "not-an-ip"; then
    bad "接受了非法地址 not-an-ip"
else
    ok "拒绝 not-an-ip"
fi

#-------------------------------------------------------------------------------
# 测试 9: JSON 解析（嵌套结构 + \uXXXX 转义）
#-------------------------------------------------------------------------------
head2 "测试 9: JSON 解析"
sed -n '/^parse_json_field()/,/^}/p' "$DDNS" > "$TMPROOT/pf.sh"
pf() {
    bash -c "source '$TMPROOT/pf.sh'; parse_json_field '$1' '$2'"
}
GOT=$(pf '{"status":{"code":1,"message":"ok"},"record":{"name":"www"}}' code)
[ "$GOT" = "1" ] && ok "从嵌套 status 对象取到 code=1" \
                 || bad "嵌套 code 解析错误" "得到: $GOT"
GOT=$(pf '{"status":{"code":1,"message":"ok"},"record":{"name":"www"}}' name)
[ "$GOT" = "www" ] && ok "回退到全文档搜索取到 name=www" \
                   || bad "name 解析错误" "得到: $GOT"
GOT=$(pf '{"status":{"code":1,"message":"\u64cd\u4f5c\u6210\u529f"}}' message)
[ "$GOT" = "操作成功" ] && ok "正确解码 \\uXXXX 中文转义" \
                        || bad "中文转义解码错误" "得到: $GOT"

#-------------------------------------------------------------------------------
# 测试 10: 语法检查
#-------------------------------------------------------------------------------
head2 "测试 10: 语法检查"
if bash -n "$DDNS" 2>/dev/null; then
    ok "ddnsv2.sh 语法正确"
else
    bad "ddnsv2.sh 存在语法错误" "$(bash -n "$DDNS" 2>&1 | head -3)"
fi
if bash -n "$SCRIPT_DIR/../install.sh" 2>/dev/null; then
    ok "install.sh 语法正确"
else
    bad "install.sh 存在语法错误"
fi

#-------------------------------------------------------------------------------
# 汇总
#-------------------------------------------------------------------------------
printf '\n\033[1;34m════════════════════════════\033[0m\n'
printf '  通过: \033[0;32m%d\033[0m   失败: \033[0;31m%d\033[0m\n' "$PASS" "$FAIL"
printf '\033[1;34m════════════════════════════\033[0m\n'
[ "$FAIL" -eq 0 ] || exit 1
