#!/bin/sh
set -e
TMP=/tmp/edgeone_ips.txt
OUT=//www/server/panel/vhost/nginx/0.edgeone_allow.conf

# 下载 EdgeOne IP 列表（输出为每行一个 CIDR）
curl -fsS https://api.edgeone.ai/ips -o "$TMP" || { echo "fetch failed"; exit 1; }

cat > "$OUT" <<'EOF'
# generated allow list - keep 127.0.0.1 and ::1
allow 127.0.0.1;
allow ::1;
EOF

# append EdgeOne IPs (each line expected to be an IP/CIDR)
awk '{ print "allow "$1";" }' "$TMP" >> "$OUT"

# deny everyone else
cat >> "$OUT" <<'EOF'
deny all;
EOF

# test and reload nginx
nginx -t && systemctl reload nginx
