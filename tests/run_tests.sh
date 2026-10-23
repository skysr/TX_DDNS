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
# 测试 10: 多记录支持
#-------------------------------------------------------------------------------
head2 "测试 10: 多记录解析"
MDIR="$TMPROOT/multi"
mkdir -p "$MDIR/log"
cat > "$MDIR/ddns.conf" <<EOF
LOGIN_TOKEN='12345,abcdef123456'
RECORDS_FILE='$MDIR/records.list'
LOG_DIR='$MDIR/log'
RECORD_TYPE='AAAA'
RECORD_TTL=600
EOF
cat > "$MDIR/records.list" <<'EOF'
# 子域名|域名ID|记录ID|类型|网卡|TTL
www|100|201|AAAA|eth0|600
nas|100|202|AAAA||
home|200|203|A||300
@|100|204|AAAA|eth0|
*|100|205|AAAA|eth0|900
EOF

OUT=$(bash "$DDNS" list -c "$MDIR/ddns.conf" 2>&1)
if echo "$OUT" | grep -q "共计 5 条记录"; then
    ok "list 命令识别出 5 条记录"
else
    bad "list 命令记录数不正确" "$(echo "$OUT" | tail -3 | tr '\n' ' ')"
fi
if echo "$OUT" | grep -qE "home.*A.*200.*203.*300"; then
    ok "字段回退正确（home 显式 TTL=300，类型 A）"
else
    bad "字段回退不正确"
fi

#-------------------------------------------------------------------------------
# 测试 11: 记录 key 唯一性（@ 与 * 不能冲突）
#-------------------------------------------------------------------------------
head2 "测试 11: 记录 key 唯一性"
sed -n '/^record_key()/,/^}/p' "$DDNS" > "$TMPROOT/rk.sh"
K_AT=$(bash -c "source '$TMPROOT/rk.sh'; record_key '@' AAAA 100")
K_STAR=$(bash -c "source '$TMPROOT/rk.sh'; record_key '*' AAAA 100")
K_WWW=$(bash -c "source '$TMPROOT/rk.sh'; record_key 'www' AAAA 100")
if [ "$K_AT" != "$K_STAR" ] && [ "$K_AT" != "$K_WWW" ] && [ "$K_STAR" != "$K_WWW" ]; then
    ok "不同子域名生成不同 key（@ / * / www 互不冲突）"
else
    bad "记录 key 冲突" "@=$K_AT *=$K_STAR www=$K_WWW"
fi
# key 必须是安全文件名
case "$K_AT" in
    *[!a-zA-Z0-9._-]*) bad "key 含不安全字符: $K_AT" ;;
    *) ok "key 只含安全字符: $K_AT" ;;
esac

#-------------------------------------------------------------------------------
# 测试 12: 多记录状态文件隔离
#-------------------------------------------------------------------------------
head2 "测试 12: 状态文件隔离"
LOGIN_TOKEN='1,invalidtoken000' bash "$DDNS" -q -c "$MDIR/ddns.conf" >/dev/null 2>&1
DB_COUNT=$(ls -1 "$MDIR/log"/db.* 2>/dev/null | wc -l)
if [ "$DB_COUNT" -eq 5 ]; then
    ok "5 条记录生成 5 个独立 db 文件"
else
    bad "状态文件数量不对" "期望 5，实际 $DB_COUNT"
fi
# 重复 key 会导致文件数少于记录数
DUP=$(ls -1 "$MDIR/log"/db.* 2>/dev/null | sort | uniq -d | wc -l)
if [ "$DUP" -eq 0 ]; then
    ok "无重复状态文件"
else
    bad "存在重复状态文件（key 冲突）"
fi

#-------------------------------------------------------------------------------
# 测试 13: 单记录模式向后兼容
#-------------------------------------------------------------------------------
head2 "测试 13: 单记录模式向后兼容"
SDIR="$TMPROOT/single"
mkdir -p "$SDIR/log"
cat > "$SDIR/ddns.conf" <<EOF
LOGIN_TOKEN='12345,abcdef123456'
DOMAIN_ID='999'
RECORD_ID='888'
SUB_DOMAIN='www'
RECORD_TYPE='AAAA'
LOG_DIR='$SDIR/log'
EOF
LOGIN_TOKEN='1,invalidtoken000' bash "$DDNS" -q -c "$SDIR/ddns.conf" >/dev/null 2>&1
if [ -f "$SDIR/log/db" ] && [ -f "$SDIR/log/flag" ]; then
    ok "单记录模式沿用原有 db / flag 文件名"
else
    bad "单记录模式状态文件名变化（破坏向后兼容）"
fi
OUT=$(bash "$DDNS" list -c "$SDIR/ddns.conf" 2>&1)
if echo "$OUT" | grep -q "共计 1 条记录"; then
    ok "单记录模式回退可用"
else
    bad "单记录模式回退失败" "$(echo "$OUT" | tail -3 | tr '\n' ' ')"
fi

#-------------------------------------------------------------------------------
# 测试 14: 记录文件格式错误处理
#-------------------------------------------------------------------------------
head2 "测试 14: 记录文件错误处理"
# 第 7 字段现在是 IP 字段：EXTRA 不是合法 IPv6 → 固定地址校验报错
cat > "$MDIR/records.list" <<'EOF'
www|100|201|AAAA|eth0|600|EXTRA
EOF
OUT=$(bash "$DDNS" list -c "$MDIR/ddns.conf" 2>&1)
if echo "$OUT" | grep -q "固定的 IPv6 地址无效"; then
    ok "第 7 字段（IP）非法时报错"
else
    bad "第 7 字段（IP）非法未报错" "$(echo "$OUT" | tail -2 | tr '\n' ' ')"
fi
# 第 8 段开始才算字段过多
cat > "$MDIR/records.list" <<'EOF'
www|100|201|AAAA|eth0|600|2409:8a00::1|EXTRA
EOF
OUT=$(bash "$DDNS" list -c "$MDIR/ddns.conf" 2>&1)
if echo "$OUT" | grep -q "字段过多"; then
    ok "字段过多（8 段）时报错"
else
    bad "字段过多（8 段）未报错" "$(echo "$OUT" | tail -2 | tr '\n' ' ')"
fi
cat > "$MDIR/records.list" <<'EOF'
www|100|201|INVALID
EOF
OUT=$(bash "$DDNS" list -c "$MDIR/ddns.conf" 2>&1)
if echo "$OUT" | grep -q "记录类型必须是"; then
    ok "非法记录类型时报错"
else
    bad "非法记录类型未报错"
fi
cat > "$MDIR/records.list" <<'EOF'
www|100
EOF
OUT=$(bash "$DDNS" list -c "$MDIR/ddns.conf" 2>&1)
if echo "$OUT" | grep -q "缺少必要字段"; then
    ok "缺少必填字段时报错"
else
    bad "缺少必填字段未报错"
fi

#-------------------------------------------------------------------------------
# 测试 15: 安装器生成配置的正确性
#-------------------------------------------------------------------------------
head2 "测试 15: 安装器配置生成"
# 静态检查：install.sh 的兼容字段赋值必须按正确的下标解析记录行
# 记录行格式: 子域名|域名ID|记录ID|记录类型|网卡|TTL|IP
# 错误写法会把 DOMAIN_ID 赋成子域名、RECORD_ID 赋成域名ID
if grep -q 'read -r SUB_DOMAIN DOMAIN_ID RECORD_ID RECORD_TYPE _ _ _ <<< "\${RECORDS_LINES\[0\]}"' "$SCRIPT_DIR/../install.sh"; then
    ok "兼容字段按正确下标解析记录行（含 IP 字段）"
else
    bad "兼容字段解析下标错误（DOMAIN_ID/RECORD_ID/SUB_DOMAIN 会错位）"
fi

# heredoc 里的 $[...] 会被当成命令替换展开，生成垃圾行
if grep -qE '^\[ .*-ge 1 \] \|\|' "$SCRIPT_DIR/../install.sh"; then
    bad "install.sh 中存在会被 heredoc 展开的 $[...] 表达式"
else
    ok "install.sh 无会被 heredoc 误展开的表达式"
fi

# 确认步骤不能用 [[ ]] && {...}：条件为假时整体退出码为 1，配合 set -e 会静默终止
if grep -qE '\[\[ "\$confirm" =~ \^\[Nn\] \]\] &&' "$SCRIPT_DIR/../install.sh"; then
    bad "确认步骤使用 [[ ]] && {...}，在 set -e 下会静默退出"
else
    ok "确认步骤使用 if 判断，无 set -e 静默退出风险"
fi

#-------------------------------------------------------------------------------
# 测试 16: 记录发现（Record.List 解析）
#-------------------------------------------------------------------------------
head2 "测试 16: 记录发现"
sed -n '/^parse_json_records()/,/^}/p' "$DDNS" > "$TMPROOT/pjr.sh"
cat > "$TMPROOT/sample.json" <<'JSONEOF'
{"status":{"code":1,"message":"ok"},"domain":{"id":"12600793","name":"example.com"},
 "records":[
 {"id":"13608148","name":"www","line":"默认","type":"A","ttl":"600","value":"1.1.1.1"},
 {"id":"13608149","name":"www","line":"电信","type":"AAAA","ttl":"600","value":"2404::1"},
 {"id":"13608150","name":"nas","line":"默认","type":"A","ttl":"300","value":"1.1.1.2"},
 {"id":"13608151","name":"@","line":"默认","type":"MX","ttl":"600","value":"mail.x.com"}
]}
JSONEOF
OUT=$(bash -c "source '$TMPROOT/pjr.sh'; parse_json_records \"\$(cat '$TMPROOT/sample.json')\"" 2>&1)
# 上面的双引号嵌套在部分 shell 下不可靠，改用 stdin 方式再验一次
cat > "$TMPROOT/pjr_run.sh" <<'PJREOF'
source "$1"
parse_json_records "$(cat "$2")"
PJREOF
OUT=$(bash "$TMPROOT/pjr_run.sh" "$TMPROOT/pjr.sh" "$TMPROOT/sample.json" 2>&1)
COUNT=$(printf '%s' "$OUT" | grep -c .)
if [ "$COUNT" -eq 4 ]; then
    ok "解析出 4 条记录"
else
    bad "记录解析数量不对" "期望 4，实际 $COUNT"
fi
if printf '%s' "$OUT" | grep -q "^13608148|www|A|600$"; then
    ok "记录字段解析正确（id|name|type|ttl）"
else
    bad "记录字段解析错误" "$OUT"
fi
if printf '%s' "$OUT" | grep -q "^13608151|@|MX|600$"; then
    ok "主域名 @ 与 MX 类型解析正确"
else
    bad "@ / MX 解析错误"
fi

# 格式化过的 JSON（带换行）必须也能解析
# 真实 DNSPod 返回紧凑 JSON，但格式化过的响应会让 .* 不跨行而匹配失败
cat > "$TMPROOT/sample_pretty.json" <<'JSONEOF'
{
  "status": {
    "code": 1,
    "message": "ok"
  },
  "domain": {
    "id": "12600793",
    "name": "example.com"
  },
  "records": [
    {
      "id": "13608148",
      "name": "www",
      "type": "A",
      "ttl": "600"
    }
  ]
}
JSONEOF
OUTP=$(bash "$TMPROOT/pjr_run.sh" "$TMPROOT/pjr.sh" "$TMPROOT/sample_pretty.json" 2>&1)
if printf '%s' "$OUTP" | grep -q "^13608148|www|A|600$"; then
    ok "格式化过的 JSON（含换行）也能正确解析"
else
    bad "格式化 JSON 解析失败" "$OUTP"
fi

# parse_json_field 也必须能处理格式化 JSON
sed -n '/^parse_json_field()/,/^}/p' "$DDNS" > "$TMPROOT/pf2.sh"
cat > "$TMPROOT/pf2_run.sh" <<'PF2EOF'
source "$1"
parse_json_field "$(cat "$2")" "code"
PF2EOF
CODER=$(bash "$TMPROOT/pf2_run.sh" "$TMPROOT/pf2.sh" "$TMPROOT/sample_pretty.json" 2>&1)
if [ "$CODER" = "1" ]; then
    ok "parse_json_field 处理格式化 JSON"
else
    bad "parse_json_field 无法处理格式化 JSON" "得到: $CODER"
fi

# 无 records 数组时应返回非零
OUT2=$(bash -c "source '$TMPROOT/pjr.sh'; parse_json_records '{\"status\":{\"code\":1}}'" 2>&1)
if [ -z "$OUT2" ]; then
    ok "无 records 数组时返回空"
else
    bad "无 records 数组时应返回空" "$OUT2"
fi

# records 命令必须存在且 --generate 被支持
if grep -q 'records)' "$DDNS" && grep -q 'RECORDS_GENERATE' "$DDNS"; then
    ok "records 命令与 --generate 选项已实现"
else
    bad "records 命令未正确实现"
fi
# -c 等全局选项不能被子命令吞掉：records 的参数循环遇到全局选项必须 break
if grep -qE '\-c\|\-v\|\-q\|\-V\|\-h\|\-\-verbose' "$DDNS"; then
    ok "子命令参数解析不吞掉全局选项"
else
    bad "子命令会吞掉全局选项（-c 无法在子命令后使用）"
fi

#-------------------------------------------------------------------------------
# 测试 17: 历史记录包含正确的记录类型
#-------------------------------------------------------------------------------
head2 "测试 17: 历史记录类型"
# 多记录模式下每条记录类型不同，history 的类型列必须来自当前记录
# 而非全局 RECORD_TYPE（多记录模式下为空）
if grep -q 'local rtype="${6:-${CURRENT_REC_TYPE:-$RECORD_TYPE}}"' "$DDNS"; then
    ok "record_history 从当前记录取类型"
else
    bad "record_history 未从当前记录取类型（多记录模式下类型列为空）"
fi
# 当前记录类型必须在 process_record 中赋值
if grep -q 'CURRENT_REC_TYPE="\$rtype"' "$DDNS"; then
    ok "process_record 设置当前记录类型"
else
    bad "process_record 未设置 CURRENT_REC_TYPE"
fi

#-------------------------------------------------------------------------------
# 测试 18: 语法检查
#-------------------------------------------------------------------------------
head2 "测试 18: 语法检查"
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
# 测试 19: IP 固定（记录字段 > 全局 IP_ADDRESS > 自动检测）
#-------------------------------------------------------------------------------
head2 "测试 19: IP 固定（仅支持 IPv6）"
cat > "$MDIR/ddns.conf" <<EOF
LOGIN_TOKEN='12345,abcdef123456'
RECORDS_FILE='$MDIR/records.list'
LOG_DIR='$MDIR/log'
RECORD_TYPE='AAAA'
RECORD_TTL=600
IP_ADDRESS='2409:8a00::9'
EOF
# 1) AAAA 固定值 / 全局默认回退
cat > "$MDIR/records.list" <<'EOF'
www|100|201|AAAA|eth0|600|2409:8a00::1
nas|100|202|AAAA||600
EOF
OUT=$(bash "$DDNS" list -c "$MDIR/ddns.conf" 2>&1)
if echo "$OUT" | grep -q "共计 2 条记录"; then
    ok "AAAA 固定值 / 全局默认混合加载成功"
else
    bad "AAAA 记录加载失败" "$(echo "$OUT" | tail -3 | tr '\n' ' ')"
fi
if echo "$OUT" | grep "^1 " | grep -q "2409:8a00::1"; then
    ok "记录字段固定值生效（www → 2409:8a00::1）"
else
    bad "记录字段固定值未生效" "$(echo "$OUT" | grep '^1 ')"
fi
if echo "$OUT" | grep "^2 " | grep -q "2409:8a00::9"; then
    ok "记录第 7 字段留空回退全局 IP_ADDRESS（nas → 2409:8a00::9）"
else
    bad "全局 IP_ADDRESS 回退未生效" "$(echo "$OUT" | grep '^2 ')"
fi
# A 记录填写 IP 字段（即使填的是合法 IPv4）也必须拒绝：IP 固定仅支持 IPv6
cat > "$MDIR/records.list" <<'EOF'
home|200|203|A||300|1.2.3.4
EOF
OUT=$(bash "$DDNS" list -c "$MDIR/ddns.conf" 2>&1)
if echo "$OUT" | grep -q "IP 字段只支持 IPv6 地址"; then
    ok "A 记录填写 IP 字段被拒绝（仅支持 IPv6）"
else
    bad "A 记录填写 IP 字段未被拒绝" "$(echo "$OUT" | tail -2 | tr '\n' ' ')"
fi
# 类型不匹配：全局固定 IPv6，A 记录未单独固定 → 回退全局后必须报错
cat > "$MDIR/records.list" <<'EOF'
home|200|203|A||300
EOF
OUT=$(bash "$DDNS" list -c "$MDIR/ddns.conf" 2>&1)
if echo "$OUT" | grep -q "IP 字段只支持 IPv6 地址"; then
    ok "A 记录回退到全局 IPv6 固定值时报错（不推错值）"
else
    bad "A 记录回退全局 IPv6 未报错" "$(echo "$OUT" | tail -2 | tr '\n' ' ')"
fi
# 全局 IP_ADDRESS 是合法 IPv4 但非 IPv6 → 必须拒绝（仅支持 IPv6）
sed -i "s/IP_ADDRESS='2409:8a00::9'/IP_ADDRESS='1.2.3.4'/" "$MDIR/ddns.conf"
OUT=$(bash "$DDNS" list -c "$MDIR/ddns.conf" 2>&1)
if echo "$OUT" | grep -q "IP_ADDRESS 只支持 IPv6 地址"; then
    ok "全局 IP_ADDRESS 为 IPv4 时被拒绝（仅支持 IPv6）"
else
    bad "全局 IP_ADDRESS IPv4 未被拒绝" "$(echo "$OUT" | tail -2 | tr '\n' ' ')"
fi
# 全局 IP_ADDRESS 格式非法 → 配置校验报错
sed -i "s/IP_ADDRESS='1.2.3.4'/IP_ADDRESS='not-an-ip'/" "$MDIR/ddns.conf"
OUT=$(bash "$DDNS" list -c "$MDIR/ddns.conf" 2>&1)
if echo "$OUT" | grep -q "IP_ADDRESS 只支持 IPv6 地址"; then
    ok "全局 IP_ADDRESS 格式非法时报错"
else
    bad "全局 IP_ADDRESS 格式非法未报错" "$(echo "$OUT" | tail -2 | tr '\n' ' ')"
fi

#-------------------------------------------------------------------------------
# 测试 20: 安装器（网卡选择 + IP 固定输入）静态检查
#-------------------------------------------------------------------------------
head2 "测试 20: 安装器"
if grep -q "IFACE_NAMES" "$SCRIPT_DIR/../install.sh" && grep -qE 'ip -6 addr show' "$SCRIPT_DIR/../install.sh"; then
    ok "安装器列出网卡当前公网地址（编号选择）"
else
    bad "安装器未提供带地址的网卡选择"
fi
if grep -q "IP_ADDRESS" "$SCRIPT_DIR/../install.sh"; then
    ok "安装器写入 IP_ADDRESS 配置"
else
    bad "安装器未写入 IP_ADDRESS"
fi
if grep -qF 'RECORDS_LINES+=("${sub}|${domain}|${rid}|${rtype}|${riface}|${rttl}|${rip}")' "$SCRIPT_DIR/../install.sh"; then
    ok "安装器生成的记录行包含第 7 IP 字段"
else
    bad "安装器记录行缺少 IP 字段"
fi

#-------------------------------------------------------------------------------
# 汇总
#-------------------------------------------------------------------------------
printf '\n\033[1;34m════════════════════════════\033[0m\n'
printf '  通过: \033[0;32m%d\033[0m   失败: \033[0;31m%d\033[0m\n' "$PASS" "$FAIL"
printf '\033[1;34m════════════════════════════\033[0m\n'
[ "$FAIL" -eq 0 ] || exit 1
