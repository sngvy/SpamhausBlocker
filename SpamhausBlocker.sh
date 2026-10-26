#!/bin/bash

# Стили и цвета
BOLD='\033[1m'
B_CYAN='\033[1;36m'
B_GREEN='\033[1;32m'
B_YELLOW='\033[1;33m'
B_RED='\033[1;31m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${B_RED}Ошибка: Запустите от имени root.${NC}"
    exit 1
fi

S="/usr/local/bin/update-spamhausblocker.sh"
STATE_DIR="/etc/spamhausblocker"
BACKUP_DIR="$STATE_DIR/backup/$(date +%Y%m%d-%H%M%S)"
LIST_URL="https://www.spamhaus.org/drop/drop.txt"
SET4="spamhausblocker_v4"
SET6="spamhausblocker_v6"

echo -e "${B_CYAN}Конфигурация SpamhausBlocker (ipset)${NC}"

# ------------------------------------------------------------
# Определяем, есть ли предыдущая установка и какой у неё режим
# ------------------------------------------------------------
PREV_MODE=""
if [ -f "$S" ]; then
    PREV_MODE=$(sed -n 's/^MODE="\([a-z]*\)".*/\1/p' "$S" | head -n1)
    echo -e "${B_YELLOW}Найдена установка SpamhausBlocker (режим: ${PREV_MODE:-неизвестен}). Будет обновление.${NC}"
fi

echo -e "Выберите метод защиты:"
echo -e "1) UFW (рекомендуется для Ubuntu/Debian)"
echo -e "2) iptables (прямые правила)"
if [ -n "$PREV_MODE" ]; then
    read -r -p "Ваш выбор [1-2, Enter = оставить $PREV_MODE]: " FW_CHOICE
    if [ -z "$FW_CHOICE" ]; then
        [ "$PREV_MODE" = "ufw" ] && FW_CHOICE=1 || FW_CHOICE=2
    fi
else
    read -r -p "Ваш выбор [1-2]: " FW_CHOICE
fi

case $FW_CHOICE in
    1) MODE="ufw" ;;
    2) MODE="iptables" ;;
    *) echo "Неверный выбор. Выход."; exit 1 ;;
esac

# ------------------------------------------------------------
# Установка пакетов
# ------------------------------------------------------------
export DEBIAN_FRONTEND=noninteractive

if [ "$MODE" = "ufw" ]; then
    if ! command -v ufw >/dev/null; then
        echo -e "${B_YELLOW}Установка UFW...${NC}"
        apt-get update -qq && apt-get install -y ufw -qq
    fi

    # iptables-persistent перезаписывал бы правила UFW
    if dpkg -l | grep -q iptables-persistent; then
        echo -e "${B_YELLOW}Удаление конфликтующего iptables-persistent...${NC}"
        apt-get purge -y iptables-persistent -qq
    fi
else
    echo -e "${B_YELLOW}Настройка компонентов iptables...${NC}"
    mkdir -p /etc/iptables
    echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections
    echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections
    apt-get update -qq && apt-get install -y iptables iptables-persistent -qq
fi

echo -e "${B_YELLOW}Установка ipset, curl, logrotate...${NC}"
apt-get update -qq && apt-get install -y ipset curl logrotate -qq
if ! command -v ipset >/dev/null; then
    echo -e "${B_RED}Не удалось установить ipset. Выход, старые правила не тронуты.${NC}"
    exit 1
fi

# ------------------------------------------------------------
# Резервные копии всего, что будем менять
# ------------------------------------------------------------
backup_file() {
    [ -e "$1" ] || return 0
    mkdir -p "$BACKUP_DIR"
    cp -a "$1" "$BACKUP_DIR/$(echo "$1" | tr '/' '_')"
}

mkdir -p "$STATE_DIR"
for f in /etc/ufw/user.rules /etc/ufw/user6.rules /etc/ufw/before.rules /etc/ufw/before6.rules \
         /etc/iptables/rules.v4 /etc/iptables/rules.v6 "$S"; do
    backup_file "$f"
done
if command -v iptables-save >/dev/null; then
    mkdir -p "$BACKUP_DIR"
    iptables-save > "$BACKUP_DIR/iptables-save.v4" 2>/dev/null
    ip6tables-save > "$BACKUP_DIR/ip6tables-save.v6" 2>/dev/null
fi
[ -d "$BACKUP_DIR" ] && echo -e "${B_YELLOW}Резервные копии на время миграции: $BACKUP_DIR (удалятся после успешной проверки)${NC}"

# ------------------------------------------------------------
# Ротация логов: храним только последние 7 дней
# ------------------------------------------------------------
cat << 'LOGROTATE_EOF' > /etc/logrotate.d/spamhausblocker
/var/log/spamhausblocker_update.log {
    daily
    rotate 7
    missingok
    notifempty
    compress
    delaycompress
}
LOGROTATE_EOF

# ------------------------------------------------------------
# Скрипт-обновлятор: ipset (атомарная подмена набора через swap)
# Подкоманды: (без аргументов) обновить список | restore
# ------------------------------------------------------------
cat << 'UPDATER_EOF' > "$S"
#!/bin/bash
MODE="__MODE__"
URL="__URL__"
STATE_DIR="/etc/spamhausblocker"
SAVE_FILE="$STATE_DIR/ipsets.save"
SET4="spamhausblocker_v4"
SET6="spamhausblocker_v6"
MAXELEM=262144
MIN_V4_ENTRIES=10

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

mkdir -p "$STATE_DIR"
exec 9>/run/spamhausblocker.lock
if ! flock -w 120 9; then
    log "[ERROR] Не удалось получить блокировку, другой экземпляр занят"
    exit 1
fi

create_sets() {
    ipset create -exist "$SET4" hash:net family inet  hashsize 4096 maxelem "$MAXELEM"
    ipset create -exist "$SET6" hash:net family inet6 hashsize 1024 maxelem "$MAXELEM"
}

restore_sets() {
    if [ -s "$SAVE_FILE" ]; then
        ipset restore -exist < "$SAVE_FILE" || log "[WARN] Не удалось полностью восстановить $SAVE_FILE"
    fi
}

save_sets() {
    { ipset save "$SET4"; ipset save "$SET6"; } > "$SAVE_FILE.tmp" && mv "$SAVE_FILE.tmp" "$SAVE_FILE"
}

# Атомарная загрузка: наполняем временный набор и меняем местами с рабочим
load_set() {
    local set="$1" fam="$2" hs="$3" file="$4" tmp="${1}_tmp" net
    ipset destroy "$tmp" 2>/dev/null
    ipset create "$tmp" hash:net family "$fam" hashsize "$hs" maxelem "$MAXELEM" || return 1
    if [ -s "$file" ]; then
        if ! sed "s/^/add $tmp /" "$file" | ipset restore -exist 2>/dev/null; then
            log "[WARN] Пакетная загрузка в $set не прошла, добавляю записи по одной"
            ipset flush "$tmp"
            while IFS= read -r net; do
                ipset add -exist "$tmp" "$net" 2>/dev/null || log "[WARN] Пропущена запись: $net"
            done < "$file"
        fi
    fi
    if ! ipset swap "$tmp" "$set"; then
        ipset destroy "$tmp" 2>/dev/null
        return 1
    fi
    ipset destroy "$tmp"
}

ensure_iptables_rules() {
    local cmd set
    for cmd in iptables ip6tables; do
        [ "$cmd" = "iptables" ] && set="$SET4" || set="$SET6"
        $cmd -N SPAMHAUS-BLOCK 2>/dev/null
        # Сбрасываем цепочку: заодно убираем тысячи старых правил по одному адресу
        $cmd -F SPAMHAUS-BLOCK
        $cmd -A SPAMHAUS-BLOCK -m set --match-set "$set" dst -j DROP
        $cmd -C OUTPUT -j SPAMHAUS-BLOCK &>/dev/null || $cmd -I OUTPUT 1 -j SPAMHAUS-BLOCK
    done
}

case "${1:-update}" in
    restore)  create_sets; restore_sets; exit 0 ;;
    update)   ;;
    *) echo "Использование: $0 [update|restore]"; exit 1 ;;
esac

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
RAW="$TMP_DIR/raw"; V4="$TMP_DIR/v4"; V6="$TMP_DIR/v6"
: > "$V4"; : > "$V6"

if ! curl -fsSL -A "SpamhausBlocker/1.0 (+https://github.com/sngvy/SpamhausBlocker)" --max-time 30 "$URL" -o "$RAW" || [ ! -s "$RAW" ]; then
    log "[ERROR] Не удалось скачать список SpamhausBlocker, оставляю текущие наборы без изменений"
    exit 1
fi

# Валидация: только корректные CIDR. Формат Spamhaus DROP — построчно "CIDR ; SBLxxxxx",
# комментарии/заголовок — строки с ";" в начале (хвост после ";" в строке с данными отбрасываем).
# Слишком широкие сети (v4 шире /8, v6 шире /16) отбрасываем, чтобы испорченный файл
# не заблокировал весь интернет и вас самих.
awk -v f4="$V4" -v f6="$V6" '
{
    gsub(/\r/, ""); sub(/^[ \t]+/, "")
    if ($0 == "" || $0 ~ /^;/) next
    s = $0
    sub(/[ \t]*;.*$/, "", s)
    sub(/[ \t]+$/, "", s)
    if (s == "") next
    p = ""
    i = index(s, "/")
    if (i) {
        p = substr(s, i + 1); s = substr(s, 1, i - 1)
        if (p !~ /^[0-9]+$/) next
    }
    if (s ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
        n = split(s, a, ".")
        for (k = 1; k <= n; k++) if (a[k] + 0 > 255) next
        if (p == "") p = 32
        if (p + 0 < 8 || p + 0 > 32) next
        print s "/" p >> f4
    } else if (s ~ /^[0-9a-fA-F:]+$/ && s ~ /:.*:/) {
        if (p == "") p = 128
        if (p + 0 < 16 || p + 0 > 128) next
        print s "/" p >> f6
    }
}' "$RAW"

N4=$(wc -l < "$V4")
N6=$(wc -l < "$V6")
if [ "$N4" -lt "$MIN_V4_ENTRIES" ]; then
    log "[ERROR] В списке всего $N4 IPv4-записей (минимум $MIN_V4_ENTRIES), похоже на повреждённый файл. Наборы не изменены"
    exit 1
fi

create_sets
if ! load_set "$SET4" inet 4096 "$V4" || ! load_set "$SET6" inet6 1024 "$V6"; then
    log "[ERROR] Не удалось загрузить наборы ipset"
    exit 1
fi
save_sets

if [ "$MODE" = "iptables" ]; then
    ensure_iptables_rules
fi
# В режиме ufw правила лежат в before.rules и ссылаются на наборы по имени,
# поэтому ufw reload после обновления списка не нужен.

log "[SUCCESS] Список SpamhausBlocker обновлён: IPv4=$N4, IPv6=$N6 (режим $MODE, ipset)"
UPDATER_EOF

sed -i "s|__MODE__|$MODE|; s|__URL__|$LIST_URL|" "$S"
chmod +x "$S"

# ------------------------------------------------------------
# Служба, которая создаёт наборы до загрузки файрвола.
# Без неё правила с --match-set не загрузятся после ребута
# (iptables-restore падает целиком, если набора ещё нет).
# ------------------------------------------------------------
cat << EOF > /etc/systemd/system/spamhausblocker-ipset.service
[Unit]
Description=Create and restore SpamhausBlocker ipsets before firewall
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target ufw.service netfilter-persistent.service iptables.service ip6tables.service
Wants=network-pre.target
Conflicts=shutdown.target
Before=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$S restore

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable spamhausblocker-ipset.service >/dev/null 2>&1

# ------------------------------------------------------------
# Первый запуск: создаём наборы и наполняем их.
# Старые правила пока не трогаем: если загрузка не удалась, защита остаётся.
# ------------------------------------------------------------
"$S" restore
echo -e "${B_YELLOW}Загрузка списка в ipset...${NC}"
if ! "$S"; then
    N=$(ipset list -t "$SET4" 2>/dev/null | awk -F': ' '/Number of entries/{print $2}')
    if [ "${N:-0}" -eq 0 ]; then
        echo -e "${B_RED}Набор $SET4 пуст, список не скачался. Старые правила оставлены без изменений.${NC}"
        echo -e "${B_YELLOW}Проверьте доступ к $LIST_URL и запустите установку снова.${NC}"
        exit 1
    fi
    echo -e "${B_YELLOW}Скачать новый список не вышло, продолжаю с сохранённым набором ($N записей).${NC}"
fi

remove_legacy_iptables_chains() {
    local cmd
    for cmd in iptables ip6tables; do
        command -v "$cmd" >/dev/null || continue
        while $cmd -D OUTPUT -j SPAMHAUS-BLOCK 2>/dev/null; do :; done
        $cmd -F SPAMHAUS-BLOCK 2>/dev/null && $cmd -X SPAMHAUS-BLOCK 2>/dev/null
    done
}

# ------------------------------------------------------------
# UFW: before.rules
# ------------------------------------------------------------
setup_ipset_block_ufw() {
    echo -e "${B_YELLOW}Подключение наборов ipset к UFW (before.rules)...${NC}"
    local f chain set tmp
    for f in /etc/ufw/before.rules /etc/ufw/before6.rules; do
        [ -f "$f" ] || continue
        if [[ "$f" == *before6.rules ]]; then
            chain="ufw6-before-output"; set="$SET6"
        else
            chain="ufw-before-output"; set="$SET4"
        fi

        # Убираем прошлую версию блока, чтобы повторный запуск не плодил дубли
        sed -i '/# --- SpamhausBlocker-IPSet: begin ---/,/# --- SpamhausBlocker-IPSet: end ---/d' "$f"

        tmp=$(mktemp)
        if grep -q '^# End required lines' "$f"; then
            # Ставим правило самым первым в цепочке, до разрешающих правил UFW
            awk -v chain="$chain" -v set="$set" '
                { print }
                /^# End required lines/ && !done {
                    print "# --- SpamhausBlocker-IPSet: begin ---"
                    print "-A " chain " -m set --match-set " set " dst -j DROP"
                    print "# --- SpamhausBlocker-IPSet: end ---"
                    done = 1
                }
            ' "$f" > "$tmp"
        else
            echo -e "${B_YELLOW}В $f нет маркера '# End required lines', вставляю перед COMMIT (проверьте порядок правил).${NC}"
            awk -v chain="$chain" -v set="$set" '
                /^COMMIT/ && !done {
                    print "# --- SpamhausBlocker-IPSet: begin ---"
                    print "-A " chain " -m set --match-set " set " dst -j DROP"
                    print "# --- SpamhausBlocker-IPSet: end ---"
                    done = 1
                }
                { print }
            ' "$f" > "$tmp"
        fi
        cat "$tmp" > "$f"
        rm -f "$tmp"
    done
}

restore_ufw_backups() {
    local f
    for f in user.rules user6.rules before.rules before6.rules; do
        [ -e "$BACKUP_DIR/_etc_ufw_$f" ] && cat "$BACKUP_DIR/_etc_ufw_$f" > "/etc/ufw/$f"
    done
}

ufw_is_active() {
    ufw status 2>/dev/null | grep -q "^Status: active"
}

if [ "$MODE" = "ufw" ]; then
    setup_ipset_block_ufw

    if ufw_is_active; then
        if ! ufw reload; then
            echo -e "${B_RED}ufw reload не прошёл, возвращаю прежние файлы правил из $BACKUP_DIR${NC}"
            restore_ufw_backups
            ufw reload
            exit 1
        fi
    else
        echo -e "${B_RED}ВНИМАНИЕ: UFW сейчас не включён, правила применятся только после 'ufw enable'.${NC}"
        echo -e "${B_YELLOW}Сначала убедитесь, что разрешён SSH (ufw allow <порт>/tcp), иначе потеряете доступ.${NC}"
    fi

    # Прежние цепочки iptables больше не нужны: блокировку делает UFW
    remove_legacy_iptables_chains

    systemctl enable ufw 2>/dev/null
    if systemctl is-enabled ufw &>/dev/null; then
        echo -e "${B_GREEN}UFW включён в автозагрузку, before.rules применится при ребуте.${NC}"
    else
        echo -e "${B_RED}ВНИМАНИЕ: ufw не в автозагрузке. Выполните: ufw enable${NC}"
    fi
else
    # Переход с UFW на iptables: убираем наши блоки из UFW
    for f in /etc/ufw/before.rules /etc/ufw/before6.rules; do
        [ -f "$f" ] || continue
        sed -i '/# --- SpamhausBlocker-IPSet: begin ---/,/# --- SpamhausBlocker-IPSet: end ---/d' "$f"
    done
    command -v ufw >/dev/null && ufw_is_active && ufw reload

    # Цепочка SPAMHAUS-BLOCK уже пересоздана обновлятором с одним правилом на набор
    mkdir -p /etc/iptables
    iptables-save > /etc/iptables/rules.v4
    ip6tables-save > /etc/iptables/rules.v6

    systemctl enable netfilter-persistent 2>/dev/null || systemctl enable iptables-persistent 2>/dev/null
    systemctl restart netfilter-persistent 2>/dev/null

    if systemctl is-enabled netfilter-persistent &>/dev/null; then
        echo -e "${B_GREEN}netfilter-persistent включён, правила переживут перезагрузку.${NC}"
    else
        echo -e "${B_RED}ВНИМАНИЕ: не удалось включить netfilter-persistent. После ребута правила iptables могут слететь!${NC}"
    fi
fi

# ------------------------------------------------------------
# Cron и служба обновления при старте
# ------------------------------------------------------------
C_JOB="30 3 * * * $S >> /var/log/spamhausblocker_update.log 2>&1"
(crontab -l 2>/dev/null | grep -v "$S" ; echo "$C_JOB") | crontab -

UPD_UNIT="/etc/systemd/system/spamhausblocker-update.service"
if [ -f "$UPD_UNIT" ]; then
    SYSTEMD_CHOICE="y"
    echo -e "${B_YELLOW}Найдена служба spamhausblocker-update, обновляю её файл (без устаревших зависимостей).${NC}"
else
    read -r -p $'\033[1;33mСоздать службу systemd для обновления при старте системы? [y/N]: \033[0m' SYSTEMD_CHOICE
fi
if [[ "$SYSTEMD_CHOICE" =~ ^[Yy]$ ]]; then
    cat << EOF > "$UPD_UNIT"
[Unit]
Description=Update SpamhausBlocker Blocklist on Boot
After=network-online.target spamhausblocker-ipset.service
Wants=network-online.target
Requires=spamhausblocker-ipset.service

[Service]
Type=oneshot
ExecStart=$S
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable spamhausblocker-update.service
    echo -e "${B_YELLOW}Служба systemd создана и включена.${NC}"
fi

echo -e "${B_GREEN}SpamhausBlocker успешно настроен через $MODE (ipset).${NC}"
echo -e "Проверка:"
echo -e "  ipset list -t $SET4 | grep 'Number of entries'"
if [ "$MODE" = "ufw" ]; then
    echo -e "  iptables -S ufw-before-output | grep match-set"
else
    echo -e "  iptables -S SPAMHAUS-BLOCK"
fi

# ------------------------------------------------------------
# Проверка результата. Бэкап удаляется только если всё реально работает,
# иначе он остаётся для ручного отката.
# ------------------------------------------------------------
verify_migration() {
    local n4
    n4=$(ipset list -t "$SET4" 2>/dev/null | awk -F': ' '/Number of entries/{print $2}')
    [ "${n4:-0}" -gt 0 ] || { echo "набор $SET4 пуст"; return 1; }
    ipset list -n 2>/dev/null | grep -qx "$SET6" || { echo "нет набора $SET6"; return 1; }
    if [ "$MODE" = "ufw" ]; then
        iptables -S ufw-before-output 2>/dev/null | grep -q "match-set $SET4" \
            || { echo "правило ipset не найдено в ufw-before-output (UFW выключен?)"; return 1; }
    else
        iptables -C SPAMHAUS-BLOCK -m set --match-set "$SET4" dst -j DROP 2>/dev/null \
            || { echo "правило ipset не найдено в SPAMHAUS-BLOCK"; return 1; }
        iptables -C OUTPUT -j SPAMHAUS-BLOCK 2>/dev/null \
            || { echo "нет перехода OUTPUT -> SPAMHAUS-BLOCK"; return 1; }
    fi
    systemctl is-enabled spamhausblocker-ipset.service &>/dev/null \
        || { echo "spamhausblocker-ipset.service не включён"; return 1; }
    return 0
}

if [ -d "$BACKUP_DIR" ]; then
    if REASON=$(verify_migration); then
        rm -rf "$BACKUP_DIR"
        rmdir "$STATE_DIR/backup" 2>/dev/null
        echo -e "${B_GREEN}Миграция проверена, резервные копии удалены.${NC}"
    else
        echo -e "${B_YELLOW}Проверка не пройдена ($REASON), резервные копии оставлены: $BACKUP_DIR${NC}"
    fi
fi