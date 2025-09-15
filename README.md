# CdnOriginUpdater

> English version: see [README.en.md](README.en.md)

自动从 EdgeOne 拉取最新的出口 IP 列表，生成 Nginx 访问白名单并安全重载 Nginx。

> 适用于将源站只对 CDN（EdgeOne）开放的场景，避免直接暴露源站。

## 特性

- 原子化更新：先写临时文件，通过 Nginx 配置校验后再替换，失败自动回滚。
- 幂等与安全：内容无变化不重载；远端返回空列表时跳过更新，避免误封所有访问。
- 并发保护与清理：文件锁避免并发运行；异常退出自动清理临时文件。
- 可配置化：URL、输出路径、测试与重载命令、Curl 选项、是否重载均可覆盖。
- 便捷参数：支持 `--dry-run`(只打印) 与 `--quiet`(安静模式)。
- 兼容 IPv4/IPv6：默认保留 `127.0.0.1` 与 `::1`。

## 目录结构

```
update_edgeone_allow.sh            # 主脚本
systemd/
	edgeone-allow.service            # systemd service（oneshot）
	edgeone-allow.timer              # systemd timer（调度）
	edgeone-allow.env.example        # EnvironmentFile 覆盖示例
```

## 运行环境

- Linux（在源站服务器运行）
- 依赖：bash、curl、awk、nginx、systemctl

> 若未使用 systemd，可通过环境变量自定义重载命令（见下文）。

## 快速开始

默认运行（需要具备写入 Nginx 配置及重载权限）：

```bash
bash update_edgeone_allow.sh
```

仅预览生成内容（不写文件、不重载）：

```bash
bash update_edgeone_allow.sh --dry-run
```

安静模式（减少日志）：

```bash
bash update_edgeone_allow.sh --quiet
```

### 下载与更新脚本（覆盖旧版本）

将脚本下载到 `/usr/local/bin` 并赋予可执行权限（覆盖旧文件）：

```bash
curl -fsSL https://raw.githubusercontent.com/yuanweize/CdnOriginUpdater/main/update_edgeone_allow.sh -o /usr/local/bin/update_edgeone_allow.sh
chmod +x /usr/local/bin/update_edgeone_allow.sh
```

之后可直接执行：

```bash
update_edgeone_allow.sh
```

## 配置项（环境变量）

可在运行前通过环境变量覆盖默认行为：

- `EDGEONE_IPS_URL`：EdgeOne IP 列表地址（每行一个 CIDR）。默认：`https://api.edgeone.ai/ips`
- `OUT`：生成的 Nginx include 文件路径。默认：`/www/server/panel/vhost/nginx/edgeone_allow.conf`
- `NGINX_TEST_CMD`：配置校验命令。默认：`nginx -t`
- `RELOAD_CMD`：重载命令。默认：`systemctl reload nginx`
- `CURL_OPTS`：curl 选项。默认：`-fsS`
- `RELOAD`：是否在有变化时重载 Nginx（1/0）。默认：`1`

示例：

```bash
# 自定义输出路径、关闭自动重载
OUT=/etc/nginx/conf.d/edgeone_allow.conf RELOAD=0 bash update_edgeone_allow.sh

# 自定义测试与重载（非 systemd 环境）
NGINX_TEST_CMD="nginx -t" RELOAD_CMD="nginx -s reload" bash update_edgeone_allow.sh

# 加强 curl 选项（10 秒超时）
CURL_OPTS="-fsS --max-time 10" bash update_edgeone_allow.sh
```

## 在 Nginx 中引用

确保你的站点或全局配置包含生成的 include 文件，例如：

```nginx
# http/server/location 任一层级均可按需引用
include /www/server/panel/vhost/nginx/cdnip/*.conf;
```

生成的内容形如：

```nginx
# EdgeOne allow list (generated 2025-09-15T12:34:56+00:00)
# Do not edit manually. Source: https://api.edgeone.ai/ips
allow 127.0.0.1;
allow ::1;
allow 203.0.113.0/24;
# ...
deny all;
```

> 注意：请勿手动编辑该文件，脚本每次运行会覆盖它。

### [可选] 将 403 重定向到伪装错误页

若希望对非 CDN 回源的请求返回一个迷惑性的错误页，可以将 403 统一映射跳转到你的错误域（例如使用项目 [Error-1402](https://github.com/yuanweize/Error-1402)）：

```nginx
# 1) 只允许 EdgeOne 回源 IP + 本机
include /www/server/panel/vhost/nginx/cdnip/*.conf;

# 2) 把 403 映射为重定向（核心：把 deny 引起的 403 改为跳转）
error_page 403 = @to_error;
location @to_error {
	# 使用 302 临时跳转到错误域（保留原请求路径）
	return 302 https://error-1402.vercel.app$request_uri;
}
```

## 定时更新

你可以用 cron 或 systemd 定时跑该脚本。例如使用 cron（每小时一次）：

```cron
0 * * * * root EDGEONE_IPS_URL=https://api.edgeone.ai/ips /bin/bash /path/to/update_edgeone_allow.sh >> /var/log/edgeone-allow.log 2>&1
```

或使用 systemd timer（推荐在生产环境）：

- Service 单元：执行脚本并重载
- Timer 单元：定义调度频率

使用项目自带的 systemd 模板：

1) 拷贝并按需调整路径（尤其是 service 里 `ExecStart` 的脚本路径）：

```bash
sudo mkdir -p /etc/systemd/system
sudo cp systemd/edgeone-allow.service /etc/systemd/system/
sudo cp systemd/edgeone-allow.timer /etc/systemd/system/
```

2) 可选：创建环境变量覆盖文件（示例位于 `systemd/edgeone-allow.env.example`）：

```bash
sudo cp systemd/edgeone-allow.env.example /etc/default/edgeone-allow
sudoedit /etc/default/edgeone-allow
```

3) 启用并启动 timer：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now edgeone-allow.timer
```

4) 查看状态与日志：

```bash
systemctl status edgeone-allow.service edgeone-allow.timer
journalctl -u edgeone-allow.service --since "1h"
```

如需固定时间频率，可将 timer 改为：

```ini
[Timer]
OnCalendar=hourly
# 或者每日 02:00
# OnCalendar=*-*-* 02:00:00
```

## 故障排查

- “Missing required command”：安装缺失的命令（curl/nginx/systemctl 等）。
- “No write permission”：使用具备写权限的用户或通过 sudo 运行。
- “nginx config test failed; rolling back”：检查 include 路径是否被正确引用、是否与现有规则冲突；修复后重试。
- 远端返回空列表：脚本会跳过更新并保留现有配置，避免全量封禁；可检查 `EDGEONE_IPS_URL` 可用性与返回内容。

## 安全与注意事项

- 空列表保护：远端异常时不会覆盖现有配置，避免锁死访问。
- 原子替换与回滚：确保线上切换安全。
- 并发锁：避免多任务同时写入导致竞态。
- 若你的 Nginx 目录不同（例如宝塔面板），请据实设置 `OUT` 并确认 include 引用路径一致。

## 许可证

MIT
