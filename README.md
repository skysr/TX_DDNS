# TX_DDNS

基于 DNSPod API 的动态 DNS 更新脚本，自动将本地公网 IP 同步到 DNS 解析记录。

## 功能特性

- **多记录 / 多子域名批量管理**，一条记录失败不影响其它记录
- **自动发现解析记录**，从 DNSPod 拉取真实记录列表，免去手工抄写 ID
- 支持 IPv6 (AAAA) 和 IPv4 (A) 记录，每条记录可独立配置类型
- 支持固定公网 IPv6 地址（`IP_ADDRESS` 全局默认 + 记录列表第 7 字段逐条覆盖，仅 IPv6）
- 自动检测公网 IP 地址变化（多地址网卡优先取非 deprecated 地址）
- 智能更新策略：仅在 IP 变化或达到强制周期时触发
- 纯 Bash 实现，无外部依赖（无需 Python/jq）
- 完善的错误处理和日志记录
- 日志自动轮转
- Docker 和 systemd 服务支持
- 一键安装脚本
- 锁文件防止并发执行
- API 失败自动重试
- Webhook 通知支持（Discord、Slack、Telegram 等）
- 自定义 TTL 配置（全局默认 + 单条覆盖）
- 更新历史记录，可按子域名过滤

## 快速安装

```bash
# 克隆仓库
git clone https://github.com/skysr/TX_DDNS.git
cd TX_DDNS

# 一键安装（需要 root 权限）
sudo ./install.sh
```

安装脚本会引导你配置：
- DNSPod API Token
- 域名和记录 ID
- 记录类型（IPv4/IPv6）
- 网卡名称（带编号选择，列出各网卡当前 IPv4/IPv6，自动推荐带公网 IPv6 的口）
- 固定 IPv6 地址（可选，留空则按网卡自动检测；支持全局默认 + 每条记录单独指定）
- 更新间隔

## 手动安装

```bash
# 复制脚本
cp ddnsv2.sh /usr/local/bin/
chmod +x /usr/local/bin/ddnsv2.sh

# 复制配置文件
mkdir -p /etc/ddns
cp ddnsv2.conf.example /etc/ddns/ddns.conf
vim /etc/ddns/ddns.conf

# 安装 systemd 服务
cp ddns.service /etc/systemd/system/
cp ddns.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now ddns.timer
```

## 多记录 / 多子域名管理

### 启用方式

在配置文件 `/etc/ddns/ddns.conf` 中设置记录列表文件：

```bash
RECORDS_FILE='/etc/ddns/records.list'
```

设置后，配置文件里的 `DOMAIN_ID` / `RECORD_ID` / `SUB_DOMAIN` 不再生效，
所有待更新的记录都由记录列表文件定义。

### 记录列表格式

`/etc/ddns/records.list`，每行一条记录，以 `|` 分隔：

```
子域名|域名ID|记录ID|记录类型|网卡|TTL|IP
```

| 字段 | 必填 | 说明 |
|------|------|------|
| 子域名 | 是 | `www` / `nas` / `@`（主域名）/ `*`（泛解析） |
| 域名 ID | 是 | DNSPod「域名管理」中的域名 ID |
| 记录 ID | 是 | DNSPod「解析记录」中的记录 ID |
| 记录类型 | 否 | `A`（IPv4）/ `AAAA`（IPv6），留空用配置文件的 `RECORD_TYPE` |
| 网卡 | 否 | 留空用配置文件的 `NETWORK_INTERFACE` |
| TTL | 否 | 留空用配置文件的 `RECORD_TTL` |
| IP | 否 | 固定的公网 IPv6 地址（**仅支持 IPv6**，A 记录不支持填写）。填写后直接以此值更新 DNS，不做网卡检测；留空回退到配置文件的 `IP_ADDRESS`，再留空则自动检测。旧的 6 字段行仍然兼容 |

以 `#` 开头的行和空行会被忽略。示例：

```
# 子域名|域名ID|记录ID|类型|网卡|TTL|IP
www|12345678|87654321|AAAA|eth0|600
nas|12345678|87654322|AAAA||600
home|12345678|87654323|A||300
@|12345678|87654324|AAAA|eth0|600|2409:8a00:1::1
*|12345678|87654325|AAAA|eth0|900
```

### 固定公网 IPv6 地址

自动检测取网卡上第一个 global 地址。如果一台机器有多个 global IPv6
（SLAAC 临时地址、ULA、运营商静态分配），或者你想要的地址不在检测的第一位，
可以固定下来。**IP 字段与 `IP_ADDRESS` 只接受 IPv6 地址，A (IPv4) 记录不支持固定**
（给 A 记录填写会在加载时报错，保持 IPv4 走网卡自动检测）：

- **全局默认**：配置文件里 `IP_ADDRESS='2409:8a00:1::1'`，所有未单独指定 IP
  的 AAAA 记录都用这个地址。
- **单条覆盖**：记录列表第 7 字段，`www|12345678|87654321|AAAA|eth0|600|2409:8a00:1::1`。

固定后直接推送该值，不依赖网卡当前状态（加载时校验必须是合法 IPv6，配错会在
启动时报错而不是推错值）。注意固定值 ≠ 实时值：网卡重启后 SLAAC 重新协商出
别的地址时，DNS 仍按固定值推送。

### 自动生成记录列表

不用去 DNSPod 控制台手工抄域名 ID 和记录 ID —— 让脚本自己拉：

```bash
# 查看域名下的所有解析记录
tx-ddns records example.com

# 生成记录列表文件（写入 RECORDS_FILE 指定的路径）
tx-ddns records example.com --generate
```

```
正在获取 example.com 的解析记录...

域名: example.com (ID: 12600793)

序号 | 子域名        | 类型 | 记录ID     | TTL
----------------------------------------------------------------------
1    | www           | A    | 13608148   | 600
2    | www           | AAAA | 13608149   | 600
3    | nas           | A    | 13608150   | 300
4    | @             | AAAA | 13608151   | 600
5    | @             | MX   | 13608152   | 600

共计 5 条记录（其中 A/AAAA 类型可用于 DDNS）
```

`--generate` 只把 A / AAAA 类型的记录写入记录列表文件，
其它类型（MX、CNAME、TXT 等）会被跳过。已存在的文件会先自动备份：

```
# TX_DDNS 记录列表
# 自动生成: 2026-10-21 12:56:02
# 来源: DNSPod Record.List (example.com)
#
# 格式: 子域名|域名ID|记录ID|记录类型|网卡|TTL|IP
# IP 字段留空 = 按网卡自动检测；固定某个公网 IPv6 地址时填入（仅支持 IPv6，A 记录不支持）

www|12600793|13608148|A||600|
www|12600793|13608149|AAAA||600|
nas|12600793|13608150|A||300|
@|12600793|13608151|AAAA||600|
```

生成后可以直接查看：

```bash
tx-ddns list
```

### 查看已配置的记录

```bash
tx-ddns list
```

```
序号 | 子域名        | 类型 | 域名ID   | 记录ID   | TTL    | 网卡     | IP
1    | www           | AAAA | 12345678 | 87654321 | 600    | eth0     | 自动检测
2    | nas           | AAAA | 12345678 | 87654322 | 600    | 自动     | 自动检测
3    | home          | A    | 12345678 | 87654323 | 300    | 自动     | 自动检测
4    | @             | AAAA | 12345678 | 87654324 | 600    | eth0     | 2409:8a00:1::1
5    | *             | AAAA | 12345678 | 87654325 | 900    | eth0     | 自动检测

共计 5 条记录
```

### 各记录独立维护状态

每条记录有独立的 IP 记录和强制更新计数器，互不干扰：

```
/var/log/ddns/
├── db.www_AAAA_12345678      # www 的上次 IP
├── flag.www_AAAA_12345678    # www 的更新计数
├── db.nas_AAAA_12345678
├── flag.nas_AAAA_12345678
└── ...
```

其中 `@`（主域名）和 `*`（泛解析）会转义成 `_at_` 和 `_star_`，
保证不同子域名不会产生相同的文件名。

### 失败隔离

每条记录独立处理。一条记录 API 调用失败时，其余记录继续执行，
最后统一汇总：

```
===== 汇总 =====
记录总数: 5 | 成功: 4 | 失败: 1
```

退出码：全部成功为 0，有任意记录失败为 1。

### 单记录模式（向后兼容）

不设置 `RECORDS_FILE` 时，行为与 v2.4.0 完全一致，状态文件仍是
`/var/log/ddns/db` 和 `/var/log/ddns/flag`。存量部署无需修改。

## 配置

配置文件 `/etc/ddns/ddns.conf`：

```bash
# 必填配置
LOGIN_TOKEN='12345,your_token_here'
DOMAIN_ID='12345678'
RECORD_ID='87654321'
SUB_DOMAIN='www'
RECORD_TYPE='AAAA'

# 可选配置
NETWORK_INTERFACE='eth0'      # 网卡名称
IP_ADDRESS='2409:8a00:1::1'   # 固定 IPv6（全局默认，留空则自动检测；记录列表第 7 字段可逐条覆盖，仅支持 IPv6）
LOG_DIR='/var/log/ddns'        # 日志与状态文件目录
LOCK_DIR='/var/lock'           # 锁文件目录
FORCE_UPDATE_CYCLE=60          # 强制更新周期（单位：检查次数）
RECORD_TTL=600                 # DNS TTL (秒)
MAX_RETRY=3                    # API 重试次数
HISTORY_MAX=100                # 历史记录条数

# Webhook 通知
WEBHOOK_URL=''                 # 留空禁用
WEBHOOK_METHOD='POST'          # POST 或 GET
WEBHOOK_CHAT_ID=''             # Telegram chat_id
```

### 关于 FORCE_UPDATE_CYCLE

该值是**检查次数**而非分钟数。脚本每执行一次计数 +1，计数达到该值时即使 IP 未变
也会强制重推一次 DNS。

换算关系：`检查次数 = 强制周期(分钟) / 检查间隔(分钟)`

例如检查间隔 5 分钟、希望每 60 分钟强制重推一次，则 `FORCE_UPDATE_CYCLE=12`。
一键安装脚本会根据你填写的两个分钟数自动换算。

### 获取 DNSPod 参数

1. 登录 [DNSPod 控制台](https://console.dnspod.cn/)
2. 创建 API Token：用户中心 → API 密钥 → 创建密钥
3. 获取域名 ID 和记录 ID：

```bash
# 列出域名
curl -s -X POST https://dnsapi.cn/Domain.List \
  -d "login_token=ID,Token&format=json"

# 列出记录
curl -s -X POST https://dnsapi.cn/Record.List \
  -d "login_token=ID,Token&format=json&domain_id=域名ID"
```

## 命令行使用

```bash
# 运行更新（更新所有记录）
ddnsv2.sh

# 查看状态（逐条列出所有记录）
ddnsv2.sh status

# 列出已配置的记录
ddnsv2.sh list

# 查看域名的解析记录（从 DNSPod 拉取）
ddnsv2.sh records example.com

# 生成记录列表文件（免去手工抄写 ID）
ddnsv2.sh records example.com --generate

# 测试配置（逐条校验每条记录）
ddnsv2.sh test

# 查看历史
ddnsv2.sh history

# 只看某个子域名的历史
ddnsv2.sh history www

# 详细输出
ddnsv2.sh -v

# 静默模式
ddnsv2.sh -q

# 指定配置
ddnsv2.sh -c /etc/ddns/ddns.conf
```

### Shell 自动补全

安装后支持 tab 键补全：

```bash
# 手动加载补全（安装后自动生效）
source /etc/bash_completion.d/ddns

# 测试补全
ddnsv2.sh <TAB>
# 显示: run  status  test  history  list  -v  -q  -c  -h

ddnsv2.sh st<TAB>
# 补全为: status
```

## Webhook 配置

支持多种通知服务：

### Discord

```bash
WEBHOOK_URL='https://discord.com/api/webhooks/xxx/xxx'
WEBHOOK_METHOD='POST'
```

### Slack

```bash
WEBHOOK_URL='https://hooks.slack.com/services/xxx/xxx/xxx'
WEBHOOK_METHOD='POST'
```

### Telegram Bot

```bash
# 需要先创建 Bot 并获取 chat_id
# 方式一：chat_id 放在配置里
WEBHOOK_URL='https://api.telegram.org/bot<TOKEN>/sendMessage'
WEBHOOK_CHAT_ID='123456789'

# 方式二：chat_id 放在 URL 查询串里
WEBHOOK_URL='https://api.telegram.org/bot<TOKEN>/sendMessage?chat_id=123456789'
```

两种方式都未提供 chat_id 时会跳过发送并记录一条 WARN。

### 通用 JSON

```bash
WEBHOOK_URL='https://your-server.com/webhook'
WEBHOOK_METHOD='POST'
```

发送的 JSON 格式：
```json
{
  "status": "success",
  "ip": "2409:xxxx::xxxx",
  "message": "DNS 更新成功",
  "timestamp": "2025-04-25 16:30:00",
  "domain": "www",
  "type": "AAAA"
}
```

## systemd 服务管理

```bash
# 查看定时器状态
systemctl status ddns.timer

# 查看服务日志
journalctl -u ddns.service -f

# 手动触发更新
systemctl start ddns.service

# 停止/启动定时任务
systemctl stop ddns.timer
systemctl start ddns.timer

# 查看所有定时任务
systemctl list-timers
```

## 日志文件

日志位于 `/var/log/ddns/`：

| 文件 | 说明 |
|------|------|
| `ddns.log` | 运行日志（自动轮转） |
| `db` | 上次 IP 地址 |
| `flag` | 更新计数器 |
| `history.log` | 更新历史记录 |

查看日志：

```bash
tail -f /var/log/ddns/ddns.log
```

## 更新历史

```bash
./ddnsv2.sh history
```

输出示例：
```
==========================================
         TX_DDNS 更新历史
==========================================

最近 100 条记录:

时间                 | 状态   | 类型  | IP 变化                                   | 消息
----------------------------------------------------------------------------------------
2025-04-25 16:30:00 | success| AAAA | 无 -> 2409:xxxx::xxxx                  | 操作成功
2025-04-25 16:00:00 | error  | AAAA | 2409:xxxx::xxxx -> 2409:yyyy::yyyy    | 更新失败: 域名未备案

共计 15 条记录
==========================================
```

## 卸载

```bash
sudo ./install.sh uninstall
```

## 工作流程

```
1. 加载配置文件
       ↓
2. 获取锁（防止并发）
       ↓
3. 检查网络连通性
       ↓
4. 获取当前公网 IP
       ↓
5. 对比历史 IP
       ↓
6. IP 变化或达到周期？
    ├── 否 → 计数器 +1，退出
    └── 是 → 调用 DNSPod API（带重试）
       ↓
7. 记录历史 + 发送通知
```

## 测试

仓库自带回归测试，覆盖锁释放、僵尸锁清理、失败重试、错误计数等关键行为：

```bash
./tests/run_tests.sh
```

无需 root 权限，也不会调用真实的 DNSPod API。

## 故障排除

### 常见问题

| 问题 | 可能原因 | 解决方案 |
|------|----------|----------|
| 无法获取 IP | 网卡名称错误 | 检查 `NETWORK_INTERFACE` 配置 |
| 检测到的不是想要的地址 | 网卡上有多个 global 地址（SLAAC 临时 / ULA / 静态） | 用记录列表第 7 字段或 `IP_ADDRESS` 固定目标地址 |
| 更新失败 | Token 无效 | 验证 `LOGIN_TOKEN` 格式 |
| 网络不可用 | 网络未就绪 | 检查网络连接 |
| 权限错误 | 非 root 运行 | 使用 sudo 或正确配置权限 |
| 获取锁超时 | 其他实例运行 | 删除 `/var/lock/ddns.lock` |

### 调试模式

```bash
# 详细输出查看完整过程
ddnsv2.sh -v -c /etc/ddns/ddns.conf
```

### 检查网络

```bash
# 测试 IPv6
ping -c 1 2001:4860:4860::8888

# 测试 IPv4
ping -c 1 8.8.8.8

# 查看网卡
ip addr show
```

## 适用场景

- 家庭宽带动态 IP 环境
- IPv6 动态 DNS 解析
- 远程访问服务（NAS、Home Assistant 等）
- 自动化运维部署

## 许可证

MIT License — 见 [LICENSE](LICENSE)

## 更新日志

### v2.7.0

固定公网 IPv6 地址 + 安装向导网卡选择优化：

- **固定 IP 支持（仅 IPv6）**：新增 `IP_ADDRESS` 配置项（全局默认）与记录列表
  第 7 字段（单条覆盖）。填写后直接以此值更新 DNS，不做网卡检测——适用于
  多地址网卡（SLAAC 临时 / ULA / 静态地址并存）检测挑错地址、或运营商静态
  分配地址不在检测第一位的场景。仅接受 IPv6 地址，A (IPv4) 记录不支持固定。
  旧的 6 字段记录行完全兼容。
- **固定地址加载时校验**：固定值必须是合法 IPv6，配错在启动时报错，
  不会把错值推到 DNS。
- **安装向导带编号选网卡**：列出每个网卡当前的公网 IPv4/IPv6，自动推荐
  带 global IPv6 的口；支持输入编号或网卡名。同时新增「默认 IPv6 地址」输入
  （留空自动检测）与单条记录的 IP 输入（A 记录自动跳过）。
- **检测优先取非 deprecated 地址**：`get_current_ipv6` 先过滤带 deprecated
  标记的地址（SLAAC 临时地址 600s 后失效），全部 deprecated 才退回第一个。
- `status` / `list` / `test` 输出增加 IP 来源与固定值展示。

### v2.6.0

新增解析记录自动发现：

- **`records <域名>` 命令**：调用 DNSPod `Record.List` 拉取域名下的真实解析
  记录并列出，附带域名 ID 与各记录 ID。免去手工去控制台抄写。
- **`records <域名> --generate`**：把 A / AAAA 类型的记录自动写入记录列表
  文件，其它类型（MX/CNAME/TXT）自动跳过。覆盖前自动备份旧文件。
- **JSON 解析支持格式化响应**：原先 `grep -oP '"records"\s*:\s*\[.*\]'` 中的
  `.*` 不跨行，DNSPod 返回紧凑 JSON 时正常，但任何带换行的格式化响应都会
  解析失败（静默返回 0 条记录）。现统一先压成单行再匹配，
  `parse_json_field` 同样修正。
- **全局选项不再被子命令吞掉**：`records example.com -c conf` 原会报
  「未知选项: -c」，现子命令参数循环遇到全局选项会交回外层处理。

### v2.5.0

新增多记录 / 多子域名批量管理：

- **多记录列表文件**：新增 `RECORDS_FILE` 配置项，支持
  `子域名|域名ID|记录ID|记录类型|网卡|TTL` 格式的记录列表，
  一次运行可更新任意多条记录。
- **每条记录独立状态**：多记录模式下每条记录拥有独立的 `db`/`flag` 文件，
  各自的 IP 变化检测与强制更新计数互不干扰。
- **失败隔离**：单条记录失败不再中断整个批次，其余记录继续执行，
  结束时统一汇总成功/失败数量。
- **新增 `list` 命令**：列出所有已配置的记录，纯本地查看，不发起网络请求。
- **新增 `history <子域名>`**：按子域名过滤历史记录。
- **安装向导支持多条记录**：交互式连续录入，生成 `/etc/ddns/records.list`。
- **记录 key 一一映射**：`@`（主域名）与 `*`（泛解析）分别转义为
  `_at_` 与 `_star_`。此前若把所有非字母数字字符统一替换为 `_`，
  两者会产生相同 key、状态文件互相覆盖。
- **单记录模式完全向后兼容**：未设置 `RECORDS_FILE` 时，行为与状态文件名
  均与 v2.4.0 一致，存量部署无需修改。

### v2.4.0

修复了一批会导致 DDNS 静默失效的缺陷：

- **锁目录永不释放**：锁用 `mkdir` 创建成目录，退出时却用 `rm -f` 删除，导致第二次
  及之后的运行全部卡满 30 秒超时。DDNS 从第二次起实际处于完全失效状态。
- **僵尸锁无法自愈**：PID 文件先被删除后，锁目录残留且无法被识别为僵尸，只能等超时。
- **更新失败后不再重试**：IP 与计数器在调用 API *之前* 落盘，API 失败时状态已被写坏，
  下一轮会判定"IP 未变化"而跳过更新，DNS 永久停留在旧值。现改为 API 成功后才落盘。
- **`test` 命令遇错即崩**：`((errors++))` 在 `set -e` 下返回值非零，首次报错就终止脚本，
  后续检查项不再执行，错误汇总永远打印不出来。
- **`run` 子命令不可用**：README 与补全脚本都列出了 `run`，但参数解析并不接受它。
- **Telegram 通知依赖 jq 且 chat_id 为空**：与"无外部依赖"的声明不符，通知实际发不出去。
  现改为纯 bash URL 编码，并支持从配置或 URL 解析 chat_id。
- **IPv4 校验接受前导零**：`010.1.1.1` 被当作八进制解析成 8，绕过范围校验。
- **Slack 通知格式错误**：body 是 `payload={...}` 而非 JSON。
- **JSON 解析不可靠**：DNSPod v2 返回嵌套结构 `{"status":{"code":1,...}}`，原实现靠
  全文本 grep 匹配，可能取到其它层级的同名字段；现已优先解析 `status` 对象，并支持
  解码 `\uXXXX` 中文转义。
- **systemd 沙箱下无法写锁目录**：`ProtectSystem=strict` 未把 `/var/lock` 列入可写路径。

同时新增 `tests/run_tests.sh` 回归测试套件与 MIT `LICENSE` 文件。
