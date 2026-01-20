# vnstat-web-panel

A lightweight VNStat web panel for Debian/Ubuntu using Lighttpd + CGI.

## Install (one-liner)

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/<YOUR_GH_USER>/vnstat-web-panel/main/install.sh)
```

During install you can input the panel port (default: `8888`).

## After install

- Web: `http://<server-ip>:<port>/vnstat/`
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
