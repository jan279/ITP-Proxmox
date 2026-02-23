#!/usr/bin/env bash
set -euo pipefail

#############################################
# KONFIGURATION (HIER ANPASSEN)
#############################################
BOOKSTACK_URL="https://doku.syntax-terror.tech"
TOKEN_ID="H7yPe8ePCW5pGCmuEGAkIqEyUxet0Ci2"
TOKEN_SECRET="MEsgJbhcnCmmDHBoOTmPg5mcilJdTVpT"

# Lokaler Ordner mit deinen Markdown-Dateien
IMPORT_DIR="$HOME/doku"

# Name des Buchs, das erstellt werden soll
BOOK_NAME="Server Doku Import"

# Optional: Beschreibung
BOOK_DESCRIPTION="Automatischer Import aus Markdown-Dateien"

# Wenn 1, werden Unterordner als Kapitel erstellt (empfohlen)
CREATE_CHAPTERS_FROM_FOLDERS=1
#############################################

AUTH_HEADER="Authorization: Token ${TOKEN_ID}:${TOKEN_SECRET}"
MAPPING_FILE="$(mktemp -t bookstack_chapter_map.XXXXXX)"
trap 'rm -f "$MAPPING_FILE"' EXIT

# --- Helper: API POST ---
api_post() {
  local endpoint="$1"
  local payload="$2"

  local response
  response="$(curl -sS -X POST "${BOOKSTACK_URL}${endpoint}" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json" \
    --data "$payload")"

  echo "$response"
}

# --- Helper: API GET ---
api_get() {
  local endpoint="$1"

  curl -sS -X GET "${BOOKSTACK_URL}${endpoint}" \
    -H "$AUTH_HEADER" \
    -H "Content-Type: application/json"
}

# --- Vorchecks ---
if [[ ! -d "$IMPORT_DIR" ]]; then
  echo "  IMPORT_DIR existiert nicht: $IMPORT_DIR"
  exit 1
fi

if [[ "$TOKEN_ID" == "HIER_DEIN_TOKEN_ID" || "$TOKEN_SECRET" == "HIER_DEIN_TOKEN_SECRET" ]]; then
  echo "  Bitte TOKEN_ID und TOKEN_SECRET im Skript eintragen."
  exit 1
fi

command -v jq >/dev/null 2>&1 || { echo "  jq fehlt. Installiere mit: brew install jq"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "  curl fehlt."; exit 1; }

# --- API erreichbar? ---
echo "🔎 Prüfe API..."
api_get "/api/docs" >/dev/null || {
  echo "  Konnte ${BOOKSTACK_URL}/api/docs nicht erreichen."
  echo "   Prüfe URL, VPN/Netzwerk, Reverse Proxy, Zertifikat."
  exit 1
}
echo "  API erreichbar"

# --- Buch erstellen ---
echo "📚 Erstelle Buch: $BOOK_NAME"
BOOK_PAYLOAD="$(jq -n \
  --arg name "$BOOK_NAME" \
  --arg description "$BOOK_DESCRIPTION" \
  '{name:$name, description:$description}')"

BOOK_RESP="$(api_post "/api/books" "$BOOK_PAYLOAD")"
BOOK_ID="$(echo "$BOOK_RESP" | jq -r '.id // empty')"

if [[ -z "$BOOK_ID" ]]; then
  echo "  Buch konnte nicht erstellt werden."
  echo "Antwort:"
  echo "$BOOK_RESP" | jq . 2>/dev/null || echo "$BOOK_RESP"
  exit 1
fi

echo "  Buch erstellt (ID: $BOOK_ID)"

# --- Kapitel-Mapping-Funktionen (ohne Bash-Associative-Arrays, damit Mac-Bash kompatibel bleibt) ---
get_mapped_chapter_id() {
  local rel_dir="$1"
  awk -F'\t' -v key="$rel_dir" '$1 == key {print $2}' "$MAPPING_FILE" | tail -n 1
}

set_mapped_chapter_id() {
  local rel_dir="$1"
  local chapter_id="$2"
  printf "%s\t%s\n" "$rel_dir" "$chapter_id" >> "$MAPPING_FILE"
}

create_chapter_for_dir() {
  local rel_dir="$1"

  # root bekommt kein Kapitel
  if [[ "$rel_dir" == "." || -z "$rel_dir" ]]; then
    return 0
  fi

  local existing_id
  existing_id="$(get_mapped_chapter_id "$rel_dir" || true)"
  if [[ -n "$existing_id" ]]; then
    return 0
  fi

  # BookStack hat keine verschachtelten Kapitel -> wir nutzen den relativen Pfad als Kapitelnamen
  local chapter_name="$rel_dir"

  echo "📁 Erstelle Kapitel: $chapter_name"

  local payload resp chapter_id
  payload="$(jq -n \
    --arg name "$chapter_name" \
    --argjson book_id "$BOOK_ID" \
    '{name:$name, book_id:$book_id}')"

  resp="$(api_post "/api/chapters" "$payload")"
  chapter_id="$(echo "$resp" | jq -r '.id // empty')"

  if [[ -z "$chapter_id" ]]; then
    echo "  Kapitel konnte nicht erstellt werden: $chapter_name"
    echo "Antwort:"
    echo "$resp" | jq . 2>/dev/null || echo "$resp"
    exit 1
  fi

  set_mapped_chapter_id "$rel_dir" "$chapter_id"
  echo "  Kapitel erstellt (ID: $chapter_id)"
}

# --- Erst alle Unterordner als Kapitel anlegen ---
if [[ "$CREATE_CHAPTERS_FROM_FOLDERS" -eq 1 ]]; then
  echo "  Erzeuge Kapitel aus Unterordnern..."
  # Achtung: Filenamen mit Newlines werden nicht unterstützt (in der Praxis meist egal)
  while IFS= read -r dir; do
    [[ -z "$dir" ]] && continue
    [[ "$dir" == "$IMPORT_DIR" ]] && continue

    rel_dir="${dir#$IMPORT_DIR/}"
    create_chapter_for_dir "$rel_dir"
  done < <(find "$IMPORT_DIR" -type d | sort)
fi

# --- Markdown-Dateien importieren ---
echo "📝 Importiere Markdown-Dateien..."
import_count=0
skip_count=0

while IFS= read -r file; do
  [[ -z "$file" ]] && continue

  rel_file="${file#$IMPORT_DIR/}"
  rel_dir="$(dirname "$rel_file")"
  base_name="$(basename "$file")"
  page_name="${base_name%.*}"

  # Leere Dateien überspringen
  if [[ ! -s "$file" ]]; then
    echo "⏭️  Überspringe leere Datei: $rel_file"
    ((skip_count+=1))
    continue
  fi

  echo "➡️  Importiere: $rel_file"

  if [[ "$rel_dir" == "." ]]; then
    # Seite direkt ins Buch
    PAGE_PAYLOAD="$(jq -n \
      --arg name "$page_name" \
      --argjson book_id "$BOOK_ID" \
      --rawfile markdown "$file" \
      '{name:$name, book_id:$book_id, markdown:$markdown}')"
  else
    # Seite ins Kapitel
    chapter_id="$(get_mapped_chapter_id "$rel_dir" || true)"

    if [[ -z "$chapter_id" ]]; then
      # Falls CREATE_CHAPTERS_FROM_FOLDERS=0 oder irgendwas schiefging, on-demand erstellen
      create_chapter_for_dir "$rel_dir"
      chapter_id="$(get_mapped_chapter_id "$rel_dir")"
    fi

    PAGE_PAYLOAD="$(jq -n \
      --arg name "$page_name" \
      --argjson chapter_id "$chapter_id" \
      --rawfile markdown "$file" \
      '{name:$name, chapter_id:$chapter_id, markdown:$markdown}')"
  fi

  PAGE_RESP="$(api_post "/api/pages" "$PAGE_PAYLOAD")"
  PAGE_ID="$(echo "$PAGE_RESP" | jq -r '.id // empty')"

  if [[ -z "$PAGE_ID" ]]; then
    echo "  Fehler beim Import von: $rel_file"
    echo "Antwort:"
    echo "$PAGE_RESP" | jq . 2>/dev/null || echo "$PAGE_RESP"
    exit 1
  fi

  echo "  Seite erstellt (ID: $PAGE_ID)"
  ((import_count+=1))
done < <(find "$IMPORT_DIR" -type f \( -iname "*.md" -o -iname "*.markdown" \) | sort)

echo
echo "🎉 Fertig!"
echo "📚 Buch-ID: $BOOK_ID"
echo "📝 Importierte Seiten: $import_count"
echo "⏭️  Übersprungene Dateien: $skip_count"
echo
echo "Hinweis:"
echo "- Unterordner wurden als Kapitel angelegt."
echo "- Verschachtelte Unterordner werden als Kapitelname mit Pfad dargestellt (z. B. 'linux/ssh')."
echo "- Bilder/Anhänge in Markdown werden nicht automatisch in BookStack hochgeladen."

