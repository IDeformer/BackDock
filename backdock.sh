#!/usr/bin/env bash
###############################################################################
# BackDock — интерактивный бэкап/восстановление docker-контейнеров
# (Remnawave-ready). Запускается на локальном ПК, серверы по SSH.
###############################################################################
set -o pipefail

BASE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="1"

# ── вывод ────────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; B=$'\033[36m'; BO=$'\033[1m'; N=$'\033[0m'
else
  G=""; Y=""; R=""; B=""; BO=""; N=""
fi
info(){ printf '%s::%s %s\n'  "$B" "$N" "$*"; }
ok(){   printf '%s✅%s %s\n'  "$G" "$N" "$*"; }
warn(){ printf '%s⚠️ %s%s\n'  "$Y" "$N" "$*" >&2; }
die(){  printf '%s❌ ОШИБКА:%s %s\n' "$R" "$N" "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }
hr(){   printf '%s----------------------------------------------%s\n' "$BO" "$N"; }
q(){    printf "'%s'" "${1//\'/\'\\\'\'}"; }
pause_(){ read -rp $'\n⏎ Enter для продолжения... ' _; }

hsize_kb(){
  local kb=$1
  if [ -z "$kb" ] || [ "$kb" = 0 ]; then echo "—"; return; fi
  numfmt --to=iec-i --suffix=B $(( kb*1024 )) 2>/dev/null || echo "${kb}KiB"
}

# ══════════════════════════ КОНФИГ ═══════════════════════════════════════════
CONF="$BASE/config.conf"

write_default_config(){
cat > "$CONF" <<'CFG'
# ===================== BackDock :: конфигурация =====================
# Можно править руками или через меню «Управление серверами».

# --- Список серверов (ssh-алиасы из ~/.ssh/config) ---
SERVERS=()

# --- Куда складывать бэкапы (относительный путь = от папки скрипта) ---
BACKUP_ROOT=backups

# --- Контейнеры, считающиеся "набором Remnawave" (кнопка r при выборе) ---
REMNAWAVE_PRESET='remna|caddy|postgres|xray|nginx'

# --- Системные пути, снимаемые дополнительно (разделитель :) ---
# /etc/ufw добавлен намеренно: без него после восстановления на новом
# сервере все открытые порты (443, 8443, 8444, 8388, 8080, 2087, 9443-9448
# и т.д. — VLESS/Reality/XHTTP/Hysteria/Shadowsocks/каскадные bridge-порты)
# придётся открывать заново руками, иначе VPN не заработает даже если
# все контейнеры поднялись.
SYS_PATHS="/var/www:/etc/letsencrypt:/root/.acme.sh:/etc/nginx:/etc/cron.d:/var/spool/cron:/etc/systemd/system:/etc/ufw"

# --- Сохранять ли Docker-образы в архив? ---
# 0 = нет  (при восстановлении образы скачаются заново из registry)
# 1 = да   (docker save; архив вырастет, но восстановление работает офлайн
#           И, что важнее для Remnawave, восстанавливает ТОЧНО ТУ ЖЕ версию
#           панели/ноды, а не текущий :latest/:3 из registry — если между
#           бэкапом и восстановлением вышло major-обновление с breaking
#           changes в API (как было при переходе v2.x -> v3.x), пулл свежего
#           образа при восстановлении может привести к несовместимости)
# По умолчанию 1 — для инфраструктуры Remnawave это не опция, а страховка.
SAVE_IMAGES=1

# --- Транспорт ---
# auto       : rsync если есть на обеих сторонах, иначе ssh+cat
# force-cat  : всегда ssh+cat
TRANSFER=auto
INSTALL_RSYNC=1        # пробовать установить rsync локально, если нет

# --- Поведение бэкапа ---
PAUSE_CONTAINERS=0     # 1 = Docker Pause контейнеров во время снятия томов
KEEP_BACKUPS=0         # сколько последних архивов хранить на хост (0 = все)

# --- SSH ---
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=12 -o ServerAliveInterval=15)
CFG
}

if [ ! -f "$CONF" ]; then
  write_default_config
  warn "config.conf не найден -> создан с настройками по умолчанию"
fi
# shellcheck disable=SC1090
source "$CONF"

BACKUP_ROOT="${BACKUP_ROOT:-backups}"
case "$BACKUP_ROOT" in /*) ;; *) BACKUP_ROOT="$BASE/${BACKUP_ROOT#/}";; esac
REMNAWAVE_PRESET="${REMNAWAVE_PRESET:-remna|caddy|postgres|xray|nginx}"
SYS_PATHS="${SYS_PATHS:-/var/www:/etc/letsencrypt:/root/.acme.sh:/etc/nginx:/etc/cron.d:/var/spool/cron:/etc/systemd/system}"
TRANSFER="${TRANSFER:-auto}"; INSTALL_RSYNC="${INSTALL_RSYNC:-1}"
PAUSE_CONTAINERS="${PAUSE_CONTAINERS:-0}"; KEEP_BACKUPS="${KEEP_BACKUPS:-0}"
SAVE_IMAGES="${SAVE_IMAGES:-0}"

SERVERS=("${SERVERS[@]}")
# ВАЖНО: SSH_OPTS уже загружен из config.conf (source "$CONF" выше) —
# раньше эта строка молча затирала пользовательские опции, включая
# ServerAliveInterval, что могло рвать долгие SQL-дампы/передачи на слабых каналах.
# Подстрахуемся на случай старого config.conf без SSH_OPTS:
if [ "${#SSH_OPTS[@]}" -eq 0 ]; then
  SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=12 -o ServerAliveInterval=15)
fi
SSH_STR="${SSH_OPTS[*]}"
RSYNC_LOCAL=0
declare -A RS_REMOTE=()

servers_list_str(){
  local out="" s
  for s in "${SERVERS[@]}"; do [ -n "$s" ] && out+="\"$s\" "; done
  printf '%s' "${out% }"
}
save_servers(){
  sed -i "s|^SERVERS=.*|SERVERS=($(servers_list_str))|" "$CONF"
}

# ═══════════════ rsync / транспорт ═══════════════════════════════════════════
try_install_rsync(){
  local mgr=""
  for c in apt-get dnf yum pacman zypper apk; do
    if have "$c"; then mgr=$c; break; fi
  done
  case "$mgr" in
    "")      return 1;;
    apt-get) sudo apt-get update -qq 2>/dev/null || true; sudo apt-get install -y rsync;;
    dnf)     sudo dnf install -y rsync;;
    yum)     sudo yum install -y rsync;;
    pacman)  sudo pacman -S --noconfirm --needed rsync;;
    zypper)  sudo zypper --non-interactive install rsync;;
    apk)     sudo apk add rsync;;
  esac
}
ensure_local_rsync(){
  if have rsync; then RSYNC_LOCAL=1; return; fi
  [ "$TRANSFER" = force-cat ] && return
  info "локального rsync нет"
  if [ "$INSTALL_RSYNC" = 1 ]; then
    if try_install_rsync && have rsync; then RSYNC_LOCAL=1; ok "rsync установлен"; fi
  fi
  if [ "$RSYNC_LOCAL" = 0 ]; then warn "работаем по ssh+cat (без прогресс-бара)"; fi
}
remote_transport_mode(){
  local h="$1"
  if [ "$TRANSFER" = force-cat ] || [ "$RSYNC_LOCAL" = 0 ]; then RS_REMOTE[$h]=0; return; fi
  if ssh "${SSH_OPTS[@]}" "$h" 'command -v rsync >/dev/null 2>&1'; then RS_REMOTE[$h]=1
  else RS_REMOTE[$h]=0; fi
}
transport_label(){
  if [ "${RS_REMOTE[$1]:-0}" = 1 ]; then echo "rsync 📡"; else echo "ssh+cat 🐈"; fi
}
fetch_file(){
  if [ "${RS_REMOTE[$1]:-0}" = 1 ]; then
    rsync -azP --partial -e "ssh $SSH_STR" -- "$1:$2" "$3"
  else
    ssh "${SSH_OPTS[@]}" "$1" "cat $(q "$2")" > "$3"
  fi
}
push_file(){
  if [ "${RS_REMOTE[$2]:-0}" = 1 ]; then
    rsync -azP --partial -e "ssh $SSH_STR" -- "$1" "$2:$3"
  else
    ssh "${SSH_OPTS[@]}" "$2" "mkdir -p \$(dirname $(q "$3")) && cat > $(q "$3")" < "$1"
  fi
}

preflight(){
  have ssh || die "нет ssh-клиента"
  have tar || die "нет tar"
  have sha256sum || warn "нет sha256sum — контрольные суммы сверяться не будут"
  ensure_local_rsync
}

ssh_ok(){ ssh "${SSH_OPTS[@]}" "$1" true 2>/dev/null; }

probe_wrap(){
  ssh "${SSH_OPTS[@]}" "$1" '
    if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then exit 0; fi
    if command -v sudo >/dev/null 2>&1 && sudo -n docker ps >/dev/null 2>&1; then echo sudo; exit 0; fi
    exit 8' 2>/dev/null
}
rw_of(){ if [ "$1" = "sudo" ]; then printf 'sudo -n '; else printf ''; fi }

expand_tokens(){
  local total=$1 tok a b; shift
  for tok in "$@"; do
    case "$tok" in
      all|ALL|a|A|все) seq 1 "$total";;
      *-*) a=${tok%-*}; b=${tok#*-}
           if [[ "$a" =~ ^[0-9]+$ ]] && [[ "$b" =~ ^[0-9]+$ ]]; then seq "$a" "$b"; fi;;
      *)   [[ "$tok" =~ ^[0-9]+$ ]] && (( tok>=1 && tok<=total )) && echo "$tok";;
    esac
  done | sort -nu
}

pick_editor(){
  EDIT=""
  local e
  for e in "$EDITOR" nano vi vim micro; do
    [ -z "$e" ] && continue
    if have "$e"; then EDIT=$e; break; fi
  done
}

# ═══ ПЭЙЛОД: СПИСОК КОНТЕЙНЕРОВ + РАЗМЕРЫ ════════════════════════════════════
# вывод: name|image|project|size_kb
read -r -d '' PAYLOAD_PS <<'REMOTE_PS' || true
set -uo pipefail
if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then DOCK=(docker)
elif command -v sudo >/dev/null 2>&1 && sudo -n docker ps >/dev/null 2>&1; then DOCK=(sudo -n docker)
else echo "__NO_DOCKER__"; exit 0; fi

is_tmp(){ case "$1" in /dev|/dev/*|/tmp|/tmp/*|/run|/run/*|/var/run|/var/run/*|/proc|/proc/*|/sys|/sys/*) return 0;; *) return 1;; esac; }

"${DOCK[@]}" ps --format '{{.Names}}' | while IFS= read -r nname; do
  img=$("${DOCK[@]}" inspect -f '{{.Config.Image}}' "$nname" 2>/dev/null)
  pj=$("${DOCK[@]}" inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$nname" 2>/dev/null)
  sz=0
  while IFS='|' read -r mt mn ms; do
    [ -n "${mt:-}" ] || continue
    case "$mt" in
      volume) [ -n "$mn" ] && [ "$mn" != "-" ] || continue
              d="/var/lib/docker/volumes/$mn/_data" ;;
      bind)   d="$ms" ;;
      *) continue ;;
    esac
    is_tmp "$d" && continue
    if [ -d "$d" ]; then
      k=$(du -sk "$d" 2>/dev/null | cut -f1)
      [ -n "$k" ] && sz=$((sz+k))
    fi
  done < <("${DOCK[@]}" inspect -f '{{range .Mounts}}{{.Type}}|{{with .Name}}{{.}}{{else}}-{{end}}|{{.Source}}{{"\n"}}{{end}}' "$nname")
  printf '%s|%s|%s|%s\n' "$nname" "$img" "${pj:-}" "$sz"
done
echo "__PS_DONE__"
REMOTE_PS

# ═══ ПЭЙЛОД: БЭКАП ═══════════════════════════════════════════════════════════
# Аргументы: $1 контейнеры, $2 системные пути(:), $3 pause, $4 save_images
read -r -d '' PAYLOAD_BK <<'REMOTE_BK' || true
set -uo pipefail
HN=$(hostname -s | tr -c 'A-Za-z0-9._-' '_')
say(){ echo "  [$HN] $*"; }
CONTAINERS="${1:-}"; EXTRA="${2:-}"; PAUSE="${3:-0}"; SVIMG="${4:-0}"
[ -n "$CONTAINERS" ] || { say "список контейнеров пуст"; exit 3; }

is_tmp(){ case "$1" in /dev|/dev/*|/tmp|/tmp/*|/run|/run/*|/var/run|/var/run/*|/proc|/proc/*|/sys|/sys/*) return 0;; *) return 1;; esac; }

W=$(mktemp -d "/tmp/backdock.XXXXXX") || { say "mktemp не удался"; exit 3; }
cleanup(){ docker unpause $PAUSED_LIST >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT
PAUSED_LIST=""
mkdir -p "$W/meta" "$W/volumes" "$W/db"
: > "$W/meta/projects.tsv"; : > "$W/meta/containers.tsv"
: > "$W/meta/volnames.txt"; : > "$W/meta/syspaths_present.txt"
: > "$W/meta/mounts_all.tsv"

cp_abs(){
  local s=$1
  local d="$W/rootfs$s"
  [ -e "$s" ] || return 0
  mkdir -p "$(dirname "$d")"
  cp -a "$s" "$d" 2>/dev/null || say "WARN пропущен путь $s"
}
is_pg(){ case "$1" in *postgres*|*timescale*) return 0;; *) return 1;; esac; }
IS_ROOT=$(id -u); TARIMG=""

echo "PROGRESS 🚚 шаг 1/6 контейнеры, файлы проектов, bind-mounts"
declare -A SEEN
for C in $CONTAINERS; do
  if ! docker inspect "$C" >/dev/null 2>&1; then say "контейнер $C исчез"; continue; fi
  say "контейнер $C"
  docker inspect "$C" > "$W/meta/container_${C}.json"
  docker logs --tail 200 "$C" > "$W/meta/logs_${C}.txt" 2>&1 || true
  img=$(docker inspect  -f '{{.Config.Image}}' "$C")
  proj=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$C" 2>/dev/null)
  svc=$(docker inspect  -f '{{index .Config.Labels "com.docker.compose.service"}}' "$C" 2>/dev/null)
  wd=$(docker inspect   -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$C" 2>/dev/null)
  cfgf=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$C" 2>/dev/null)
  printf '%s\t%s\t%s\n' "${proj:--}" "$C" "$img" >> "$W/meta/containers.tsv"

  if [ -n "$proj" ] && [ -z "${SEEN[$proj]:-}" ]; then
    SEEN[$proj]=1
    PGS=""
    if [ -n "$wd" ] && [ -d "$wd" ]; then
      cp_abs "$wd"
      say "  папка проекта $wd ($(du -sh "$wd" 2>/dev/null | cut -f1))"
    fi
    OLDIFS=$IFS; IFS=','
    for f in $cfgf; do [ -n "$f" ] && [ -f "$f" ] && cp_abs "$f"; done
    IFS=$OLDIFS
    is_pg "$img" && PGS=$svc
    printf '%s\t%s\t%s\t%s\n' "$proj" "${wd:-}" "${cfgf:-}" "$PGS" >> "$W/meta/projects.tsv"
  fi

  docker inspect -f '{{range .Mounts}}{{.Type}}|{{with .Name}}{{.}}{{else}}-{{end}}|{{.Source}}|{{.Destination}}{{"\n"}}{{end}}' "$C" |
  while IFS='|' read -r mt mn ms md; do
    [ -n "$md" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$C" "$mt" "$mn" "$ms" "$md" >> "$W/meta/mounts_all.tsv"
    case "$mt" in
      bind)
        if is_tmp "$ms"; then
          say "  bind $ms → $md (временный — пропущен)"
        else
          say "  bind $ms → $md"
          cp_abs "$ms"
        fi ;;
      volume)
        [ -n "$mn" ] && [ "$mn" != "-" ] && { say "  volume $mn"; echo "$mn" >> "$W/meta/volnames.txt"; } ;;
    esac
  done
done
sort -u "$W/meta/volnames.txt" -o "$W/meta/volnames.txt"

if [ "$PAUSE" = 1 ]; then
  say "пауза контейнеров..."
  if Docker Pause $CONTAINERS >/dev/null 2>&1; then PAUSED_LIST="$CONTAINERS"; else say "pause не удался - продолжаю"; fi
fi

echo "PROGRESS 📦 шаг 2/6 тома ($(wc -l < "$W/meta/volnames.txt"))"
while read -r V; do
  [ -n "$V" ] || continue
  say "том $V"
  if [ "$IS_ROOT" = 0 ]; then
    D="/var/lib/docker/volumes/$V/_data"
    if [ -d "$D" ]; then tar -czf "$W/volumes/$V.tgz" -C "$D" . 2>/dev/null || say "WARN том $V недоступен"
    else say "WARN том $V нет пути"; fi
  else
    if [ -z "$TARIMG" ]; then
      for cand in alpine busybox "$(awk -F'\t' 'NR==1{print $3}' "$W/meta/containers.tsv")"; do
        if [ -n "$cand" ] && docker image inspect "$cand" >/dev/null 2>&1; then TARIMG=$cand; break; fi
      done
    fi
    if [ -n "$TARIMG" ]; then
      docker run --rm -e VN="$V" -v "$V":/from:ro -v "$W/volumes":/to \
        --entrypoint sh "$TARIMG" -c 'tar czf "/to/$VN.tgz" -C /from .' 2>/dev/null \
        || say "WARN том $V пропущен"
    else
      say "WARN нет образа с tar для снятия тома $V"
    fi
  fi
done < "$W/meta/volnames.txt"
if [ -n "$PAUSED_LIST" ]; then docker unpause $PAUSED_LIST >/dev/null 2>&1; PAUSED_LIST=""; say "снята пауза"; fi

echo "PROGRESS 🖼 шаг 3/6 образы (save_images=$SVIMG)"
IMG_TOTAL_K=0
if [ "$SVIMG" = 1 ]; then
  mkdir -p "$W/images"
  : > "$W/meta/images.txt"
  declare -A IDONE
  for C in $CONTAINERS; do
    IMGE=$(docker inspect -f '{{.Config.Image}}' "$C" 2>/dev/null) || continue
    [ -n "$IMGE" ] || continue
    [ -z "${IDONE[$IMGE]:-}" ] || continue
    IDONE[$IMGE]=1
    SFN="img_$(printf '%s' "$IMGE" | tr '/:@' '_').tar.gz"
    say "образ $IMGE"
    if docker save "$IMGE" 2>/dev/null | gzip -1 > "$W/images/$SFN" && [ -s "$W/images/$SFN" ]; then
      KB=$(du -sk "$W/images/$SFN" | cut -f1)
      IMG_TOTAL_K=$((IMG_TOTAL_K+KB))
      printf '%s\n' "$IMGE" >> "$W/meta/images.txt"
    else
      rm -f "$W/images/$SFN"; say "WARN образ $IMGE пропущен"
    fi
  done
else
  say "образы не сохраняются (включается SAVE_IMAGES=1 в config.conf)"
fi

echo "PROGRESS 🗄 шаг 4/6 PostgreSQL"
HAS_PG=$(awk -F'\t' '$4!=""{found=1} END{print found+0}' "$W/meta/projects.tsv")
if [ "$HAS_PG" = 1 ]; then
  while IFS=$'\t' read -r pn pwdir pcfg pgs; do
    [ -z "$pgs" ] && continue
    PGC=""
    for CC in $(docker ps --format '{{.Names}}'); do
      PP=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$CC" 2>/dev/null)
      IM=$(docker inspect -f '{{.Config.Image}}' "$CC" 2>/dev/null)
      if [ "$PP" = "$pn" ] && is_pg "$IM"; then PGC=$CC; break; fi
    done
    if [ -z "$PGC" ]; then say "проект $pn: postgres не найден"; continue; fi
    PU=$(docker exec "$PGC" printenv POSTGRES_USER 2>/dev/null); PU=${PU:-postgres}
    say "pg_dumpall ($PU)"
    if docker exec "$PGC" pg_dumpall -U "$PU" 2>/dev/null | gzip -6 > "$W/db/pg_all.sql.gz" && [ -s "$W/db/pg_all.sql.gz" ]; then
      say "SQL готов ($(du -h "$W/db/pg_all.sql.gz" | cut -f1))"
    else
      say "!! pg_dumpall не удался"; rm -f "$W/db/pg_all.sql.gz"
    fi
    break
  done < "$W/meta/projects.tsv"
else
  say "postgres среди выбранных проектов нет - дамп пропущен"
fi

echo "PROGRESS 🧩 шаг 5/6 системные пути, cron, сети"
OLDIFS=$IFS; IFS=':'
for p in $EXTRA; do
  [ -n "$p" ] || continue
  if [ -e "$p" ]; then echo "$p" >> "$W/meta/syspaths_present.txt"; cp_abs "$p"; else say "нет пути $p"; fi
done
IFS=$OLDIFS
(crontab -l 2>/dev/null || true) > "$W/meta/crontab_root.txt"

# Читаемый дамп правил UFW — на случай если /etc/ufw (бинарные правила)
# не восстановится один-в-один на другой версии iptables-backend.
# Это справочный файл, восстанавливается вручную командами ufw allow.
if command -v ufw >/dev/null 2>&1; then
  (ufw status verbose 2>/dev/null || true) > "$W/meta/ufw_status.txt"
  say "снят справочный дамп ufw status"
fi

NETS=$(docker network ls --format '{{.Name}}' 2>/dev/null | grep -Ev '^(bridge|host|none)$' || true)
if [ -n "$NETS" ]; then
  docker network inspect $NETS > "$W/meta/networks.json" 2>/dev/null || true
  printf '%s\n' "$NETS" > "$W/meta/networks.txt"
  say "сети: $(echo $NETS | tr '\n' ' ')"
fi

echo "PROGRESS 🚀 шаг 6/6 упаковка"
{
  echo "# hostname: $HN"
  echo "# date: $(date +%FT%T%z)"
  echo "# kernel: $(uname -srmo)"
  echo "# docker_server: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  echo "# containers_arg: $CONTAINERS"
  echo "# save_images: $SVIMG"
  echo "--- docker ps -a ---"
  docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
  echo "--- projects (proj|workdir|cfgfiles|pg_service) ---"
  cat "$W/meta/projects.tsv"
  echo "--- mounts (ctr|type|name|src|dst) ---"
  cat "$W/meta/mounts_all.tsv"
  echo "--- images ---"
  cat "$W/meta/images.txt" 2>/dev/null
  echo "--- networks ---"
  cat "$W/meta/networks.txt" 2>/dev/null
  echo "--- ufw status (справочно) ---"
  cat "$W/meta/ufw_status.txt" 2>/dev/null
  echo "--- disk ---"
  df -h 2>/dev/null | head -15
  echo "--- volumes ---"
  ls -la "$W/volumes"
} > "$W/meta/manifest.txt"

sz_dir(){ if [ -d "$1" ]; then du -sk "$1" 2>/dev/null | cut -f1; else echo 0; fi; }
RSZ=$(sz_dir "$W/rootfs")
VSZ=$(sz_dir "$W/volumes")
DSZ=$(sz_dir "$W/db")
echo "COMPONENT_SIZES rootfs=${RSZ}kb volumes=${VSZ}kb sql=${DSZ}kb images=${IMG_TOTAL_K}kb"

FN="/tmp/${HN}_$(date +%Y%m%d-%H%M%S).tar.gz.part"
tar -C "$W" -czf "$FN" . && mv "$FN" "${FN%.part}" || { say "упаковка не удалась"; exit 3; }
FN=${FN%.part}
chmod 600 "$FN"
SIZE=$(stat -c%s "$FN" 2>/dev/null || echo 0)
SHA=$(sha256sum "$FN" 2>/dev/null | awk '{print $1}')
echo "BACKUP_PATH=$FN"
echo "BACKUP_SIZE=$SIZE"
echo "BACKUP_SHA=${SHA:-NONE}"
REMOTE_BK

# ═══ ПЭЙЛОД: RESTORE ═════════════════════════════════════════════════════════
# Аргументы: $1 режим(full|apps|dbless|sys), $2 stop(0|1), $3 рабочая папка
read -r -d '' PAYLOAD_RS <<'REMOTE_RS' || true
set -uo pipefail
DIR="${3:-/root/.dockrestore}"
say(){ echo "  [restore] $*"; }
MODE="${1:-full}"; STOP="${2:-1}"
stamp=$(date +%Y%m%d%H%M%S)
have_apps(){ [ "$MODE" = full ] || [ "$MODE" = apps ] || [ "$MODE" = dbless ]; }

if command -v docker >/dev/null 2>&1 && docker ps >/dev/null 2>&1; then DOCK=(docker)
elif command -v sudo >/dev/null 2>&1 && sudo -n docker ps >/dev/null 2>&1; then DOCK=(sudo -n docker)
else echo "RESTORE_FAILED: docker недоступен"; exit 1; fi

[ -f "$DIR/data.tgz" ] || { echo "RESTORE_FAILED: нет архива в $DIR"; exit 1; }
cd "$DIR" || { echo "RESTORE_FAILED: cd не удался"; exit 1; }
rm -rf meta volumes db rootfs images
echo "PROGRESS 📥 распаковка"
tar -xzf data.tgz || { echo "RESTORE_FAILED: битый архив"; exit 1; }
[ -f meta/manifest.txt ] || { echo "RESTORE_FAILED: это не наш архив"; exit 1; }
head -5 meta/manifest.txt

if ls images/img_*.tar.gz >/dev/null 2>&1; then
  echo "PROGRESS 🖼 загрузка образов"
  for f in images/img_*.tar.gz; do
    say "load $(basename "$f")"
    gunzip -c "$f" | "${DOCK[@]}" load >/dev/null 2>&1 || say "WARN образ $(basename "$f") не загрузился"
  done
fi

if have_apps && [ "$STOP" = 1 ]; then
  say "останов совпадающих проектов"
  while IFS=$'\t' read -r pn pwdir pcfg pgs; do
    if [ -n "${pwdir:-}" ] && [ -d "$pwdir" ]; then
      ( cd "$pwdir" && { "${DOCK[@]}" compose down --remove-orphans || docker-compose down --remove-orphans; } ) >/dev/null 2>&1 || true
      say "  down $pwdir"
    fi
  done < meta/projects.tsv
  "${DOCK[@]}" ps -q 2>/dev/null | while read -r cid; do
    pl=$("${DOCK[@]}" inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$cid" 2>/dev/null)
    if [ -z "$pl" ] || ! cut -f1 meta/projects.tsv | grep -qs "^${pl}$"; then
      "${DOCK[@]}" stop "$cid" >/dev/null 2>&1 || true
    fi
  done
fi

if [ "$MODE" = sys ] || [ "$MODE" = full ]; then
  echo "PROGRESS 🧩 rootfs -> /"
  say "раскладываем rootfs (конфликты сохраняются как *.restobak_$stamp)"
  while read -r f; do
    dst="/${f#./}"
    if [ -e "$dst" ] && ! cmp -s "$dst" "rootfs/$f" 2>/dev/null; then
      cp -a "$dst" "${dst}.restobak_$stamp" 2>/dev/null || true
    fi
  done < <( cd rootfs && find . -mindepth 1 )
  ( cd rootfs && tar cf - . ) | tar xf - -C /
  if [ -s meta/crontab_root.txt ]; then crontab meta/crontab_root.txt && say "cron применён"; fi
  systemctl restart cron 2>/dev/null || service cron restart 2>/dev/null || true
  systemctl daemon-reload 2>/dev/null || true
fi

if have_apps; then
  echo "PROGRESS 📦 тома"
  for f in volumes/*.tgz; do
    [ -e "$f" ] || continue
    V=$(basename "$f" .tgz)
    "${DOCK[@]}" volume inspect "$V" >/dev/null 2>&1 || "${DOCK[@]}" volume create "$V" >/dev/null
    D="/var/lib/docker/volumes/$V/_data"
    say "том $V"
    if [ -d "$D" ] && [ -n "$(ls -A "$D" 2>/dev/null)" ]; then
      mv "$D" "${D}.restobak_$stamp"; mkdir -p "$D"
    elif [ ! -d "$D" ]; then mkdir -p "$D"; fi
    tar -xzf "$f" -C "$D"
  done

  echo "PROGRESS 🗄 SQL"
  PG_ROW=$(awk -F'\t' '$4!=""{print; exit}' meta/projects.tsv 2>/dev/null)
  if [ -n "$PG_ROW" ] && [ -s db/pg_all.sql.gz ]; then
    IFS=$'\t' read -r pn pwdir pcfg pgs <<<"$PG_ROW"
    say "поднимаем Postgres проекта $pn"
    ( cd "$pwdir" && { "${DOCK[@]}" compose up -d "$pgs" || docker-compose up -d "$pgs"; } ) || { echo "RESTORE_FAILED: старт pg"; exit 1; }
    sleep 3
    PGC=""
    for cc in $("${DOCK[@]}" ps --format '{{.Names}}'); do
      im=$("${DOCK[@]}" inspect -f '{{.Config.Image}}' "$cc")
      case "$im" in *postgres*) PGC=$cc; break;; esac
    done
    [ -n "$PGC" ] || { echo "RESTORE_FAILED: pg контейнер не найден"; exit 1; }
    PU=$("${DOCK[@]}" exec "$PGC" printenv POSTGRES_USER 2>/dev/null); PU=${PU:-postgres}
    for i in $(seq 1 45); do "${DOCK[@]}" exec "$PGC" pg_isready -U "$PU" >/dev/null 2>&1 && break; sleep 2; done
    say "импорт pg_all.sql.gz"
    gunzip -c db/pg_all.sql.gz | "${DOCK[@]}" exec -i "$PGC" psql -U "$PU" -q 2>&1 |
      grep -Evi 'already exists|does not exist, skipping|^$' || true
  else
    say "SQL-дампа нет или не нужен - данные берутся из tar томов"
  fi

  echo "PROGRESS ▶️ запуск проектов"
  FAIL=0
  while IFS=$'\t' read -r pn pwdir pcfg pgs; do
    if [ -n "${pwdir:-}" ] && [ -d "$pwdir" ]; then
      say "up $pwdir"
      ( cd "$pwdir" && { "${DOCK[@]}" compose up -d --remove-orphans || docker-compose up -d --remove-orphans; } ) || FAIL=1
    fi
  done < meta/projects.tsv
  sleep 2
  "${DOCK[@]}" ps
  if [ "$FAIL" = 0 ]; then echo RESTORE_COMPLETED; else echo RESTORE_PARTIAL; fi
else
  say "системная часть применена, приложения не трогали"
  echo RESTORE_COMPLETED
fi
rm -rf "$DIR"
REMOTE_RS

# ═══ ГЛАВНОЕ МЕНЮ ════════════════════════════════════════════════════════════
main_menu(){
  while true; do
    NSRV=${#SERVERS[@]}
    clear 2>/dev/null || true
    cat <<MENU
 ${BO}=============================================
🐳 BackDock v$VERSION :: Бэкап / Рестор Docker-стеков
=============================================${N}
Конфиг: config.conf │ Архивы: backups/ │ Серверов: $NSRV │ Образы в архиве: $SAVE_IMAGES

  ${B}1${N}) 📦 Сделать бэкапы
  ${B}2${N}) ♻️ Восстановить из бэкапа
  ${B}3${N}) 📋 Список архивов
  ${B}4${N}) 🖥  Управление серверами
  ${B}5${N}) ⚙️ Открыть настройки (редактор)
  ${B}0${N}) 🚪 Выход
MENU
    read -rp $'\nВыбор: ' m
    case "$m" in
      1) menu_backup ;;
      2) menu_restore ;;
      3) cmd_list; pause_ ;;
      4) menu_servers ;;
      5) pick_editor
         if [ -n "$EDIT" ]; then
           "$EDIT" "$CONF"
           source "$CONF"; SERVERS=("${SERVERS[@]}")
           SAVE_IMAGES="${SAVE_IMAGES:-0}"
           warn "конфиг перечитан"
           sleep 1
         else
           warn "редактор не найден (nano/vi/micro)"; sleep 1
         fi ;;
      0|"q"|"Q") echo "👋 Пока!"; exit 0 ;;
      *) ;;
    esac
  done
}

# ═══ МЕНЮ: СЕРВЕРА ═══════════════════════════════════════════════════════════
menu_servers(){
  while true; do
    NSRV=${#SERVERS[@]}
    clear 2>/dev/null || true
    hr
    echo "${BO}🖥  Серверы: $NSRV${N}"
    hr
    if [ "$NSRV" -eq 0 ]; then
      echo "  (список пуст)"
    else
      i=1
      for s in "${SERVERS[@]}"; do
        if ssh_ok "$s"; then st="${G}🟢 доступен${N}"; else st="${R}🔴 недоступен${N}"; fi
        printf '  %d) %-28s [%b]\n' "$i" "$s" "$st"
        i=$((i+1))
      done
    fi
    cat <<SMSG

  ${B}a${N}) ➕ добавить сервер      ${B}d${N}) ➖ удалить сервер
  ${B}i${N}) ⬇️ импорт из ~/.ssh/config    ${B}0${N}) 🔙 назад
SMSG
    read -rp $'\nВыбор: ' c
    case "$c" in
      a) read -rp "Алиас сервера (как в ~/.ssh/config): " al
         al=$(printf '%s' "$al" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-64)
         if [ -z "$al" ]; then warn "пустой алиас"; sleep 1; continue; fi
         dup=0
         for s in "${SERVERS[@]}"; do [ "$s" = "$al" ] && dup=1; done
         if [ "$dup" = 1 ]; then warn "уже есть в списке"; sleep 1; continue; fi
         if ssh_ok "$al"; then ok "соединение установлено 🤝"
         else warn "подключиться не удалось (добавляю всё равно)"; fi
         SERVERS+=("$al")
         save_servers
         ok "сохранено в config.conf 💾"; sleep 1 ;;
      d) [ "$NSRV" -eq 0 ] && continue
         read -rp "Номер для удаления: " dn
         if [[ "$dn" =~ ^[0-9]+$ ]] && (( dn>=1 && dn<=NSRV )); then
           del="${SERVERS[dn-1]}"
           TMP_ARR=()
           for s in "${SERVERS[@]}"; do [ "$s" = "$del" ] || TMP_ARR+=("$s"); done
           SERVERS=("${TMP_ARR[@]}")
           save_servers
           ok "🗑 «$del» удалён"; sleep 1
         fi ;;
      i) if [ ! -f ~/.ssh/config ]; then warn "~/.ssh/config не найден"; sleep 1; continue; fi
         FOUND=()
         while IFS= read -r h; do FOUND+=("$h"); done < <(
           awk 'tolower($1)=="host"{for(i=2;i<=NF;i++) if($i !~ /[*!?]/) print $i}' ~/.ssh/config \
           | sort -u )
         NFND=${#FOUND[@]}
         if [ "$NFND" -eq 0 ]; then warn "хостов не найдено"; sleep 1; continue; fi
         echo "🔍 Найдено:"
         i=1
         for h in "${FOUND[@]}"; do
           dup=0
           for s in "${SERVERS[@]}"; do [ "$s" = "$h" ] && dup=1; done
           if [ "$dup" = 1 ]; then printf '  %2d) %-30s (уже есть)\n' "$i" "$h"; else printf '  %2d) %s\n' "$i" "$h"; fi
           i=$((i+1))
         done
         read -rp "Импортировать номера («1 3», «1-5», all): "
         IDX=(); while IFS= read -r t; do IDX+=("$t"); done < <(expand_tokens "$NFND" $REPLY)
         [ "${#IDX[@]}" -gt 0 ] || continue
         added=0
         for n in "${IDX[@]}"; do
           h="${FOUND[n-1]}"
           dup=0
           for s in "${SERVERS[@]}"; do [ "$s" = "$h" ] && dup=1; done
           if [ "$dup" = 0 ]; then SERVERS+=("$h"); added=$((added+1)); fi
         done
         save_servers
         ok "➕ добавлено: $added"; sleep 1 ;;
      0|"q") return ;;
    esac
  done
}

# ═══ МЕНЮ: БЭКАП ═════════════════════════════════════════════════════════════
menu_backup(){
  clear 2>/dev/null || true
  hr; echo "${BO}📦 БЭКАП${N}"; hr
  preflight

  NSRV=${#SERVERS[@]}
  if [ "$NSRV" -eq 0 ]; then
    warn "Нет ни одного сервера в конфиге - добавьте через меню «Управление серверами»"
    pause_; return
  fi

  echo "🖥  Серверы из config.conf:"
  i=1
  for s in "${SERVERS[@]}"; do
    if ssh_ok "$s"; then st="${G}🟢${N}"; else st="${R}🔴 недоступен${N}"; fi
    printf '  %d) %-30s [%b]\n' "$i" "$s" "$st"
    i=$((i+1))
  done
  echo "     («all» = все доступные)"

  read -rp $'\nВыберите серверы: '
  HS=()
  if [ "${REPLY// /}" = "all" ]; then
    for s in "${SERVERS[@]}"; do
      if ssh_ok "$s"; then HS+=("$s"); else warn "$s: нет соединения - пропуск"; fi
    done
  else
    IDX=(); while IFS= read -r t; do IDX+=("$t"); done < <(expand_tokens "$NSRV" $REPLY)
    for n in "${IDX[@]}"; do
      s="${SERVERS[n-1]}"
      if ssh_ok "$s"; then HS+=("$s"); else warn "$s: нет соединения - пропуск"; fi
    done
  fi
  if [ "${#HS[@]}" -eq 0 ]; then die "не выбрано ни одного доступного сервера"; fi

  read -rp $'\nDocker Pause на время копирования томов (жёстче консистентность)? y/N: '
  DO_PAUSE=0; [ "${REPLY,,}" = y ] && DO_PAUSE=1

  read -rp $'\n➕ доп. пути через запятую (Enter = только SYS_PATHS из конфига): '
  XIN="${REPLY// /}"
  EFF_EXTRA="$SYS_PATHS"
  if [ -n "${XIN//,/}" ]; then
    EFF_EXTRA="${SYS_PATHS}:${XIN//,/:}"
  fi
  EFF_EXTRA=$(printf '%s' "$EFF_EXTRA" | sed 's/:::*/:/g; s/^://; s/:$//')

  mkdir -p "$BACKUP_ROOT"
  INDEX="$BACKUP_ROOT/index.tsv"
  FAILED=()

  for H in "${HS[@]}"; do
    echo ""; hr; info "🖥  Сервер: $H"
    remote_transport_mode "$H"
    info "🛰  Транспорт: $(transport_label "$H")"

    WRAP="$(probe_wrap "$H")"
    if [ $? -ne 0 ]; then
      warn "$H: Docker недоступен (нужен root или беспарольный sudo)"
      FAILED+=("$H"); continue
    fi
    RW="$(rw_of "$WRAP")"

    PSOUT=$(ssh "${SSH_OPTS[@]}" "$H" "${RW}bash -s" \
            < <(printf '%s\n' "$PAYLOAD_PS") 2>&1)

    if grep -qs '__NO_DOCKER__' <<<"$PSOUT"; then
      warn "$H: Docker не запущен или нет прав ❌"
      FAILED+=("$H"); continue
    fi
    if ! grep -qs '__PS_DONE__' <<<"$PSOUT"; then
      warn "$H: Не удалось получить список контейнеров. Ответ сервера:"
      sed 's/^/    /' <<<"${PSOUT:-(пусто)}" | head -5 >&2
      FAILED+=("$H"); continue
    fi
    ROWS=(); while IFS= read -r l; do ROWS+=("$l"); done < <(
      grep -Ev '^(__(PS_DONE|NO_DOCKER)__|[[:space:]]*$)' <<<"$PSOUT" )
    NCNT=${#ROWS[@]}
    if [ "$NCNT" -eq 0 ]; then
      info "🐱 $H: Docker работает, но запущенных контейнеров нет"
      FAILED+=("$H"); continue
    fi

    # таблица: имя|образ|проект|размер
    declare -A CSZ CPRJ
    echo ""
    echo "📦 Контейнеры на $H:"
    i=1
    for l in "${ROWS[@]}"; do
      IFS='|' read -r cn ci cpj csz <<<"$l"
      CSZ[$cn]="${csz:-0}"; CPRJ[$cn]="${cpj:-}"
      printf '  %2d) %-30s %-32s %9s  [%s]\n' "$i" "$cn" "${ci:0:32}" "$(hsize_kb "${csz:-0}")" "${cpj:--}"
      i=$((i+1))
    done

    PRESET_SEL=""; HAS_REMNA=0
    for l in "${ROWS[@]}"; do
      cn=$(cut -d'|' -f1 <<<"$l"); cpj=$(cut -d'|' -f3 <<<"$l")
      if grep -Eqi "$REMNAWAVE_PRESET" <<<"$l"; then
        HAS_REMNA=1
        PRESET_SEL+="$cn "
      fi
    done

    SEL=()
    if [ "$HAS_REMNA" = 1 ]; then
      echo ""
      echo "${G}🌟 Remnawave компоненты: $PRESET_SEL${N}"
    fi
    read -rp $'\nВыбери что бэкапить: 👇\n• Enter = 🌍 ВСЕ (полный бэкап) \n• r = 🌟 Только Remnawave \n• Номера («1 3», «2-4») \n• 0 = 🔙 Назад \n  ➡️  '
    ANS="${REPLY// /}"
    case "$ANS" in
      "")
        for l in "${ROWS[@]}"; do SEL+=("$(cut -d'|' -f1 <<<"$l")"); done ;;
      0|q)
        warn "$H: пропущен"; FAILED+=("$H"); continue ;;
      r|R)
        if [ "$HAS_REMNA" = 1 ]; then SEL=($PRESET_SEL)
        else warn "$H: Remnawave не обнаружен — укажите номера"; FAILED+=("$H"); continue; fi ;;
      a|A|all)
        for l in "${ROWS[@]}"; do SEL+=("$(cut -d'|' -f1 <<<"$l")"); done ;;
      *)
        IDX=(); while IFS= read -r t; do IDX+=("$t"); done < <(expand_tokens "$NCNT" $REPLY)
        if [ "${#IDX[@]}" -eq 0 ]; then warn "$H: неверный ввод"; FAILED+=("$H"); continue; fi
        for n in "${IDX[@]}"; do SEL+=("$(cut -d'|' -f1 <<<"${ROWS[n-1]}")"); done ;;
    esac
    SEL_STR="${SEL[*]}"

    # оценка объёма выбранного (без дублей по compose-проекту)
    EST=0
    declare -A PSEENP
    for name in "${SEL[@]}"; do
      p="${CPRJ[$name]:-}"
      if [ -n "$p" ]; then
        if [ -n "${PSEENP[$p]:-}" ]; then continue; fi
        PSEENP[$p]=1
      fi
      EST=$((EST + ${CSZ[$name]:-0}))
    done
    info "🎯 бэкапим: $SEL_STR"
    info "🧮 оценка данных контейнеров: ~$(hsize_kb "$EST") (+системные пути$( [ "$SAVE_IMAGES" = 1 ] && echo ", +образы"))"

    echo ""
    LINES=$(ssh "${SSH_OPTS[@]}" "$H" \
      "${RW}bash -s $(q "$SEL_STR") $(q "$EFF_EXTRA") $DO_PAUSE $SAVE_IMAGES" \
      < <(printf '%s\n' "$PAYLOAD_BK") 2>&1 | tee /dev/stderr | grep -E '^(BACKUP_PATH|BACKUP_SIZE|BACKUP_SHA|COMPONENT_SIZES)=' ) || true

    BP=$(sed -n 's/^BACKUP_PATH=//p' <<<"$LINES")
    if [ -z "$BP" ]; then warn "$H: бэкап на сервере сорвался 😿"; FAILED+=("$H"); continue; fi
    BSZ=$(sed -n 's/^BACKUP_SIZE=//p' <<<"$LINES")
    SHA_R=$(sed -n 's/^BACKUP_SHA=//p' <<<"$LINES")

    CSLINE=$(sed -n 's/^COMPONENT_SIZES //p' <<<"$LINES")
    if [ -n "$CSLINE" ]; then
      pretty=" 🧮 собрано:"
      for tk in $CSLINE; do
        kk=${tk%%=*}; vv=${tk##*=}; vv=${vv%kb}
        pretty+=" $kk:$(hsize_kb "$vv") │"
      done
      info "${pretty%│}"
    fi

    DEST="$BACKUP_ROOT/$H"; mkdir -p "$DEST"
    FNAME=$(basename "$BP")
    HUM=$(numfmt --to=iec-i --suffix=B "${BSZ:-0}" 2>/dev/null || echo "${BSZ:-?}Б")
    echo ""
    info "⬇️  скачивание архива [$HUM] ($(transport_label "$H"))..."
    rm -f "$DEST/$FNAME.tmp"
    if ! fetch_file "$H" "$BP" "$DEST/$FNAME.tmp"; then
      warn "$H: передача сорвалась"
      ssh "${SSH_OPTS[@]}" "$H" "rm -f $(q "$BP")" 2>/dev/null
      FAILED+=("$H"); continue
    fi
    mv "$DEST/$FNAME.tmp" "$DEST/$FNAME"
    ssh "${SSH_OPTS[@]}" "$H" "rm -f $(q "$BP")" 2>/dev/null
    chmod 600 "$DEST/$FNAME"

    if [ -n "$SHA_R" ] && [ "$SHA_R" != NONE ] && have sha256sum; then
      SHA_L=$(sha256sum "$DEST/$FNAME" | awk '{print $1}')
      if [ "$SHA_R" = "$SHA_L" ]; then ok "checksum OK 🔒"
      else warn "checksum MISMATCH - архив испорчен! 💥"; FAILED+=("$H"); continue; fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%F_%T)" "$H" "$DEST/$FNAME" "${BSZ:-?}" "$SEL_STR" >> "$INDEX"

    if [ "$KEEP_BACKUPS" -gt 0 ] 2>/dev/null; then
      LIST_OLD=$(ls -1t "$DEST"/*.tar.gz 2>/dev/null | tail -n +"$((KEEP_BACKUPS+1))")
      if [ -n "$LIST_OLD" ]; then
        while IFS= read -r f; do rm -f -- "$f"; done <<<"$LIST_OLD"
      fi
    fi

    ok "готово: $DEST/$FNAME"
  done

  echo ""; hr
  if [ "${#FAILED[@]}" -gt 0 ]; then warn ":( Не удалось: ${FAILED[*]}"
  else ok "🎉 Все серверы обработаны!"; fi
  pause_
}

# ═══ МЕНЮ: ВОССТАНОВЛЕНИЕ ════════════════════════════════════════════════════
menu_restore(){
  clear 2>/dev/null || true
  hr; echo "${BO}♻️ ВОССТАНОВЛЕНИЕ${N}"; hr
  preflight
  [ -d "$BACKUP_ROOT" ] || die "папки $BACKUP_ROOT ещё нет - сначала сделайте бэкап"

  LIST=()
  while IFS= read -r f; do LIST+=("$f"); done < <(find "$BACKUP_ROOT" -name '*.tar.gz' -type f | sort)
  NL=${#LIST[@]}
  [ "$NL" -gt 0 ] || die "архивов не найдено"

  echo "🗂 Архивы:"
  i=1
  for a in "${LIST[@]}"; do
    fsize=$(du -h "$a" 2>/dev/null | cut -f1)
    printf '  %2d) %8s  %s\n' "$i" "$fsize" "${a#$BASE/}"
    i=$((i+1))
  done
  read -rp $'\nНомер архива: '
  if ! [[ "$REPLY" =~ ^[0-9]+$ ]] || (( REPLY<1 || REPLY>NL )); then die "неверный номер"; fi
  ARCHIVE="${LIST[REPLY-1]}"

  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  tar -xzOf "$ARCHIVE" meta/manifest.txt 2>/dev/null > "$T/man" || die "в архиве нет manifest.txt"
  SRC_HOST=$(awk -F': ' '/^# hostname/{print $2; exit}' "$T/man")

  hr
  head -7 "$T/man"
  echo "  ..."
  sed -n '/^--- projects/,/^$/p' "$T/man" | head -12
  hr
  NVC=$(tar -tzf "$ARCHIVE" | grep -c '^volumes/.*\.tgz$' || true)
  HAS_SQL="нет"
  tar -tzf "$ARCHIVE" 2>/dev/null | grep -q '^db/pg_all.sql.gz$' && HAS_SQL="да ✅"
  NSYS=$(tar -xzOf "$ARCHIVE" meta/syspaths_present.txt 2>/dev/null | grep -c . || true)
  NIMG=$(tar -tzf "$ARCHIVE" | grep -c '^images/img_' || true)
  echo "  📦 томов: $NVC │ 🗄 SQL: $HAS_SQL │ 🧩 сист. путей: $NSYS │ 🖼 образов: $NIMG"
  hr

  echo "🎯 Целевой сервер (Enter = исходный «$SRC_HOST»)."
  SRVL="-"
  for s in "${SERVERS[@]}"; do SRVL="$SRVL $s"; done
  echo "В конфиге:$SRVL"
  read -rp "Хост: " TARGET
  TARGET=${TARGET:-$SRC_HOST}
  if ! ssh_ok "$TARGET"; then die "$TARGET: нет ssh-доступа"; fi
  [ "$TARGET" != "$SRC_HOST" ] && warn "⚠️  целевой хост отличается от исходного!"

  echo ""
  echo "Что восстанавливаем?"
  echo "  ${B}1${N}) 🌍 ВСЁ (файлы, тома, SQL, запуск стеков + системное)  ← обычно это"
  echo "  ${B}2${N}) 🐳 Только приложения (compose, тома, SQL, запуск)"
  echo "  ${B}3${N}) 🐳 Приложения БЕЗ импорта SQL (данные возьмутся из tar томов)"
  echo "  ${B}4${N}) 🧩 Только системное (/var/www, серты, nginx, cron...)"
  echo "  ${B}0${N}) отмена"
  read -rp $'\nВыбор: ' mm
  case "$mm" in
    1) MODE=full ;;
    2) MODE=apps ;;
    3) MODE=dbless ;;
    4) MODE=sys ;;
    *) return ;;
  esac

  STOPV=1
  if [ "$MODE" != sys ]; then
    read -rp "Остановить существующие совпадающие стеки перед развёртыванием? [Y/n]: "
    if [ "${REPLY,,}" = n ]; then STOPV=0; else STOPV=1; fi
  fi

  warn "📄 АРХИВ: $(basename "$ARCHIVE")"
  warn "🎯 ЦЕЛЬ : $TARGET    режим: $MODE"
  read -rp $'\n🔥 Точно продолжить? [да/no]: '
  [ "${REPLY,,}" = да ] || die "отменено"

  remote_transport_mode "$TARGET"
  info "🛰  Транспорт: $(transport_label "$TARGET")"

  WRAP="$(probe_wrap "$TARGET")" || die "$TARGET: Docker недоступен на цели"
  RW="$(rw_of "$WRAP")"

  RDIR="/root/.dockrestore"
  if [ "$WRAP" = "sudo" ]; then RDIR="/tmp/.dockrestore.$(date +%s)"; fi
  if ! ssh "${SSH_OPTS[@]}" "$TARGET" "mkdir -p $(q "$RDIR")" 2>/dev/null; then
    ssh "${SSH_OPTS[@]}" "$TARGET" "${RW}mkdir -p $(q "$RDIR")" 2>/dev/null \
      || die "не удалось создать $RDIR"
  fi

  echo ""; info "⬆️ загрузка архива на $TARGET..."
  if ! push_file "$ARCHIVE" "$TARGET" "$RDIR/data.tgz"; then
    ssh "${SSH_OPTS[@]}" "$TARGET" "rm -rf $(q "$RDIR")" 2>/dev/null
    die "загрузка архива не удалась"
  fi

  info "🚑 Выполняю восстановление:"
  set +e
  OUT=$(ssh -tt "${SSH_OPTS[@]}" "$TARGET" \
      "${RW}bash -s $(q "$MODE") $STOPV $(q "$RDIR")" \
      < <(printf '%s\n' "$PAYLOAD_RS") 2>&1 | tee "$T/log")
  RC=${PIPESTATUS[0]}
  set +e
  ssh "${SSH_OPTS[@]}" "$TARGET" "rm -rf $(q "$RDIR")" 2>/dev/null

  echo ""; hr
  if grep -q '^RESTORE_COMPLETED' <<<"$OUT"; then
    ok "🎉 Готово! Проверьте сервисы на $TARGET"
  elif grep -q '^RESTORE_PARTIAL' <<<"$OUT"; then
    warn "😅 Частично: что-то не поднялось - см. лог выше"
  else
    warn "💥 Завершился нештатно (rc=$RC)"
  fi
  trap - EXIT
  pause_
}

# ═══ СПИСОК АРХИВОВ ══════════════════════════════════════════════════════════
cmd_list(){
  clear 2>/dev/null || true
  hr; echo "${BO}📋 АРХИВЫ${N}"; hr
  INDEX="$BACKUP_ROOT/index.tsv"
  if [ -f "$INDEX" ]; then
    awk -F'\t' '{printf "  %s │ %-12s │ %10s Б │ %s\n",$1,$2,$4,$3}' "$INDEX"
  else
    echo "  журнал пуст - бэкапов ещё не было"
  fi
  [ -d "$BACKUP_ROOT" ] || return 0
  echo ""
  du -sh "$BACKUP_ROOT"/* 2>/dev/null | while read -r sz d; do
    printf '  %-45s %8s\n' "${d#$BASE/}" "$sz"
  done
}

main_menu
