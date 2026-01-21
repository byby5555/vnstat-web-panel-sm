# vnstat-web-panel

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

- Web: `http://<server-ip>:<port>/` (will redirect to `/vnstat/`)
- CGI: `http://<server-ip>:<port>/cgi-bin/vnstat-web-config.cgi`

Common commands:

```bash
# manual update
sudo /usr/local/bin/vnstat-web-update.sh

# lighttpd status
systemctl status lighttpd --no-pager

# lighttpd logs
journalctl -u lighttpd -n 80 --no-pager
```

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
