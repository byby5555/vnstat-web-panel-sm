# vnstat-web-panel


简陋单机 vnstat+web 流量监控

A lightweight VNStat web panel for Debian/Ubuntu using Lighttpd + CGI.

## 安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/byby5555/vnstat-web-panel-sm/main/install.sh)
```


卸载
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/byby5555/vnstat-web-panel-sm/main/uninstall.sh)
```


During install you can input the panel port (default: `8888`).

## After install

- Web: `http://<server-ip>:<port>/` (redirects to `/vnstat/`)
- Web: `http://<server-ip>:<port>/` (same UI as `/vnstat/`)
- CGI: `http://<server-ip>:<port>/cgi-bin/vnstat-web-config.cgi`

Common commands:

```bash
# manual update
sudo /usr/local/bin/vnstat-web-update.sh

# lighttpd status
systemctl status lighttpd --no-pager

# lighttpd logs
journalctl -u lighttpd -n 80 --no-pager

# 安全管理一级菜单
vn
```


## 新增安全特性（本次更新）

- Web 登录认证（安装时自动随机生成强用户名/强密码，并显示在安装输出，同时保存到 `/root/vnstat-web-login.txt`）。
- 登录失败同一 IP 达到 5 次自动封锁，并记录到 `/var/log/vnstat-web-auth.log`。
- 新增“安全管理”页面弹窗：可查看用户、查看封锁 IP、手动解封、重置密码。
- 新增 VPS 终端管理脚本：`/usr/local/bin/vnstat-web-admin.sh`，并创建快捷命令 `vn`（一级菜单交互，支持改用户名/改密码/重置密码）。
- `scripts/vnstat-web-update.sh` 增加自动清理：当 Web 输出目录超过 `100MB`（可配 `MAX_WEB_SIZE_MB`）时清理临时文件与过期图片/文本。

> 默认认证数据文件：`/etc/vnstat-web/users.json`，会在首次调用认证接口时自动初始化。

## Uninstall

```bash
sudo bash uninstall.sh
```

## Repo layout

- `install.sh` / `uninstall.sh`: installer and remover
- `web/`: static frontend
- `cgi-bin/`: CGI endpoint for reading/writing quota thresholds
- `scripts/`: update & quota check scripts
- `systemd/`: systemd services/timers
- `lighttpd/`: reference configs/notes
- `config/`: example config
