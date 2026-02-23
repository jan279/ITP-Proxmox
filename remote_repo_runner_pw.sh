#!/usr/bin/env bash
# File: remote_repo_runner_pw.sh
#
# - SSH per Passwort (sshpass)
# - Installiert Abhängigkeiten vor dem Clone (apt/dnf/yum/zypper/pacman/apk)
# - Führt 2 Skripte aus (script1 toleriert systemd-timer Konflikt)
# - Packt logs + standardmäßig bookstack*.md (und optional fetch-path / include-globs)
# - Repo-Ordner wird IMMER gelöscht; Workdir optional; Artifact optional löschen
#
# NOTE: --password ist im Prozess/History sichtbar. Besser ohne --password (Prompt).

set -euo pipefail

# ===== DEFAULTS (für deinen Use-Case) =====
DEFAULT_REPO_URL="https://github.com/jan279/ITP-Proxmox.git"
DEFAULT_REF="e28b93090bb6bfad470ed36b24661fa38dbc0f0a" # leer lassen => default branch
DEFAULT_SCRIPT1="create_temp_ssh_user.sh"
DEFAULT_SCRIPT2="export_vm_docs.sh"
DEFAULT_FETCH_PATH=""
DEFAULT_INCLUDE_GLOBS=("bookstack*.md")

usage() {
  cat <<'USAGE'
Usage:
  remote_repo_runner_pw.sh --host <host> --ssh-user <user> [--password <pw>] [options]

Required:
  --host          Server hostname / IP
  --ssh-user      SSH username

Optional (overrides defaults):
  --repo          Git repo clone URL
  --ref           Branch/Tag/Commit (checkout)
  --script1       Pfad im Repo ODER GitHub blob URL
  --script2       Pfad im Repo ODER GitHub blob URL

Other options:
  --port              SSH port (default: 22)
  --out               Lokales Output-Verzeichnis (default: ./remote_artifacts)
  --fetch-path         Relativer Pfad im Repo (Datei/Ordner) ins Artefakt
  --include-glob       Zusätzliches Glob-Muster (kann mehrfach)
  --no-default-globs   Deaktiviert default globs (bookstack*.md)
  --delete-user        Username der remote gelöscht werden soll (default: doku)
  --no-delete          Deaktiviert User-Löschung
  --keep-remote        Kein remote cleanup (debug). Repo-Ordner wird trotzdem entfernt.
  --keep-artifact      Remote Artefakt nach Download nicht löschen
  --accept-new-hostkey StrictHostKeyChecking=accept-new
  --password           Passwort (besser: prompt)
  --no-install-deps    Deps nicht installieren
USAGE
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }

HOST=""
SSH_USER=""
PASSWORD=""
PORT="22"
LOCAL_OUT="./remote_artifacts"
FETCH_PATH="$DEFAULT_FETCH_PATH"
DELETE_USER="doku"
DO_DELETE="1"
KEEP_REMOTE="0"
KEEP_ARTIFACT="0"
ACCEPT_NEW_HOSTKEY="0"
INSTALL_DEPS="1"

REPO_URL="$DEFAULT_REPO_URL"
REF="$DEFAULT_REF"
SCRIPT1="$DEFAULT_SCRIPT1"
SCRIPT2="$DEFAULT_SCRIPT2"

NO_DEFAULT_GLOBS="0"
INCLUDE_GLOBS=()

is_github_blob_url() {
  [[ "$1" =~ ^https://github\.com/[^/]+/[^/]+/blob/[^/]+/.+ ]]
}

parse_github_blob_url() {
  local url="$1"
  local rest="${url#https://github.com/}"
  local owner="${rest%%/*}"; rest="${rest#*/}"
  local repo="${rest%%/*}"; rest="${rest#*/}"
  rest="${rest#blob/}"
  local ref="${rest%%/*}"
  local path="${rest#*/}"
  echo "REPO_URL=https://github.com/${owner}/${repo}.git"
  echo "REF=${ref}"
  echo "PATH=${path}"
}

normalize_inputs() {
  local derived_repo=""
  local derived_ref=""

  for varname in SCRIPT1 SCRIPT2; do
    local v="${!varname}"
    if is_github_blob_url "$v"; then
      local p u r pa
      p="$(parse_github_blob_url "$v")"
      u="$(awk -F= '/^REPO_URL=/{print $2}' <<<"$p")"
      r="$(awk -F= '/^REF=/{print $2}' <<<"$p")"
      pa="$(awk -F= '/^PATH=/{print $2}' <<<"$p")"
      printf -v "$varname" '%s' "$pa"

      if [[ -z "$derived_repo" ]]; then
        derived_repo="$u"
        derived_ref="$r"
      else
        [[ "$derived_repo" == "$u" ]] || { echo "Error: script URLs refer to different repos." >&2; exit 2; }
        [[ "$derived_ref" == "$r" ]] || { echo "Error: script URLs refer to different refs." >&2; exit 2; }
      fi
    fi
  done

  if [[ -n "$derived_repo" && "$REPO_URL" == "$DEFAULT_REPO_URL" ]]; then
    REPO_URL="$derived_repo"
  fi
  if [[ -n "$derived_ref" && "$REF" == "$DEFAULT_REF" ]]; then
    REF="$derived_ref"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="${2:-}"; shift 2 ;;
    --ssh-user) SSH_USER="${2:-}"; shift 2 ;;
    --password) PASSWORD="${2:-}"; shift 2 ;;
    --port) PORT="${2:-}"; shift 2 ;;
    --out) LOCAL_OUT="${2:-}"; shift 2 ;;
    --fetch-path) FETCH_PATH="${2:-}"; shift 2 ;;
    --include-glob) INCLUDE_GLOBS+=("${2:-}"); shift 2 ;;
    --no-default-globs) NO_DEFAULT_GLOBS="1"; shift 1 ;;
    --delete-user) DELETE_USER="${2:-}"; shift 2 ;;
    --no-delete) DO_DELETE="0"; shift 1 ;;
    --keep-remote) KEEP_REMOTE="1"; shift 1 ;;
    --keep-artifact) KEEP_ARTIFACT="1"; shift 1 ;;
    --accept-new-hostkey) ACCEPT_NEW_HOSTKEY="1"; shift 1 ;;
    --no-install-deps) INSTALL_DEPS="0"; shift 1 ;;
    --repo) REPO_URL="${2:-}"; shift 2 ;;
    --ref) REF="${2:-}"; shift 2 ;;
    --script1) SCRIPT1="${2:-}"; shift 2 ;;
    --script2) SCRIPT2="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

if [[ -z "$HOST" || -z "$SSH_USER" ]]; then
  echo "Error: missing required args --host and/or --ssh-user" >&2
  usage
  exit 2
fi

need_cmd sshpass
need_cmd ssh
need_cmd scp

normalize_inputs
mkdir -p "$LOCAL_OUT"

if [[ -z "$PASSWORD" ]]; then
  read -r -s -p "SSH password for ${SSH_USER}@${HOST}: " PASSWORD
  echo
fi
export SSHPASS="$PASSWORD"

NEED_PYTHON="0"
[[ "$SCRIPT1" == *.py || "$SCRIPT2" == *.py ]] && NEED_PYTHON="1"

SSH_OPTS=(-p "$PORT")
SSH_OPTS+=(-o PreferredAuthentications=password -o PubkeyAuthentication=no)
SSH_OPTS+=(-o BatchMode=no)
SSH_OPTS+=(-o ServerAliveInterval=15 -o ServerAliveCountMax=3)
if [[ "$ACCEPT_NEW_HOSTKEY" == "1" ]]; then
  SSH_OPTS+=(-o StrictHostKeyChecking=accept-new)
fi

# Deterministischer Remote-Ordnername (keine wirren Zahlen am Ende)
# Ersetzt Punkte im Host durch Unterstriche und entfernt sonstige Nicht-Alnum
REMOTE_BASENAME="repo_run_${SSH_USER}_$(echo "$HOST" | tr . _ | tr -cd '[:alnum:]_')"
REMOTE_ARTIFACT_DIR="/tmp/${REMOTE_BASENAME}"

SER_GLOBS=""
if [[ "$NO_DEFAULT_GLOBS" == "0" ]]; then
  for g in "${DEFAULT_INCLUDE_GLOBS[@]}"; do SER_GLOBS+="$g"$'\n'; done
fi
for g in "${INCLUDE_GLOBS[@]}"; do SER_GLOBS+="$g"$'\n'; done

REMOTE_OUTPUT="$(
  sshpass -e ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" \
    "REPO_URL=$(printf %q "$REPO_URL") \
     REF=$(printf %q "$REF") \
     SCRIPT1=$(printf %q "$SCRIPT1") \
     SCRIPT2=$(printf %q "$SCRIPT2") \
     FETCH_PATH=$(printf %q "$FETCH_PATH") \
     DELETE_USER=$(printf %q "$DELETE_USER") \
     DO_DELETE=$(printf %q "$DO_DELETE") \
     KEEP_REMOTE=$(printf %q "$KEEP_REMOTE") \
    REMOTE_ARTIFACT_DIR=$(printf %q "$REMOTE_ARTIFACT_DIR") \
     NEED_PYTHON=$(printf %q "$NEED_PYTHON") \
     INSTALL_DEPS=$(printf %q "$INSTALL_DEPS") \
     SER_GLOBS=$(printf %q "$SER_GLOBS") \
     bash -s" <<'REMOTE_EOF'
set -euo pipefail

have_cmd() { command -v "$1" >/dev/null 2>&1; }

as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo -n "$@"
  fi
}

detect_pm() {
  if have_cmd apt-get; then echo apt; return; fi
  if have_cmd dnf; then echo dnf; return; fi
  if have_cmd yum; then echo yum; return; fi
  if have_cmd zypper; then echo zypper; return; fi
  if have_cmd pacman; then echo pacman; return; fi
  if have_cmd apk; then echo apk; return; fi
  echo ""
}

install_deps() {
  local pm="$1"
  local need_python="$2"
  local pkgs=(git tar gzip ca-certificates findutils)

  if [[ "$need_python" == "1" ]]; then
    case "$pm" in
      pacman) pkgs+=(python) ;;
      *) pkgs+=(python3) ;;
    esac
  fi

  case "$pm" in
    apt)
      as_root apt-get update -y
      as_root apt-get install -y "${pkgs[@]}"
      ;;
    dnf) as_root dnf -y install "${pkgs[@]}" ;;
    yum) as_root yum -y install "${pkgs[@]}" ;;
    zypper)
      as_root zypper --non-interactive refresh
      as_root zypper --non-interactive install -y "${pkgs[@]}"
      ;;
    pacman) as_root pacman -Sy --noconfirm "${pkgs[@]}" ;;
    apk) as_root apk add --no-cache "${pkgs[@]}" ;;
    *) echo "REMOTE_ERROR: no supported package manager found." >&2; exit 10 ;;
  esac
}

cleanup_tempuser_timer() {
  local u="$1"
  local base="delete-tempuser-${u}"

  have_cmd systemctl || return 0

  systemctl stop "${base}.timer" "${base}.service" >/dev/null 2>&1 || true
  systemctl reset-failed "${base}.timer" "${base}.service" >/dev/null 2>&1 || true

  # Transient units liegen oft in /run/systemd/transient
  rm -f "/run/systemd/transient/${base}.timer" "/run/systemd/transient/${base}.service" >/dev/null 2>&1 || true

  systemctl daemon-reload >/dev/null 2>&1 || true
}

if [[ "${INSTALL_DEPS}" == "1" ]]; then
  pm="$(detect_pm)"
  [[ -n "$pm" ]] || { echo "REMOTE_ERROR: cannot detect package manager; install git manually." >&2; exit 10; }

  if ! have_cmd git || ! have_cmd tar || ! have_cmd gzip || ! have_cmd find || { [[ "$NEED_PYTHON" == "1" ]] && ! have_cmd python3 && ! have_cmd python; }; then
    if [[ "$(id -u)" -ne 0 ]]; then
      have_cmd sudo || { echo "REMOTE_ERROR: need root/sudo to install deps, but sudo missing." >&2; exit 10; }
      sudo -n true >/dev/null 2>&1 || { echo "REMOTE_ERROR: need passwordless sudo (sudo -n) to install deps." >&2; exit 10; }
    fi
    install_deps "$pm" "$NEED_PYTHON"
  fi
fi

have_cmd git || { echo "REMOTE_ERROR: missing command: git" >&2; exit 10; }

workdir="$(mktemp -d /tmp/repo_runner.XXXXXX)"
repodir="$workdir/repo"
logdir="$workdir/logs"
mkdir -p "$logdir"

cleanup() {
  if [[ "${KEEP_REMOTE}" == "1" ]]; then
    echo "REMOTE_INFO: keeping remote workdir (except repo dir): $workdir" >&2
    return 0
  fi
  rm -rf "$workdir" || true
}
trap cleanup EXIT

# Clone + optional checkout REF
if [[ -n "${REF}" ]]; then
  git clone "${REPO_URL}" "$repodir" 2>&1 | tee "$logdir/git_clone.log"
  (cd "$repodir" && git checkout -f "${REF}") 2>&1 | tee -a "$logdir/git_checkout.log"
else
  git clone --depth 1 "${REPO_URL}" "$repodir" 2>&1 | tee "$logdir/git_clone.log"
fi

run_any() {
  local rel="$1"
  local abs="$repodir/$rel"
  [[ -e "$abs" ]] || { echo "REMOTE_ERROR: script not found: $rel" >&2; exit 11; }

  local base out
  base="$(basename "$rel")"
  out="$logdir/run_${base}.log"

  if [[ "$abs" == *.py ]]; then
    if have_cmd python3; then (cd "$repodir" && python3 "$abs") 2>&1 | tee "$out"
    else (cd "$repodir" && python "$abs") 2>&1 | tee "$out"
    fi
  else
    (cd "$repodir" && bash "$abs") 2>&1 | tee "$out"
  fi
}

run_script1_tolerant() {
  local rel="$1"
  local abs="$repodir/$rel"
  [[ -e "$abs" ]] || { echo "REMOTE_ERROR: script not found: $rel" >&2; exit 11; }

  local base out rc
  base="$(basename "$rel")"
  out="$logdir/run_${base}.log"

  cleanup_tempuser_timer "$DELETE_USER"

  set +e
  (cd "$repodir" && bash "$abs") 2>&1 | tee "$out"
  rc=${PIPESTATUS[0]}
  set -e

  if [[ "$rc" -ne 0 ]]; then
    # Timer-Kollision ist für uns nicht fatal, weil wir am Ende sofort löschen
    if grep -qiE 'Failed to start transient timer unit|already loaded or has a fragment file' "$out"; then
      echo "REMOTE_WARN: systemd timer conflict ignored; wrapper deletes user immediately at end." | tee -a "$out"
      return 0
    fi
    return "$rc"
  fi
}

# SCRIPT1: tolerant (systemd-timer Konflikt killt den Run nicht)
run_script1_tolerant "$SCRIPT1"

# SCRIPT2: normal (soll hart fehlschlagen, wenn Export kaputt ist)
run_any "$SCRIPT2"

# Sofort: Timer weg, User weg
cleanup_tempuser_timer "$DELETE_USER"

if [[ "${DO_DELETE}" == "1" ]]; then
  if id -u "$DELETE_USER" >/dev/null 2>&1; then
    echo "REMOTE_INFO: deleting user immediately: $DELETE_USER" | tee -a "$logdir/user_delete.log"
    if [[ "$(id -u)" -eq 0 ]]; then
      pkill -u "$DELETE_USER" 2>&1 | tee -a "$logdir/user_delete.log" || true
      userdel -r "$DELETE_USER" 2>&1 | tee -a "$logdir/user_delete.log"
    else
      sudo -n pkill -u "$DELETE_USER" 2>&1 | tee -a "$logdir/user_delete.log" || true
      sudo -n userdel -r "$DELETE_USER" 2>&1 | tee -a "$logdir/user_delete.log"
    fi
  fi
fi

  artifact_tmp="$workdir/artifact_payload"
  mkdir -p "$artifact_tmp/logs" "$artifact_tmp/files"
  cp -a "$logdir/." "$artifact_tmp/logs/"

# fetch-path (Datei oder Ordner)
if [[ -n "${FETCH_PATH}" ]]; then
  src="$repodir/$FETCH_PATH"
  if [[ -e "$src" ]]; then
    mkdir -p "$artifact_tmp/fetch"
    cp -a "$src" "$artifact_tmp/fetch/"
  else
    echo "REMOTE_WARN: fetch-path not found: $FETCH_PATH" | tee -a "$artifact_tmp/logs/fetch.log"
  fi
fi

# include globs (default: bookstack*.md)
included=0
if [[ -n "${SER_GLOBS}" ]]; then
  while IFS= read -r glob; do
    [[ -n "$glob" ]] || continue
    while IFS= read -r -d '' f; do
      rel="${f#$repodir/}"
      mkdir -p "$artifact_tmp/files/$(dirname "$rel")"
      cp -a "$f" "$artifact_tmp/files/$rel"
      included=$((included+1))
    done < <(find "$repodir" -type f -name "$glob" -print0 2>/dev/null || true)
  done <<< "${SER_GLOBS}"
fi
  echo "REMOTE_INFO: included_files_count=${included}" | tee -a "$artifact_tmp/logs/include_files.log"

  # Kein Archiv mehr: lege statisches Remote-Verzeichnis an und kopiere Inhalte
  rm -rf "$REMOTE_ARTIFACT_DIR" || true
  mkdir -p "$REMOTE_ARTIFACT_DIR"
  cp -a "$artifact_tmp/." "$REMOTE_ARTIFACT_DIR/"

  # Repo-Ordner IMMER sofort weg
  rm -rf "$repodir" || true

  echo "ARTIFACT_DIR=$REMOTE_ARTIFACT_DIR"
REMOTE_EOF
)" || {
  echo "Error: remote run failed." >&2
  echo "$REMOTE_OUTPUT" >&2
  exit 1
}

artifact_dir="$(printf '%s\n' "$REMOTE_OUTPUT" | awk -F= '/^ARTIFACT_DIR=/{print $2; exit}')"
if [[ -z "$artifact_dir" ]]; then
  echo "Error: could not parse ARTIFACT_DIR from remote output." >&2
  echo "$REMOTE_OUTPUT" >&2
  exit 1
fi

echo "$REMOTE_OUTPUT" > "${LOCAL_OUT}/remote_session_${REMOTE_BASENAME}.log"

echo "Downloading artifact directory: $artifact_dir"
sshpass -e scp -r -P "$PORT" -o PreferredAuthentications=password -o PubkeyAuthentication=no \
  ${ACCEPT_NEW_HOSTKEY:+-o StrictHostKeyChecking=accept-new} \
  "${SSH_USER}@${HOST}:${artifact_dir}" "${LOCAL_OUT}/" >/dev/null

if [[ "$KEEP_ARTIFACT" != "1" ]]; then
  sshpass -e ssh "${SSH_OPTS[@]}" "${SSH_USER}@${HOST}" "rm -rf $(printf %q "$artifact_dir")" >/dev/null || true
fi

echo "Saved:"
echo "  ${LOCAL_OUT}/${REMOTE_BASENAME}/"
echo "Look:"
echo "  ${LOCAL_OUT}/${REMOTE_BASENAME}/files/ (bookstack*.md)"
echo "  ${LOCAL_OUT}/${REMOTE_BASENAME}/logs/  (logs)"
