# TX_DDNS

基于 DNSPod API 的动态 DNS 更新脚本，自动将本地公网 IP 同步到 DNS 解析记录。

## 功能特性

- 支持 IPv6 (AAAA) 和 IPv4 (A) 记录
- 自动检测公网 IP 地址变化
- 智能更新策略：仅在 IP 变化或达到强制周期时触发
- 纯 Bash 实现，无外部依赖（无需 Python/jq）
- 完善的错误处理和日志记录
- 日志自动轮转
- Docker 和 systemd 服务支持
- 一键安装脚本
- 锁文件防止并发执行
- API 失败自动重试
- Webhook 通知支持（Discord、Slack、Telegram 等）
- 自定义 TTL 配置
- 更新历史记录

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
- 网卡名称
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
FORCE_UPDATE_CYCLE=60          # 强制更新周期
RECORD_TTL=600                 # DNS TTL (秒)
MAX_RETRY=3                    # API 重试次数
HISTORY_MAX=100                # 历史记录条数

# Webhook 通知
WEBHOOK_URL=''                 # 留空禁用
```

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
# 运行更新
ddnsv2.sh

# 查看状态
ddnsv2.sh status

# 测试配置
ddnsv2.sh test

# 查看历史
ddnsv2.sh history

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
# 显示: run  status  test  history  -v  -q  -c  -h

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
WEBHOOK_URL='https://api.telegram.org/bot<TOKEN>/sendMessage'
```

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
2025-04-25 16:30:00 | success| AAAA | 无 -> 2409:xxxx::xxxx                  | Operation failed
2025-04-25 16:00:00 | success| AAAA | 2409:xxxx::xxxx -> 2409:yyyy::yyyy    | 

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

## 故障排除

### 常见问题

| 问题 | 可能原因 | 解决方案 |
|------|----------|----------|
| 无法获取 IP | 网卡名称错误 | 检查 `NETWORK_INTERFACE` 配置 |
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

MIT License
