# CdnOriginUpdater

> 中文版请见 [README.md](README.md)

Fetch the latest EdgeOne egress IP ranges and generate an Nginx allowlist include safely, then reload Nginx if changed.

> Use this when your origin should only be reachable via the CDN (EdgeOne), keeping the origin closed to the public Internet.

## Features

- Atomic updates: write to a temp file, validate with `nginx -t`, then replace; automatic rollback on failure.
- Idempotent and safe: no reload when content is unchanged; skip updates when the remote list is empty to avoid lockouts.
- Concurrency-safe and clean: simple file lock and automatic cleanup via traps.
- Configurable via env: URL, output path, test and reload commands, curl options, reload toggle.
- Handy flags: `--dry-run` and `--quiet`.
- IPv4/IPv6 ready: always includes `127.0.0.1` and `::1`.

## Layout

```
update_edgeone_allow.sh     # main script
systemd/
  edgeone-allow.service     # systemd service unit (oneshot)
  edgeone-allow.timer       # systemd timer unit (schedule)
  edgeone-allow.env.example # example EnvironmentFile overrides
```

## Requirements

- Linux (run on the origin server)
- Dependencies: bash, curl, awk, nginx, systemctl

> If you don't use systemd, override the reload command accordingly.

## Quick start

Default run (requires permission to write the Nginx include and reload Nginx):

```bash
bash update_edgeone_allow.sh
```

Preview only (no writes, no reload):

```bash
bash update_edgeone_allow.sh --dry-run
```

Quiet mode:

```bash
bash update_edgeone_allow.sh --quiet
```

### Download and update the script (overwrite old version)

Download to `/usr/local/bin` and make it executable:

```bash
curl -fsSL https://raw.githubusercontent.com/yuanweize/CdnOriginUpdater/main/update_edgeone_allow.sh -o /usr/local/bin/update_edgeone_allow.sh
chmod +x /usr/local/bin/update_edgeone_allow.sh
```

Then run it directly:

```bash
update_edgeone_allow.sh
```

## Configuration (env vars)

- `EDGEONE_IPS_URL`: EdgeOne IP list (one CIDR per line). Default: `https://api.edgeone.ai/ips`
- `OUT`: Output Nginx include path. Default: `/www/server/panel/vhost/nginx/edgeone_allow.conf`
- `NGINX_TEST_CMD`: Nginx config test command. Default: `nginx -t`
- `RELOAD_CMD`: Reload command. Default: `systemctl reload nginx`
- `CURL_OPTS`: Extra curl options. Default: `-fsS`
- `RELOAD`: Whether to reload Nginx when changed (1/0). Default: `1`

Examples:

```bash
# Custom output path and skip reload
OUT=/etc/nginx/conf.d/edgeone_allow.conf RELOAD=0 bash update_edgeone_allow.sh

# Custom test and reload (non-systemd)
NGINX_TEST_CMD="nginx -t" RELOAD_CMD="nginx -s reload" bash update_edgeone_allow.sh

# Tighter curl options
CURL_OPTS="-fsS --max-time 10" bash update_edgeone_allow.sh
```

## Nginx include

Make sure your site/global config includes the generated file:

```nginx
include /www/server/panel/vhost/nginx/cdnip/*.conf;
```

Generated content example:

```nginx
# EdgeOne allow list (generated 2025-09-15T12:34:56+00:00)
# Do not edit manually. Source: https://api.edgeone.ai/ips
allow 127.0.0.1;
allow ::1;
allow 203.0.113.0/24;
# ...
deny all;
```

> Do not edit the generated file manually; it will be overwritten.

### Optional: redirect 403 to a decoy error page

If you prefer serving a decoy for non-CDN traffic, map 403 to a redirect, e.g. using the [Error-1402](https://github.com/yuanweize/Error-1402) project:

```nginx
# 1) Allow only EdgeOne egress IPs + localhost
include /www/server/panel/vhost/nginx/cdnip/*.conf;

# 2) Turn 403 into a redirect (instead of default deny)
error_page 403 = @to_error;
location @to_error {
  # Temporary redirect to your error host, preserve path
  return 302 https://error-1402.vercel.app$request_uri;
}
```

## Systemd setup

1) Copy units and adjust paths:

```bash
sudo mkdir -p /etc/systemd/system
sudo cp systemd/edgeone-allow.service /etc/systemd/system/
sudo cp systemd/edgeone-allow.timer /etc/systemd/system/
```

2) Optional: create env overrides (edit values as needed):

```bash
sudo cp systemd/edgeone-allow.env.example /etc/default/edgeone-allow
sudoedit /etc/default/edgeone-allow
```

3) Edit the `ExecStart` path in the service file so it points to your clone location, e.g. `/opt/CdnOriginUpdater/update_edgeone_allow.sh`.

4) Enable and start the timer:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now edgeone-allow.timer
```

Check status/logs:

```bash
systemctl status edgeone-allow.service edgeone-allow.timer
journalctl -u edgeone-allow.service --since "1h"
```

## Troubleshooting

- Missing commands: install curl/nginx/systemctl as appropriate.
- Write permission errors: run as a user with access to the output path or use sudo.
- `nginx -t` fails -> rollback occurred: ensure the include path is correct and not conflicting with existing directives.
- Remote empty list: script keeps current config and skips reload to avoid lockouts.

## License

MIT
