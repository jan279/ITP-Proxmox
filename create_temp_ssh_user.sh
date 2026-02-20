#!/usr/bin/env bash
set -euo pipefail

########################################
# Konfiguration (hier anpassen)
########################################
DOKU_USER="doku"
DOKU_PASS="doku"   # <- fest definieren
OUT_BASE="/var/tmp/doku_exports"           # wohin der Export geschrieben wird
NO_REDACT=0                             # 0 = Secrets redacted (empfohlen), 1 = keine Redaction
DELETE_AFTER_MIN=30
########################################

if [[ $EUID -ne 0 ]]; then
  echo "Bitte als root ausführen: sudo $0"
  exit 1
fi

if [[ -z "${DOKU_PASS}" || "${DOKU_PASS}" == "HIER_DEIN_PASSWORT_SETZEN" ]]; then
  echo "⚠️  Bitte setze DOKU_PASS im Skript, bevor du es ausführst."
  exit 1
fi

HOST="$(hostname -f 2>/dev/null || hostname)"
TS="$(date +%F_%H%M%S)"
OUTDIR="${OUT_BASE}/export-${HOST}-${TS}"

DIR="$(cd "$(dirname "$0")" && pwd)"

if id "$DOKU_USER" >/dev/null 2>&1; then
  echo "❌ Benutzer '$DOKU_USER' existiert bereits. Bitte anderen Namen wählen oder User vorher löschen."
  exit 1
fi

echo "👤 Lege temporären Benutzer ${DOKU_USER} an (SSH-Zugriff) ..."
useradd -m -s /bin/bash "$DOKU_USER"
echo "${DOKU_USER}:${DOKU_PASS}" | chpasswd

# Passwort nicht kurzfristig ablaufen lassen
if command -v chage >/dev/null 2>&1; then
  chage -M 99999 -m 0 "$DOKU_USER" || true
  passwd -u "$DOKU_USER" >/dev/null 2>&1 || true
fi

DELETION_DELAY_SECONDS=$((DELETE_AFTER_MIN*60))
if command -v systemd-run >/dev/null 2>&1; then
  echo "⏳ Plane automatisches Löschen in ${DELETE_AFTER_MIN} Minuten mit systemd-run ..."
  systemd-run --on-active=${DELETE_AFTER_MIN}m --unit="delete-tempuser-${DOKU_USER}" --quiet --no-block /usr/bin/env bash -c "pkill -u ${DOKU_USER} 2>/dev/null || true; /usr/sbin/userdel -r ${DOKU_USER} 2>/dev/null || true"
else
  echo "⏳ Starte Hintergrundjob: Lösche Benutzer in ${DELETE_AFTER_MIN} Minuten ..."
  nohup bash -c "sleep ${DELETION_DELAY_SECONDS}; pkill -u ${DOKU_USER} 2>/dev/null || true; /usr/sbin/userdel -r ${DOKU_USER} 2>/dev/null || true" >/dev/null 2>&1 &
fi
echo "🕒 Benutzer ${DOKU_USER} wird in ${DELETE_AFTER_MIN} Minuten automatisch entfernt."

mkdir -p "$OUTDIR/files"

echo "📝 Starte VM-Dokumentationsexport -> $OUTDIR"
if [[ "$NO_REDACT" -eq 1 ]]; then
  bash "$DIR/export_vm_docs.sh" --out "$OUTDIR" --no-redact
else
  bash "$DIR/export_vm_docs.sh" --out "$OUTDIR"
fi

echo "✅ Fertig. Ergebnis: $OUTDIR/bookstack.md"
