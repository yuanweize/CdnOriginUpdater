#!/usr/bin/env bash
# Purpose: Generate nginx allow list for EdgeOne IPs and safely reload nginx
# Platform: Linux (intended to run on the origin server)
# Requirements: bash, curl, awk, nginx, systemctl

set -euo pipefail

# -------------------- Config (overridable via env) --------------------
: "${EDGEONE_IPS_URL:=https://api.edgeone.ai/ips}"
: "${OUT:=/www/server/panel/vhost/nginx/cdnip/0.edgeone_allow.conf}"
: "${NGINX_TEST_CMD:=nginx -t}"
: "${RELOAD_CMD:=systemctl reload nginx}"
: "${CURL_OPTS:=-fsS --retry 3 --retry-delay 1 --retry-all-errors}"
: "${RELOAD:=1}"         # 1 to reload nginx on changes; 0 to skip

# -------------------- CLI flags --------------------
DRY_RUN=0
QUIET=0
usage() {
	cat <<USAGE
Usage: ${0##*/} [options]

Options:
	-n, --dry-run     Generate to stdout without modifying files or reloading nginx
	-q, --quiet       Suppress informational logs (errors still printed)
	-h, --help        Show this help

Environment overrides:
	EDGEONE_IPS_URL   URL providing EdgeOne IP list (one CIDR per line)
	OUT               Output nginx include file path (default: $OUT)
	NGINX_TEST_CMD    Command to test nginx config (default: "$NGINX_TEST_CMD")
	RELOAD_CMD        Command to reload nginx (default: "$RELOAD_CMD")
	CURL_OPTS         Extra curl options (default: "$CURL_OPTS"). Auto-fallback to --http1.1 on failure
	RELOAD            1 to reload (default), 0 to skip reload
USAGE
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		-n|--dry-run) DRY_RUN=1; RELOAD=0; shift ;;
		-q|--quiet) QUIET=1; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "Unknown option: $1" >&2; usage; exit 2 ;;
	esac
done

log() {
	if [[ "$QUIET" -eq 0 ]]; then
		printf '[%s] %s\n' "$(date -Iseconds)" "$*" >&2
	fi
}

err() { printf '[%s] ERROR: %s\n' "$(date -Iseconds)" "$*" >&2; }

# -------------------- Dependency checks --------------------
need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Missing required command: $1"; exit 127; }; }
need_cmd curl
need_cmd awk
if [[ "$DRY_RUN" -eq 0 ]]; then
	need_cmd nginx
	need_cmd systemctl
fi

# Ensure output directory exists (for non-dry run)
OUT_DIR=$(dirname "$OUT")
if [[ "$DRY_RUN" -eq 0 ]]; then
	mkdir -p "$OUT_DIR"
	# basic permission check
	if [[ -e "$OUT" && ! -w "$OUT" ]] || [[ ! -w "$OUT_DIR" ]]; then
		err "No write permission to $OUT or its directory. Try running as root."
		exit 13
	fi
fi

# -------------------- Fetch EdgeOne IP list --------------------
TMP=$(mktemp -t edgeone_ips.XXXXXX)
NEW=$(mktemp -t edgeone_allow.conf.XXXXXX)
LOCK="$OUT.lock"
BACKUP=""

cleanup() {
	rm -f "$TMP" "$NEW" "$LOCK" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log "Fetching IP list from $EDGEONE_IPS_URL ..."
if ! curl $CURL_OPTS "$EDGEONE_IPS_URL" -o "$TMP"; then
	log "Primary fetch failed; retrying with --http1.1 ..."
	if ! curl $CURL_OPTS --http1.1 "$EDGEONE_IPS_URL" -o "$TMP"; then
		err "Failed to fetch IP list"
		exit 1
	fi
fi

# Abort if list is empty after filtering (avoid locking everyone out)
COUNT=$(awk '
	{ sub(/#.*/, ""); gsub(/^[ \t]+|[ \t]+$/, "", $0); if ($0 != "") c++ }
	END { print c+0 }
' "$TMP")
if [[ "$COUNT" -eq 0 ]]; then
	err "Fetched an empty IP list; keeping current config and skipping reload"
	exit 0
fi

# -------------------- Render new config content --------------------
{
	printf '# EdgeOne allow list (generated %s)\n' "$(date -Iseconds)"
	printf '# Do not edit manually. Source: %s\n' "$EDGEONE_IPS_URL"
	printf 'allow 127.0.0.1;\n'
	printf 'allow ::1;\n'
	awk '
		{
			# remove comments
			sub(/#.*/, "");
			# trim
			gsub(/^[ \t]+|[ \t]+$/, "", $0);
			if ($0 != "") {
				print "allow " $0 ";";
			}
		}
	' "$TMP"
	printf 'deny all;\n'
} > "$NEW"

# Dry-run: print and exit
if [[ "$DRY_RUN" -eq 1 ]]; then
	cat "$NEW"
	exit 0
fi

# If unchanged, skip reload
if [[ -f "$OUT" ]] && cmp -s "$NEW" "$OUT"; then
	log "No changes detected; skipping reload."
	exit 0
fi

# Simple lock to avoid concurrent runs
if ! ( set -o noclobber; : > "$LOCK" ) 2>/dev/null; then
	err "Another instance is running (lock: $LOCK)"
	exit 1
fi

# Backup existing file if present
if [[ -f "$OUT" ]]; then
	BACKUP="$OUT.bak.$(date +%Y%m%d%H%M%S)"
	cp -f "$OUT" "$BACKUP"
	log "Backup created: $BACKUP"
fi

# Atomic replace
chmod 0644 "$NEW" || true
mv -f "$NEW" "$OUT"
log "Wrote new config to $OUT"

# Test nginx config; rollback on failure
if ! eval "$NGINX_TEST_CMD"; then
	err "nginx config test failed; rolling back"
	if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
		mv -f "$BACKUP" "$OUT"
		log "Restored previous config from $BACKUP"
	fi
	exit 1
fi

if [[ "${RELOAD}" == "1" ]]; then
	log "Reloading nginx ..."
	eval "$RELOAD_CMD"
	log "nginx reloaded"
else
	log "Reload skipped (RELOAD=$RELOAD)."
fi
