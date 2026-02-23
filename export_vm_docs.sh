#!/usr/bin/env bash
set -u

# VM Dokumentations-Exporter -> Markdown für BookStack
# - erzeugt ./export-<hostname>-<timestamp>/bookstack.md
# - redacted sensible Werte (Passwörter/Tokens/Keys) standardmäßig

REDact=1
OUTDIR=""
INCLUDE_FILES=()
INCLUDE_DIRS=()

usage() {
  cat <<'EOF'
Usage:
  sudo ./export_vm_docs.sh [--out DIR] [--no-redact] [--include FILE]... [--include-dir DIR]...

Examples:
  sudo ./export_vm_docs.sh
  sudo ./export_vm_docs.sh --out /root/export-vm --include /etc/caddy/Caddyfile --include-dir /opt/stacks
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUTDIR="${2:-}"; shift 2 ;;
    --no-redact) REDact=0; shift ;;
    --include) INCLUDE_FILES+=("${2:-}"); shift 2 ;;
    --include-dir) INCLUDE_DIRS+=("${2:-}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

HOST="$(hostname -f 2>/dev/null || hostname)"
TS="$(date +%F_%H%M%S)"
if date -Is >/dev/null 2>&1; then
  NOW_ISO="$(date -Is)"
else
  NOW_ISO="$(date '+%Y-%m-%dT%H:%M:%S%z')"
fi
if [[ -z "$OUTDIR" ]]; then
  OUTDIR="./export-${HOST}-${TS}"
fi

mkdir -p "$OUTDIR/files"
MD="$OUTDIR/bookstack.md"
: > "$MD"

write() { printf "%s\n" "$*" >> "$MD"; }
h1() { write "# $1"; write ""; }
h2() { write "## $1"; write ""; }
h3() { write "### $1"; write ""; }

have() {
  local bin="$1"
  local cache_var="__HAVE_${bin//[^[:alnum:]_]/_}"
  if [[ -n "${!cache_var+x}" ]]; then
    return "${!cache_var}"
  fi
  if command -v "$bin" >/dev/null 2>&1; then
    printf -v "$cache_var" '%s' 0
    return 0
  fi
  printf -v "$cache_var" '%s' 1
  return 1
}

# Redaction über python3 (fallback: sed)
sanitize_to() {
  local src="$1"
  local dst="$2"

  # Skip binary files (empty files are fine)
  if [[ -s "$src" ]] && ! LC_ALL=C grep -Iq . "$src" 2>/dev/null; then
    printf "[SKIPPED: binary file]\n" > "$dst"
    return 0
  fi

  # Skip private keys komplett
  if grep -qE 'BEGIN (RSA |EC |OPENSSH |PRIVATE )?PRIVATE KEY' "$src" 2>/dev/null; then
    printf "[SKIPPED: looks like a private key]\n" > "$dst"
    return 0
  fi

  # Schnellpfad: ohne typische Secret-Muster unverändert übernehmen
  if [[ "$REDact" -eq 1 ]] && ! grep -Eqi \
    '(pass(word|wd)?|secret|token|api[_-]?key|client[_-]?secret|bearer|authorization|private[_-]?key|[A-Za-z0-9_-]{40,})' \
    "$src" 2>/dev/null; then
    cat "$src" > "$dst"
    return 0
  fi

  if [[ "$REDact" -eq 0 ]]; then
    cat "$src" > "$dst"
    return 0
  fi

  if have python3; then
    python3 - "$src" > "$dst" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
try:
    text = p.read_text(errors="replace")
except Exception as e:
    print(f"[ERROR reading file: {e}]")
    sys.exit(0)

key_re = re.compile(r'(?i)\b(pass(word|wd)?|secret|token|api[_-]?key|client[_-]?secret|bearer|authorization|private[_-]?key)\b')

def redact_line(line: str) -> str:
    m = re.match(r'^(\s*[^#\n\r]*?)([:=])(\s*)(.+)$', line)
    if m:
        left, sep, sp, right = m.group(1), m.group(2), m.group(3), m.group(4)
        if key_re.search(left):
            return f"{left}{sep}{sp}***REDACTED***\n"
    if re.search(r'(?i)^\s*authorization\s*:\s*', line):
        return re.sub(r'(:\s*).+', r'\1***REDACTED***', line.rstrip()) + "\n"
    line2 = re.sub(r'(?i)\bBearer\s+[A-Za-z0-9\-\._~\+\/]+=*', 'Bearer ***REDACTED***', line)
    line2 = re.sub(r'([A-Za-z0-9_\-]{40,})', '***REDACTED_LONG_TOKEN***', line2)
    return line2

out = []
for ln in text.splitlines(keepends=True):
    out.append(redact_line(ln))
sys.stdout.write("".join(out))
PY
  else
    sed -E \
      -e 's/^([[:space:]]*(pass(word|wd)?|secret|token|api[_-]?key|client[_-]?secret)[[:space:]]*[:=][[:space:]]*).+$/\1***REDACTED***/I' \
      -e 's/([Bb]earer)[[:space:]]+[A-Za-z0-9._-]+/\1 ***REDACTED***/g' \
      "$src" > "$dst"
  fi
}

cmd_block() {
  local title="$1"; shift
  h3 "$title"
  {
    printf '```\n'
    "$@" 2>&1 || true
    printf '\n```\n\n'
  } >> "$MD"
}

cmd_block_if() {
  local title="$1"; shift
  local bin="$1"; shift
  if have "$bin"; then
    cmd_block "$title" "$bin" "$@"
  else
    h3 "$title"
    write "_(nicht verfügbar: \`$bin\`)_"
    write ""
  fi
}

append_file() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  local safe_name
  safe_name="${path//\//_}"
  local dst="$OUTDIR/files/${safe_name}"
  sanitize_to "$path" "$dst"

  h3 "Datei: \`$path\`"
  {
    printf '```\n'
    cat "$dst"
    printf '\n```\n\n'
  } >> "$MD"
}

append_dir_files() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  # Collect candidate files (limit to 200) and sanitize in batch for performance
  local -a files
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "$dir" -type f \( \
            -name "*.yml" -o -name "*.yaml" -o -name "*.json" -o -name "*.toml" -o -name "*.ini" -o -name "*.conf" \
            -o -name "docker-compose.yml" -o -name "compose.yml" -o -name "Caddyfile" -o -name "*.service" \
          \) 2>/dev/null | head -n 200)

  if [[ ${#files[@]} -eq 0 ]]; then
    return 0
  fi

  # Batch-sanitize files with a single Python process if available
  batch_sanitize() {
    if have python3; then
      python3 - "$OUTDIR/files" "${files[@]}" <<'PY'
import sys, pathlib, re
outdir = pathlib.Path(sys.argv[1])
paths = sys.argv[2:]
key_re = re.compile(r'(?i)\b(pass(word|wd)?|secret|token|api[_-]?key|client[_-]?secret|bearer|authorization|private[_-]?key)\b')

def sanitize_text(text):
    # simple redaction rules similar to the inline script
    def redact_line(line):
        m = re.match(r'^(\s*[^#\n\r]*?)([:=])(\s*)(.+)$', line)
        if m:
            left, sep, sp, right = m.group(1), m.group(2), m.group(3), m.group(4)
            if key_re.search(left):
                return f"{left}{sep}{sp}***REDACTED***\n"
        if re.search(r'(?i)^\s*authorization\s*:\s*', line):
            return re.sub(r'(:\s*).+', r'\1***REDACTED***', line.rstrip()) + "\n"
        line2 = re.sub(r'(?i)Bearer\s+[A-Za-z0-9\-\._~\+\/]+=*', 'Bearer ***REDACTED***', line)
        line2 = re.sub(r'([A-Za-z0-9_\-]{40,})', '***REDACTED_LONG_TOKEN***', line2)
        return line2

    out = []
    for ln in text.splitlines(keepends=True):
        out.append(redact_line(ln))
    return ''.join(out)

for p in paths:
    src = pathlib.Path(p)
    safe = src.as_posix().replace('/', '_')
    dst = outdir / safe
    try:
        if src.exists() and src.is_file():
            text = src.read_text(errors='replace')
            dst.write_text(sanitize_text(text))
        else:
            dst.write_text('[MISSING]\n')
    except Exception as e:
        dst.write_text(f'[ERROR reading file: {e}]\n')
PY
      return 0
    fi
    return 1
  }

  mkdir -p "$OUTDIR/files"
  batch_sanitize || true

  # Append sanitized files to markdown
  for f in "${files[@]}"; do
    append_file "$f"
  done
}

h1 "VM-Dokumentation: ${HOST}"
write "- Export-Zeitpunkt: \`$NOW_ISO\`"
write "- Redaction: \`$([[ "$REDact" -eq 1 ]] && echo enabled || echo disabled)\`"
write ""

h2 "System"
cmd_block_if "OS / Release" cat /etc/os-release
cmd_block_if "Kernel / Architektur" uname -a
cmd_block_if "Uptime" uptime
cmd_block_if "CPU / RAM (kurz)" sh -c 'echo "CPU:"; (lscpu 2>/dev/null | egrep -i "Model name|CPU\\(s\\)|Thread|Core|Socket" || true); echo ""; echo "RAM:"; (free -h || true)'

h2 "Netzwerk"
cmd_block_if "Interfaces" ip -br a
cmd_block_if "Routing" ip r
cmd_block_if "DNS (resolv.conf)" cat /etc/resolv.conf
cmd_block_if "Ports (Listening)" ss -tulpn

h2 "Storage"
cmd_block_if "Blockgeräte" lsblk -f
cmd_block_if "Mounts" mount
cmd_block_if "Disk Usage" df -hT

h2 "Benutzer / SSH"
cmd_block_if "Lokale Benutzer (UID >= 1000)" sh -c 'awk -F: '\''$3>=1000{print $1" (uid="$3", gid="$4")"}'\'' /etc/passwd'
cmd_block_if "SSH-Config (sshd_config, falls vorhanden)" sh -c 'test -f /etc/ssh/sshd_config && sed -n "1,200p" /etc/ssh/sshd_config || echo "no /etc/ssh/sshd_config"'

h2 "Services"
if have systemctl; then
  cmd_block "Running services" systemctl list-units --type=service --state=running --no-pager
  cmd_block "Enabled services" systemctl list-unit-files --type=service --state=enabled --no-pager
else
  write "_(systemctl nicht verfügbar – evtl. Container ohne systemd)_"
  write ""
fi

# Weitere Service-Runtimes / Manager erfassen
h2 "Weitere Service-Manager / Container-Runtimes"
cmd_block_if "Supervisord (supervisorctl status)" supervisorctl status
cmd_block_if "Podman containers" podman ps -a
cmd_block_if "Docker containers" docker ps -a
cmd_block_if "containerd (crictl)" crictl ps

# LXC / LXD
if have lxc; then
  cmd_block "LXC/LXD: lxc list (falls LXD)" lxc list --format=csv || true
elif command -v lxc-ls >/dev/null 2>&1; then
  cmd_block "LXC: lxc-ls -f" lxc-ls -f
fi

# Snap services (falls vorhanden)
cmd_block_if "snap services" snap services

# SysV / init.d Auflistung
cmd_block "SysV init scripts" ls -la /etc/init.d || true

# Runit / s6 Hinweise
cmd_block_if "Runit service dirs (/etc/service)" ls /etc/service || true
cmd_block_if "S6 service dir (/run)" ls /run 2>/dev/null || true

# Detailliertere runit/s6 Abfrage
if command -v sv >/dev/null 2>&1; then
  h3 "Runit: sv status (per service)"
  for d in /etc/service/*; do
    [[ -d "$d" ]] || continue
    svc="$(basename "$d")"
    {
      printf 'Service: %s\n' "$svc"
      sv status "$svc" 2>&1 || true
      printf '\n'
    } >> "$MD"
  done
fi

if command -v s6-svscanctl >/dev/null 2>&1 || command -v s6 >/dev/null 2>&1; then
  h3 "s6: basic status info"
  {
    printf 's6 services listing (ls /run):\n'
    ls -la /run 2>/dev/null || true
    printf '\n'
  } >> "$MD"
fi

h2 "Firewall"
cmd_block_if "UFW" ufw status verbose
cmd_block_if "nftables (gekürzt)" sh -c 'nft list ruleset 2>/dev/null | sed -n "1,250p"'
cmd_block_if "iptables (gekürzt)" sh -c 'iptables -S 2>/dev/null | sed -n "1,250p"'

h2 "Cronjobs"
cmd_block_if "root crontab" sh -c 'crontab -l 2>/dev/null || echo "no root crontab"'
cmd_block_if "/etc/cron.*" sh -c 'ls -la /etc/cron.* 2>/dev/null || true'

h2 "Web/Proxy-Konfigurationen (falls vorhanden)"
[[ -f /etc/caddy/Caddyfile ]] && append_file /etc/caddy/Caddyfile
[[ -d /etc/nginx ]] && append_dir_files /etc/nginx
[[ -d /etc/apache2 ]] && append_dir_files /etc/apache2

h2 "Docker (falls vorhanden)"
if have docker; then
  COMPOSE_FILES=()
  cmd_block "Docker version" docker version
  cmd_block "Docker ps" docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
  if docker compose version >/dev/null 2>&1; then
    cmd_block "Docker compose ls" docker compose ls
    while IFS= read -r cf; do
      COMPOSE_FILES+=("$cf")
    done < <(find /opt /srv /home /root -maxdepth 6 -type f \( -name "docker-compose.yml" -o -name "compose.yml" \) 2>/dev/null | head -n 50)
  fi

  h3 "Gefundene Compose-Dateien (max 50)"
  {
    printf '```\n'
    if [[ "${#COMPOSE_FILES[@]}" -gt 0 ]]; then
      printf '%s\n' "${COMPOSE_FILES[@]}"
    else
      printf '%s\n' "[none found]"
    fi
    printf '```\n\n'
  } >> "$MD"

  for cf in "${COMPOSE_FILES[@]:0:20}"; do
    append_file "$cf"
  done
else
  write "_(docker nicht installiert)_"
  write ""
fi

# Podman fallback: capture podman-compose / containers if podman exists
if have podman; then
  h3 "Podman: installed containers"
  {
    printf '```
'
    podman ps -a || true
    printf '
```

'
  } >> "$MD"
fi

h2 "Zusätzliche Includes"
for f in "${INCLUDE_FILES[@]:-}"; do
  [[ -n "$f" ]] && append_file "$f"
done
for d in "${INCLUDE_DIRS[@]:-}"; do
  [[ -n "$d" ]] && append_dir_files "$d"
done

h2 "Hinweise"
write "- **Vor dem Einfügen in BookStack**: Markdown einmal kurz durchscrollen (Secrets/Keys prüfen)."
write "- Wenn du mehr/andere Pfade willst: Script mit \`--include\` / \`--include-dir\` erneut laufen lassen."
write ""

# Performance / completeness notes (für Admins)
write "- Hinweis: Dieses Script sammelt breite Systeminfos; bei sehr großen Systemen kann das Lesen vieler Logs langsam sein."
write "- Tipp: Für schnellere Läufe: \`--include\` benutzen um nur relevante Dateien einzuschließen."
write ""

echo "OK: Markdown exportiert nach: $MD"
echo "     Sanitized files in:     $OUTDIR/files/"
