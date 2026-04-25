# TX_DDNS

基于 DNSPod API 的动态 DNS 更新脚本，自动将本地公网 IP 同步到 DNS 解析记录。

## 功能特性

- 支持 IPv6 (AAAA) 和 IPv4 (A) 记录
- 自动检测公网 IP 地址变化
- 智能更新策略：仅在 IP 变化或达到强制更新周期时触发
- 完善的错误处理和日志记录
- 配置与脚本分离，便于管理

## 版本说明

| 版本 | 文件 | 说明 |
|------|------|------|
| v1 | `ddnsv1.sh` | 简单版本，适合快速部署 |
| v2 | `ddnsv2.sh` | 增强版本，推荐使用 |

### v2 新增特性
- 配置文件分离（`ddnsv2.conf`）
- 日志记录功能
- 网络连通性检查
- JSON 响应解析
- IPv4 支持
- 命令行参数支持

## 安装

```bash
# 克隆仓库
git clone https://github.com/skysr/TX_DDNS.git
cd TX_DDNS

# 复制并编辑配置文件
cp ddnsv2.conf.example ddnsv2.conf
vim ddnsv2.conf

# 添加执行权限
chmod +x ddnsv2.sh
```

## 配置

编辑 `ddnsv2.conf` 文件：

```bash
# DNSPod API Token（ID,Token 格式）
LOGIN_TOKEN='12345,your_token_here'

# 域名信息
DOMAIN_ID='12345678'
RECORD_ID='87654321'
SUB_DOMAIN='www'

# 记录类型：AAAA（IPv6）或 A（IPv4）
RECORD_TYPE='AAAA'

# 网卡名称（可选，留空自动检测）
NETWORK_INTERFACE=''

# 日志目录
LOG_DIR='/var/log/ddns'

# 强制更新周期（每次 crontab 调用计一次）
FORCE_UPDATE_CYCLE=60
```

### 获取 DNSPod 参数

1. 登录 [DNSPod](https://console.dnspod.cn/)
2. 创建 API Token：用户中心 → API 密钥 → 创建密钥
3. 获取域名 ID 和记录 ID：
   ```bash
   # 列出域名
   curl -s -X POST https://dnsapi.cn/Domain.List -d "login_token=ID,Token&format=json"
   
   # 列出记录
   curl -s -X POST https://dnsapi.cn/Record.List -d "login_token=ID,Token&format=json&domain_id=域名ID"
   ```

## 使用

### 手动执行

```bash
# 正常执行
./ddnsv2.sh

# 详细输出
./ddnsv2.sh -v

# 静默模式
./ddnsv2.sh -q

# 指定配置文件
./ddnsv2.sh -c /path/to/config.conf

# 查看帮助
./ddnsv2.sh -h
```

### 定时任务

编辑 crontab：

```bash
crontab -e
```

添加以下内容（每分钟检查一次）：

```cron
* * * * * /path/to/TX_DDNS/ddnsv2.sh -q >> /var/log/ddns/cron.log 2>&1
```

或每 5 分钟检查：

```cron
*/5 * * * * /path/to/TX_DDNS/ddnsv2.sh -q >> /var/log/ddns/cron.log 2>&1
```

## 日志

日志文件位于 `/var/log/ddns/`：

| 文件 | 说明 |
|------|------|
| `ddns.log` | 运行日志 |
| `db` | 上次 IP 地址 |
| `flag` | 更新计数器 |

查看日志：

```bash
tail -f /var/log/ddns/ddns.log
```

## 工作原理

```
1. 加载配置文件
       ↓
2. 检查网络连通性
       ↓
3. 获取当前公网 IP
       ↓
4. 对比历史 IP
       ↓
5. IP 变化或达到强制周期？
    ├── 否 → 计数器 +1，退出
    └── 是 → 调用 DNSPod API 更新
       ↓
6. 记录新 IP 到本地
```

## 适用场景

- 家庭宽带动态 IP 环境
- IPv6 动态 DNS 解析
- 远程访问服务（NAS、Home Assistant 等）
