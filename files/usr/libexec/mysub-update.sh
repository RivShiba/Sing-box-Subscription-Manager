#!/bin/sh
# : /usr/libexec/mysub-update.sh
# : chmod +x /usr/libexec/mysub-update.sh

CONFIG_FILE="/etc/config/mysub"
LOG_FILE="/var/log/mysub.log"
XRAY_CONV="/usr/libexec/mysub-xray2sing.jq"
LOCK_DIR="/tmp/mysub.lock"

# --- Блокировка: два парсера одновременно нельзя ---
# Они используют общие временные файлы (/tmp/mysub_outbounds.json и др.) и
# пишут в один лог, поэтому параллельный запуск (кнопка + cron, кнопка +
# анализ) ломает обновление. mkdir атомарен, flock в busybox нет.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    _lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$_lock_pid" ] && kill -0 "$_lock_pid" 2>/dev/null; then
        # Лог не перезаписываем — там работает другой экземпляр.
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] Парсер уже выполняется (pid $_lock_pid) — этот запуск пропущен." >> "$LOG_FILE"
        logger -t mysub "already running (pid $_lock_pid), skipped duplicate start"
        exit 0
    fi
    # Замок остался от убитого процесса — снимаем и занимаем.
    rm -rf "$LOCK_DIR"
    mkdir "$LOCK_DIR" 2>/dev/null || exit 1
fi
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' 0 1 2 15

# Режим анализа подписок (--analyze): только замер/сортировка/шаблон,
# основной конфиг и запущенный сервис при этом не затрагиваются.
ANALYZE_MODE=0
[ "$1" = "--analyze" ] && ANALYZE_MODE=1
ANALYZE_DIR="/tmp/mysub_analyze"
PROBE_PORT=9199
PROBE_TRIES=2
PROBE_PARALLEL=8

> "$LOG_FILE"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $1" >> "$LOG_FILE"; }
debug() { [ "$log_level" = "debug" ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $1" >> "$LOG_FILE"; }

log_level=$(uci -q get mysub.@mysub[0].log_level || uci -q get mysub.main.log_level)
[ -z "$log_level" ] && log_level="info"

log "=== Starting Subscription Parser ==="
log "Log level is set to: $log_level"

if [ ! -f "$CONFIG_FILE" ]; then
    log "ERROR: Config $CONFIG_FILE not found."
    exit 1
fi

urls=$(uci -q get mysub.@mysub[0].urls || uci -q get mysub.main.urls)
debug "Loaded URLs: $urls"
base_config=$(uci -q get mysub.@mysub[0].base_config || uci -q get mysub.main.base_config)
output_config=$(uci -q get mysub.@mysub[0].output_config || uci -q get mysub.main.output_config)

[ -z "$base_config" ] && base_config="/etc/mysub/template.json"
[ -z "$output_config" ] && output_config="/etc/mysub/mysub.json"

# --- Параметры анализа подписок (вкладка «Анализ подписок») ---
use_template=$(uci -q get mysub.@mysub[0].use_analysis_template || uci -q get mysub.main.use_analysis_template)
[ -z "$use_template" ] && use_template=0
max_delay_ms=$(uci -q get mysub.@mysub[0].max_delay_ms || uci -q get mysub.main.max_delay_ms)
[ -z "$max_delay_ms" ] && max_delay_ms=500
exclude_keywords=$(uci -q get mysub.@mysub[0].exclude_keywords || uci -q get mysub.main.exclude_keywords)

log "Base config: $base_config"
log "Output config: $output_config"

# В режиме анализа базовый конфиг не нужен: основной конфиг не изменяется.
if [ "$ANALYZE_MODE" = "0" ]; then
    if [ ! -f "$base_config" ]; then
        log "ERROR: Base config (template) not found!"
        exit 1
    fi

    # Validate base config JSON
    if ! jq empty < "$base_config" >/dev/null 2>/tmp/jq_base_err.log; then
        log "ERROR: Base config $base_config contains invalid JSON!"
        err_msg=$(cat /tmp/jq_base_err.log | tr '\n' ' ')
        log "JQ ERROR: $err_msg"
        exit 1
    fi
fi

if [ -z "$urls" ]; then
    log "No URLs to parse."
    exit 1
fi

echo "[" > /tmp/mysub_outbounds.json
echo "[]" > /tmp/mysub_subst.json
total_parsed=0
total_skipped=0

urldecode() {
    awk -v str="$1" 'BEGIN {
        gsub(/\\+/, " ", str)
        res = ""
        for (i=1; i<=length(str); i++) {
            c = substr(str, i, 1)
            if (c == "%") {
                if (i+2 <= length(str)) {
                    hex = substr(str, i+1, 2)
                    dec = 0
                    for (j=1; j<=2; j++) {
                        hc = tolower(substr(hex, j, 1))
                        dec = dec * 16 + (index("0123456789abcdef", hc) - 1)
                    }
                    res = res sprintf("%c", dec)
                    i += 2
                } else {
                    res = res c
                }
            } else {
                res = res c
            }
        }
        print res
    }'
}

decode_base64() {
    local str=$(echo "$1" | tr -d '\r\n ' | tr '_-' '/+')
    local len=${#str}
    local rem=$((len % 4))
    [ $rem -eq 2 ] && str="${str}=="
    [ $rem -eq 3 ] && str="${str}="
    echo "$str" | base64 -d 2>/dev/null
}

# ================= Анализ подписок и шаблон серверов =================
# Задержка измеряется реальным подключением через отдельный временный
# экземпляр sing-box (Clash API), а не ICMP/TCP: ICMP режется файрволами
# хостеров, а любой TCP-connect изнутри роутера перехватывается tproxy momo.
# Рабочий сервис при замере не затрагивается — это другой процесс.

TAB="$(printf '\t')"

template_enabled() {
    case "$use_template" in
        1|true|on|yes|enabled) return 0 ;;
        *) return 1 ;;
    esac
}

# server_template хранится в UCI как list (многострочный option UCI не принимает).
read_template_lines() {
    uci -q show mysub 2>/dev/null \
        | sed -n 's/^mysub\.main\.server_template=//p' \
        | sed "s/' '/\n/g" \
        | sed "s/^'//; s/'$//"
}

# Только ключи "адрес:порт": всё после # считается комментарием.
read_template_keys() {
    read_template_lines | while IFS= read -r _line; do
        _key=$(printf '%s' "$_line" | sed 's/#.*//' | tr -d ' \t\r')
        [ -n "$_key" ] && printf '%s\n' "$_key"
    done
}

# Запуск временного sing-box только с узлами-кандидатами (Clash API на localhost).
probe_start() {
    _sb=$(command -v sing-box)
    if [ -z "$_sb" ]; then
        log "ERROR: sing-box не найден, замер задержки невозможен."
        return 1
    fi

    _port=$PROBE_PORT
    _tries=0
    while netstat -ltn 2>/dev/null | grep -q ":$_port "; do
        _port=$((_port + 10))
        _tries=$((_tries + 1))
        if [ "$_tries" -gt 5 ]; then
            log "ERROR: не нашёл свободный порт для Clash API."
            return 1
        fi
    done
    PROBE_PORT=$_port

    jq -n --slurpfile obs "$ANALYZE_DIR/candidates.json" --arg port "$PROBE_PORT" '{
        log: { level: "error", output: "/tmp/mysub_analyze/probe.log" },
        dns: { servers: [ { type: "udp", tag: "probe-dns", server: "1.1.1.1" } ], final: "probe-dns" },
        route: { default_domain_resolver: "probe-dns" },
        experimental: { clash_api: { external_controller: ("127.0.0.1:" + $port) } },
        outbounds: $obs[0]
    }' > "$ANALYZE_DIR/probe.json" 2>"$ANALYZE_DIR/jq_probe.err"

    if [ ! -s "$ANALYZE_DIR/probe.json" ]; then
        log "ERROR: не удалось собрать тестовый конфиг: $(tr '\n' ' ' < "$ANALYZE_DIR/jq_probe.err" | cut -c1-200)"
        return 1
    fi

    # Процесс должен читать/писать в свой каталог, а запускается он от nobody.
    chmod 777 "$ANALYZE_DIR" 2>/dev/null

    # uid nobody исключён из tproxy-правил momo -> замер идёт напрямую,
    # а не сквозь текущий туннель.
    if [ -x /sbin/start-stop-daemon ]; then
        start-stop-daemon -S -b -c nobody -p "$ANALYZE_DIR/probe.pid" -x "$_sb" -- \
            -D "$ANALYZE_DIR" run -c "$ANALYZE_DIR/probe.json" 2>"$ANALYZE_DIR/probe.err"
    else
        ( "$_sb" -D "$ANALYZE_DIR" run -c "$ANALYZE_DIR/probe.json" > "$ANALYZE_DIR/probe.err" 2>&1 &
          echo $! > "$ANALYZE_DIR/probe.pid" )
        log "WARN: start-stop-daemon не найден — замер может идти через текущий туннель."
    fi

    sleep 4
    _pid=$(cat "$ANALYZE_DIR/probe.pid" 2>/dev/null)
    [ -z "$_pid" ] && _pid=$(pgrep -f "D $ANALYZE_DIR" 2>/dev/null | head -1)

    # Гарантированный обход перехвата: тот же cgroup, что у самого momo.
    if [ -n "$_pid" ] && [ -d /sys/fs/cgroup/services/momo ]; then
        echo "$_pid" > /sys/fs/cgroup/services/momo/cgroup.procs 2>/dev/null \
            && debug "Процесс замера помещён в cgroup momo (обход tproxy)."
    fi

    _wait=0
    while [ "$_wait" -lt 10 ]; do
        if curl -s --max-time 2 "http://127.0.0.1:$PROBE_PORT/version" 2>/dev/null | grep -q '"version"'; then
            return 0
        fi
        sleep 1
        _wait=$((_wait + 1))
    done

    log "ERROR: временный sing-box не поднял Clash API на 127.0.0.1:$PROBE_PORT."
    [ -s "$ANALYZE_DIR/probe.log" ] && log "ERROR: $(tr '\n' ' ' < "$ANALYZE_DIR/probe.log" | cut -c1-300)"
    [ -s "$ANALYZE_DIR/probe.err" ] && log "ERROR: $(tr '\n' ' ' < "$ANALYZE_DIR/probe.err" | cut -c1-300)"
    return 1
}

probe_stop() {
    _pid=$(cat "$ANALYZE_DIR/probe.pid" 2>/dev/null)
    if [ -n "$_pid" ] && kill -0 "$_pid" 2>/dev/null; then
        kill "$_pid" 2>/dev/null
    fi
    # Подстраховка: только процессы с нашим каталогом в -D (momo не задеваем).
    for _p in $(pgrep -f "D $ANALYZE_DIR" 2>/dev/null); do
        kill "$_p" 2>/dev/null
    done
    sleep 1
    # В probe.json лежат параметры узлов (id/пароли) — на диске его не оставляем.
    rm -f "$ANALYZE_DIR/probe.json" "$ANALYZE_DIR/probe.pid"
    chmod 700 "$ANALYZE_DIR" 2>/dev/null
}

# Замер одного узла: лучший результат из PROBE_TRIES попыток, иначе пусто.
probe_measure() {
    _enc=$(jq -rn --arg x "$1" '$x|@uri' 2>/dev/null)
    _best=""
    _n=0
    while [ "$_n" -lt "$PROBE_TRIES" ]; do
        _n=$((_n + 1))
        _res=$(curl -s --max-time $(( max_delay_ms / 1000 + 2 )) \
            "http://127.0.0.1:$PROBE_PORT/proxies/$_enc/delay?timeout=$max_delay_ms&url=https%3A%2F%2Fwww.gstatic.com%2Fgenerate_204" 2>/dev/null)
        _d=$(printf '%s' "$_res" | jq -r '.delay // empty' 2>/dev/null)
        if [ -n "$_d" ]; then
            if [ -z "$_best" ] || [ "$_d" -lt "$_best" ]; then
                _best="$_d"
            fi
            [ "$_best" -le "$max_delay_ms" ] && break
        fi
    done
    [ -n "$_best" ] && printf '%s' "$_best"
}

# Режим --analyze: замер, сортировка по возрастанию, запись шаблона.
run_analysis() {
    log "=== Режим анализа подписок ==="
    log "Порог задержки: ${max_delay_ms} ms; слова-исключения: ${exclude_keywords:-нет}"

    rm -rf "$ANALYZE_DIR"
    mkdir -p "$ANALYZE_DIR"

    jq -r '.[] | select((.tag|type) == "string") | [.tag, (.server // ""), ((.server_port // 0)|tostring)] | @tsv' \
        /tmp/mysub_outbounds.json > "$ANALYZE_DIR/nodes.tsv" 2>/dev/null

    _total=$(wc -l < "$ANALYZE_DIR/nodes.tsv" | tr -d ' ')
    log "Узлов из подписок: $_total"

    : > "$ANALYZE_DIR/candidates.tsv"
    _ok=0
    _excluded=0
    _skipped=0
    while IFS="$TAB" read -r _tag _server _port; do
        [ -n "$_tag" ] || continue
        if [ -z "$_server" ] || [ "$_server" = "null" ] || [ "$_port" = "0" ]; then
            _skipped=$((_skipped + 1))   # группы/служебные узлы без адреса
            continue
        fi
        _hit=""
        if [ -n "$exclude_keywords" ]; then
            for _kw in $exclude_keywords; do
                case "$_tag" in
                    *"$_kw"*) _hit="$_kw"; break ;;
                esac
            done
        fi
        if [ -n "$_hit" ]; then
            _excluded=$((_excluded + 1))
            debug "Исключён по слову '$_hit': $_tag"
            continue
        fi
        printf '%s\t%s\t%s\n' "$_tag" "$_server" "$_port" >> "$ANALYZE_DIR/candidates.tsv"
        _ok=$((_ok + 1))
    done < "$ANALYZE_DIR/nodes.tsv"

    log "Кандидатов: $_ok (исключено по словам: $_excluded, без адреса: $_skipped)"

    if [ "$_ok" -eq 0 ]; then
        log "ERROR: после фильтрации не осталось узлов. Шаблон не изменён."
        return 1
    fi

    awk -F"$TAB" '{print $1}' "$ANALYZE_DIR/candidates.tsv" > "$ANALYZE_DIR/candidate_tags.txt"
    jq --rawfile t "$ANALYZE_DIR/candidate_tags.txt" \
        '[ .[] | select(.tag as $x | ($t | split("\n") | index($x)) != null) ]' \
        /tmp/mysub_outbounds.json > "$ANALYZE_DIR/candidates.json" 2>"$ANALYZE_DIR/jq_cand.err"

    if [ ! -s "$ANALYZE_DIR/candidates.json" ]; then
        log "ERROR: не удалось подготовить узлы для замера: $(tr '\n' ' ' < "$ANALYZE_DIR/jq_cand.err" | cut -c1-200)"
        return 1
    fi

    if ! probe_start; then
        probe_stop
        log "ERROR: замер невозможен. Шаблон не изменён."
        return 1
    fi
    log "Временный sing-box запущен (Clash API 127.0.0.1:$PROBE_PORT), идёт замер..."

    : > "$ANALYZE_DIR/results.tsv"
    _idx=0
    while IFS="$TAB" read -r _tag _server _port; do
        _idx=$((_idx + 1))
        (
            _d=$(probe_measure "$_tag")
            printf '%s\t%s\t%s\t%s\n' "$_tag" "$_server" "$_port" "$_d" >> "$ANALYZE_DIR/results.tsv"
        ) &
        if [ $((_idx % PROBE_PARALLEL)) -eq 0 ]; then
            wait
        fi
    done < "$ANALYZE_DIR/candidates.tsv"
    wait
    probe_stop

    awk -F"$TAB" -v max="$max_delay_ms" 'NF >= 4 && $4 != "" && ($4 + 0) <= (max + 0) { print $4 "\t" $2 ":" $3 "\t" $1 }' \
        "$ANALYZE_DIR/results.tsv" | sort -n > "$ANALYZE_DIR/sorted.tsv"

    _measured=$(wc -l < "$ANALYZE_DIR/results.tsv" | tr -d ' ')
    _fast=$(wc -l < "$ANALYZE_DIR/sorted.tsv" | tr -d ' ')
    log "Замерены: $_measured; прошли порог ${max_delay_ms} ms: $_fast"

    if [ "$_fast" -eq 0 ]; then
        log "ERROR: ни один сервер не прошёл замер. Шаблон не изменён (оставлен прежний)."
        return 1
    fi

    uci -q delete mysub.main.server_template
    while IFS="$TAB" read -r _d _key _tag; do
        uci -q add_list mysub.main.server_template="${_key}  # ${_tag} (${_d}ms)"
    done < "$ANALYZE_DIR/sorted.tsv"
    uci -q commit mysub

    log "SUCCESS: шаблон сохранён — $_fast сервер(ов), отсортированы по возрастанию задержки (см. поле «Шаблон серверов»)."
    log "Чтобы обновления шли только по шаблону, включите галочку «Использовать шаблон анализа»."
    return 0
}

# Обычный режим: оставить только серверы из шаблона и в порядке шаблона.
apply_server_template() {
    mkdir -p "$ANALYZE_DIR"
    read_template_keys > "$ANALYZE_DIR/tpl_keys.txt"
    _kcount=$(grep -c . "$ANALYZE_DIR/tpl_keys.txt" 2>/dev/null | tr -d ' ')
    [ -z "$_kcount" ] && _kcount=0

    if [ "$_kcount" -eq 0 ]; then
        log "ERROR: включён шаблон анализа, но шаблон пуст. Обновление отменено, конфиг не изменён."
        return 1
    fi

    # -n обязателен: данные приходят через --slurpfile/--rawfile, а stdin у
    # скрипта может быть чем угодно (cron, heredoc, LuCI).
    if ! jq -n --slurpfile o /tmp/mysub_outbounds.json --rawfile k "$ANALYZE_DIR/tpl_keys.txt" '
        ($k | split("\n") | map(select(length > 0))) as $keys
        | [ $keys[] as $key
            | $o[0][] | select( ((.server // "") + ":" + ((.server_port // 0)|tostring)) == $key ) ]
    ' > "$ANALYZE_DIR/filtered.json" 2>"$ANALYZE_DIR/jq_filter.err"; then
        log "ERROR: фильтр шаблона упал: $(tr '\n' ' ' < "$ANALYZE_DIR/jq_filter.err" | cut -c1-300)"
        return 1
    fi

    _fcount=$(jq 'length' "$ANALYZE_DIR/filtered.json" 2>/dev/null)
    [ -z "$_fcount" ] && _fcount=0

    if [ "$_fcount" -eq 0 ]; then
        log "ERROR: ни один сервер из шаблона ($_kcount ключей) не найден в подписке. Обновление отменено, конфиг не изменён."
        return 1
    fi

    cp "$ANALYZE_DIR/filtered.json" /tmp/mysub_outbounds.json
    jq 'reduce (.[] | .tag) as $t ([]; if index($t) then . else . + [$t] end)' \
        "$ANALYZE_DIR/filtered.json" > /tmp/mysub_subst.json

    log "Шаблон применён: $_fcount сервер(ов) из $_kcount ключей (порядок — как в шаблоне)."
    return 0
}

for url in $urls; do
    log "Fetching: $url"
    
    raw_b64=""
    curl_err=""
    attempt=0
    max_retries=3
    while [ $attempt -lt $max_retries ]; do
        attempt=$((attempt+1))
        # Strict TLS verification first; fall back to --insecure only if the
        # server's certificate fails to verify (curl exit 60).
        curl_err=$(curl -s -f --connect-timeout 10 --max-time 30 -H "User-Agent: v2rayN/6.23" -w "\n%{http_code}" "$url" 2>&1)
        curl_exit=$?
        if [ $curl_exit -eq 60 ]; then
            debug "TLS certificate error (exit 60), retrying with --insecure"
            curl_err=$(curl -s -f -k --connect-timeout 10 --max-time 30 -H "User-Agent: v2rayN/6.23" -w "\n%{http_code}" "$url" 2>&1)
            curl_exit=$?
        fi
        http_code=$(echo "$curl_err" | tail -1)
        raw_b64=$(echo "$curl_err" | sed '$d')

        if [ $curl_exit -eq 0 ] && [ -n "$raw_b64" ]; then
            break
        fi

        if [ $curl_exit -eq 6 ]; then
            log "WARN: Attempt $attempt/$max_retries: DNS resolution failed for $url"
        elif [ $curl_exit -eq 7 ]; then
            log "WARN: Attempt $attempt/$max_retries: Connection refused by $url"
        elif [ $curl_exit -eq 28 ]; then
            log "WARN: Attempt $attempt/$max_retries: Connection timed out for $url"
        elif [ "$http_code" = "403" ]; then
            log "WARN: Attempt $attempt/$max_retries: Access denied (403) for $url"
        elif [ "$http_code" = "404" ]; then
            log "WARN: Attempt $attempt/$max_retries: Not found (404) for $url"
        else
            log "WARN: Attempt $attempt/$max_retries: Download failed (curl exit=$curl_exit, HTTP $http_code) for $url"
        fi

        [ $attempt -lt $max_retries ] && sleep 2
    done

    if [ -z "$raw_b64" ]; then
        log "ERROR: Failed to fetch $url after $max_retries attempts. Skipping."
        continue
    fi
    debug "Downloaded ${#raw_b64} bytes from $url"

    # --- Xray JSON config array (e.g. maestro52-style subscriptions) ---
    if printf '%s' "$raw_b64" | jq -e 'type=="array" and (length>0) and (.[0]|type=="object") and (.[0]|has("outbounds"))' >/dev/null 2>&1; then
        log "Format: Xray JSON config array detected."
        if [ ! -f "$XRAY_CONV" ]; then
            log "ERROR: Converter $XRAY_CONV not found - cannot parse Xray JSON."
            continue
        fi
        if printf '%s' "$raw_b64" | jq -f "$XRAY_CONV" > /tmp/mysub_xray_conv.json 2>/tmp/mysub_xray_conv.err; then
            jq -c '.outbounds[]' /tmp/mysub_xray_conv.json > /tmp/mysub_xray_obs.txt
            while IFS= read -r ob; do
                [ -n "$ob" ] || continue
                [ "$total_parsed" -gt 0 ] && echo "," >> /tmp/mysub_outbounds.json
                echo "$ob" >> /tmp/mysub_outbounds.json
                total_parsed=$((total_parsed+1))
            done < /tmp/mysub_xray_obs.txt
            jq --slurpfile g /tmp/mysub_xray_conv.json '. + $g[0].group_tags' /tmp/mysub_subst.json > /tmp/mysub_subst.tmp && mv /tmp/mysub_subst.tmp /tmp/mysub_subst.json
            xcount=$(jq '.outbounds | length' /tmp/mysub_xray_conv.json)
            log "Xray JSON: generated $xcount outbounds (grouped by country), country groups added to selector set."
            rm -f /tmp/mysub_xray_conv.json /tmp/mysub_xray_conv.err /tmp/mysub_xray_obs.txt
        else
            log "ERROR: Xray JSON conversion failed:"
            sed 's/^/    /' /tmp/mysub_xray_conv.err | while IFS= read -r el; do log "$el"; done
            rm -f /tmp/mysub_xray_conv.json /tmp/mysub_xray_conv.err
        fi
        continue
    fi

    if echo "$raw_b64" | grep -q -E "vless://|vmess://|trojan://|hysteria2://"; then
        log "Format: Plaintext detected."
        debug "Saving plaintext to /tmp/mysub_links.txt"
        echo "$raw_b64" | tr -d '\r' > /tmp/mysub_links.txt
    else
        log "Format: Base64 detected. Decoding..."
        debug "Decoding base64 and saving to /tmp/mysub_links.txt"
        decode_base64 "$raw_b64" | tr -d '\r' > /tmp/mysub_links.txt
    fi

    count=0
    skipped=0
    while IFS= read -r link || [ -n "$link" ]; do
        link=$(echo "$link" | sed 's/^[ 	]*//;s/[ 	]*$//')
        [ -z "$link" ] && continue
        
        debug "Full link: $link"
        outbound=""
        
        case "$link" in
            vless://*)
                uri="${link#vless://}"
                
                case "$uri" in
                    *#*)
                        remarks="${uri#*#}"
                        uri="${uri%%#*}"
                        remarks=$(urldecode "$remarks")
                        remarks="${remarks} [sub-${total_parsed}]"
                        ;;
                    *) remarks="VLESS_[sub-${total_parsed}]" ;;
                esac
                
                case "$uri" in
                    *\?*)
                        query="${uri#*\?}"
                        uri="${uri%%\?*}"
                        ;;
                    *) query="" ;;
                esac
                
                case "$uri" in
                    *@*)
                        uuid="${uri%%@*}"
                        host_port="${uri#*@}"
                        ;;
                    *)
                        uuid=""
                        host_port="$uri"
                        ;;
                esac

                case "$host_port" in
                    *]*:*) server="${host_port%:*}"; port="${host_port##*:}";;
                    *]*)   server="$host_port"; port="443";;
                    *:*)   server="${host_port%:*}"; port="${host_port##*:}";;
                    *)     server="$host_port"; port="443";;
                esac
                port=$(echo "$port" | tr -d '/')
                server=$(echo "$server" | sed 's/^\[//; s/\]$//')

                type=$(echo "$query" | awk -F'type=' '{print $2}' | cut -d'&' -f1)
                security=$(echo "$query" | awk -F'security=' '{print $2}' | cut -d'&' -f1)
                sni=$(echo "$query" | awk -F'sni=' '{print $2}' | cut -d'&' -f1)
                sni=$(urldecode "$sni")
                path=$(echo "$query" | awk -F'path=' '{print $2}' | cut -d'&' -f1)
                path=$(urldecode "$path")
                host=$(echo "$query" | awk -F'host=' '{print $2}' | cut -d'&' -f1)
                pbk=$(echo "$query" | awk -F'pbk=' '{print $2}' | cut -d'&' -f1)
                sid=$(echo "$query" | awk -F'sid=' '{print $2}' | cut -d'&' -f1)
                fp=$(echo "$query" | awk -F'fp=' '{print $2}' | cut -d'&' -f1)
                allow_insecure=$(echo "$query" | awk -F'allowInsecure=' '{print $2}' | cut -d'&' -f1)
                [ -z "$allow_insecure" ] && allow_insecure=$(echo "$query" | awk -F'insecure=' '{print $2}' | cut -d'&' -f1)
                [ "$allow_insecure" = "1" ] && insecure_val="true" || insecure_val="false"
                flow=$(echo "$query" | awk -F'flow=' '{print $2}' | cut -d'&' -f1)
                alpn=$(echo "$query" | awk -F'alpn=' '{print $2}' | cut -d'&' -f1)
                alpn=$(urldecode "$alpn")

                outbound=$(jq -n \
                     --arg tag "$remarks" --arg server "$server" --arg port "${port:-443}" \
                     --arg uuid "$uuid" --arg type "$type" --arg security "$security" \
                     --arg sni "$sni" --arg path "$path" --arg host "$host" \
                     --arg pbk "$pbk" --arg sid "$sid" --arg fp "$fp" --arg insecure "$insecure_val" --arg flow "$flow" --arg alpn "$alpn" \
                     '{
                        type: "vless", tag: $tag, server: $server, server_port: ($port | tonumber), uuid: $uuid,
                        packet_encoding: "xudp",
                        flow: (if $flow != "" then $flow else null end),
                        tls: (if $security == "tls" or $security == "reality" then { 
                            enabled: true, server_name: (if $sni != "" then $sni else $server end), insecure: ($insecure == "true"),
                            utls: (if $fp != "" then { enabled: true, fingerprint: $fp } else { enabled: true, fingerprint: "chrome" } end),
                            reality: (if $security == "reality" then { enabled: true, public_key: $pbk } + (if $sid != "" then { short_id: $sid } else {} end) else null end)
                        } + (if $alpn != "" then { alpn: ($alpn | split(",")) } else {} end) | with_entries(select(.value != null)) else null end),
                        transport: (if $type == "ws" then { type: "ws", path: (if $path != "" then $path else "/" end), headers: (if $host != "" then { Host: $host } else null end) } | with_entries(select(.value != null)) elif $type == "grpc" then { type: "grpc", service_name: $path } else null end)
                    } | with_entries(select(.value != null))')
                ;;
            vmess://*)
                vmess_b64="${link#vmess://}"
                vmess_json=$(decode_base64 "$vmess_b64")
                
                v_add=$(echo "$vmess_json" | jq -r '.add // empty')
                v_port=$(echo "$vmess_json" | jq -r '.port // "443"')
                v_id=$(echo "$vmess_json" | jq -r '.id // empty')
                v_net=$(echo "$vmess_json" | jq -r '.net // "tcp"')
                v_tls=$(echo "$vmess_json" | jq -r '.tls // "none"')
                v_sni=$(urldecode "$(echo "$vmess_json" | jq -r '.sni // empty')")
                v_path=$(echo "$vmess_json" | jq -r '.path // empty')
                v_ps=$(echo "$vmess_json" | jq -r '.ps // empty')
                v_host=$(echo "$vmess_json" | jq -r '.host // empty')
                v_alpn=$(echo "$vmess_json" | jq -r '.alpn // empty')
                v_ainsecure=$(echo "$vmess_json" | jq -r '.allowInsecure // empty')
                [ -z "$v_ainsecure" ] && v_ainsecure=$(echo "$vmess_json" | jq -r '.insecure // empty')
                [ "$v_ainsecure" = "1" ] || [ "$v_ainsecure" = "true" ] && v_insecure="true" || v_insecure="false"
                
                if [ -z "$v_add" ]; then
                    log "WARN: Failed to decode vmess link (empty/invalid base64 or missing 'add' field) - skipping."
                    skipped=$((skipped+1))
                    total_skipped=$((total_skipped+1))
                    continue
                fi

                if [ -n "$v_ps" ]; then
                    v_ps="${v_ps} [sub-${total_parsed}]"
                else
                    v_ps="VMess_[sub-${total_parsed}]"
                fi

                outbound=$(jq -n \
                     --arg tag "$v_ps" --arg server "$v_add" --arg port "$v_port" \
                     --arg uuid "$v_id" --arg net "$v_net" --arg tls "$v_tls" \
                     --arg sni "$v_sni" --arg path "$v_path" --arg host "$v_host" --arg alpn "$v_alpn" --arg insecure "$v_insecure" \
                     '{
                        type: "vmess", tag: $tag, server: $server, server_port: ($port | tonumber), uuid: $uuid, security: "auto",
                        tls: (if $tls == "tls" then { enabled: true, server_name: (if $sni != "" then $sni else $server end), insecure: ($insecure == "true"), utls: { enabled: true, fingerprint: "chrome" } } + (if $alpn != "" then { alpn: ($alpn | split(",")) } else {} end) else null end),
                        transport: (if $net == "ws" then { type: "ws", path: (if $path != "" then $path else "/" end), headers: (if $host != "" then { Host: $host } else null end) } | with_entries(select(.value != null)) elif $net == "grpc" then { type: "grpc", service_name: $path } else null end)
                    } | with_entries(select(.value != null))')
                ;;
            trojan://*)
                uri="${link#trojan://}"
                
                case "$uri" in
                    *#*)
                        remarks="${uri#*#}"
                        uri="${uri%%#*}"
                        remarks=$(urldecode "$remarks")
                        remarks="${remarks} [sub-${total_parsed}]"
                        ;;
                    *) remarks="Trojan_[sub-${total_parsed}]" ;;
                esac
                
                case "$uri" in
                    *\?*)
                        query="${uri#*\?}"
                        uri="${uri%%\?*}"
                        ;;
                    *) query="" ;;
                esac
                
                case "$uri" in
                    *@*)
                        password="${uri%%@*}"
                        host_port="${uri#*@}"
                        ;;
                    *)
                        password=""
                        host_port="$uri"
                        ;;
                esac

                case "$host_port" in
                    *]*:*) server="${host_port%:*}"; port="${host_port##*:}";;
                    *]*)   server="$host_port"; port="443";;
                    *:*)   server="${host_port%:*}"; port="${host_port##*:}";;
                    *)     server="$host_port"; port="443";;
                esac
                port=$(echo "$port" | tr -d '/')
                server=$(echo "$server" | sed 's/^\[//; s/\]$//')

                type=$(echo "$query" | awk -F'type=' '{print $2}' | cut -d'&' -f1)
                security=$(echo "$query" | awk -F'security=' '{print $2}' | cut -d'&' -f1)
                sni=$(echo "$query" | awk -F'sni=' '{print $2}' | cut -d'&' -f1)
                sni=$(urldecode "$sni")
                path=$(echo "$query" | awk -F'path=' '{print $2}' | cut -d'&' -f1)
                path=$(urldecode "$path")
                host=$(echo "$query" | awk -F'host=' '{print $2}' | cut -d'&' -f1)
                pbk=$(echo "$query" | awk -F'pbk=' '{print $2}' | cut -d'&' -f1)
                sid=$(echo "$query" | awk -F'sid=' '{print $2}' | cut -d'&' -f1)
                fp=$(echo "$query" | awk -F'fp=' '{print $2}' | cut -d'&' -f1)
                allow_insecure=$(echo "$query" | awk -F'allowInsecure=' '{print $2}' | cut -d'&' -f1)
                [ -z "$allow_insecure" ] && allow_insecure=$(echo "$query" | awk -F'insecure=' '{print $2}' | cut -d'&' -f1)
                [ "$allow_insecure" = "1" ] && insecure_val="true" || insecure_val="false"
                alpn=$(echo "$query" | awk -F'alpn=' '{print $2}' | cut -d'&' -f1)
                alpn=$(urldecode "$alpn")

                outbound=$(jq -n \
                     --arg tag "$remarks" --arg server "$server" --arg port "${port:-443}" \
                     --arg password "$password" --arg type "$type" --arg security "$security" \
                     --arg sni "$sni" --arg path "$path" --arg host "$host" \
                     --arg pbk "$pbk" --arg sid "$sid" --arg fp "$fp" --arg insecure "$insecure_val" --arg alpn "$alpn" \
                     '{
                        type: "trojan", tag: $tag, server: $server, server_port: ($port | tonumber), password: $password,
                        tls: (if $security != "none" and $security != "" then { 
                            enabled: true, server_name: (if $sni != "" then $sni else $server end), insecure: ($insecure == "true"),
                            utls: (if $fp != "" then { enabled: true, fingerprint: $fp } else { enabled: true, fingerprint: "chrome" } end),
                            reality: (if $security == "reality" then { enabled: true, public_key: $pbk } + (if $sid != "" then { short_id: $sid } else {} end) else null end)
                        } + (if $alpn != "" then { alpn: ($alpn | split(",")) } else {} end) | with_entries(select(.value != null)) else null end),
                        transport: (if $type == "ws" then { type: "ws", path: (if $path != "" then $path else "/" end), headers: (if $host != "" then { Host: $host } else null end) } | with_entries(select(.value != null)) elif $type == "grpc" then { type: "grpc", service_name: $path } else null end)
                    } | with_entries(select(.value != null))')
                ;;
            hysteria2://*)
                uri="${link#hysteria2://}"
                
                case "$uri" in
                    *#*)
                        remarks="${uri#*#}"
                        uri="${uri%%#*}"
                        remarks=$(urldecode "$remarks")
                        remarks="${remarks} [sub-${total_parsed}]"
                        ;;
                    *) remarks="Hysteria2_[sub-${total_parsed}]" ;;
                esac
                
                case "$uri" in
                    *\?*)
                        query="${uri#*\?}"
                        uri="${uri%%\?*}"
                        ;;
                    *) query="" ;;
                esac
                
                case "$uri" in
                    *@*)
                        password="${uri%%@*}"
                        host_port="${uri#*@}"
                        ;;
                    *)
                        password=""
                        host_port="$uri"
                        ;;
                esac

                case "$host_port" in
                    *]*:*) server="${host_port%:*}"; port="${host_port##*:}";;
                    *]*)   server="$host_port"; port="443";;
                    *:*)   server="${host_port%:*}"; port="${host_port##*:}";;
                    *)     server="$host_port"; port="443";;
                esac
                port=$(echo "$port" | tr -d '/')
                server=$(echo "$server" | sed 's/^\[//; s/\]$//')

                sni=$(echo "$query" | awk -F'sni=' '{print $2}' | cut -d'&' -f1)
                sni=$(urldecode "$sni")
                obfs=$(echo "$query" | awk -F'obfs=' '{print $2}' | cut -d'&' -f1)
                obfs_password=$(echo "$query" | awk -F'obfs-password=' '{print $2}' | cut -d'&' -f1)
                obfs_password=$(urldecode "$obfs_password")
                insecure=$(echo "$query" | awk -F'insecure=' '{print $2}' | cut -d'&' -f1)
                [ "$insecure" = "1" ] && insecure_val="true" || insecure_val="false"

                outbound=$(jq -n \
                     --arg tag "$remarks" --arg server "$server" --arg port "${port:-443}" \
                     --arg password "$password" --arg sni "$sni" --arg obfs "$obfs" --arg obfs_password "$obfs_password" --arg insecure "$insecure_val" \
                     '{
                        type: "hysteria2", tag: $tag, server: $server, server_port: ($port | tonumber), password: $password,
                        up_mbps: 0, down_mbps: 0,
                        tls: { enabled: true, server_name: (if $sni != "" then $sni else $server end), insecure: ($insecure == "true"), alpn: ["h3"] },
                        obfs: (if $obfs != "" then { type: $obfs, password: $obfs_password } else null end)
                    } | with_entries(select(.value != null))')
                ;;
            *)
                scheme="${link%%://*}"
                [ "$scheme" = "$link" ] && scheme="(no scheme)"
                log "WARN: Unsupported link type '${scheme}://' - skipping (not vless/vmess/trojan/hysteria2)."
                skipped=$((skipped+1))
                total_skipped=$((total_skipped+1))
                ;;
        esac

        if [ -n "$outbound" ] && echo "$outbound" | grep -q '"server"'; then
            debug "Successfully generated outbound JSON for this link."
            [ "$total_parsed" -gt 0 ] && echo "," >> /tmp/mysub_outbounds.json
            echo "$outbound" >> /tmp/mysub_outbounds.json
            _t=$(echo "$outbound" | jq -r '.tag // empty')
            jq --arg t "$_t" '. + [$t]' /tmp/mysub_subst.json > /tmp/mysub_subst.tmp && mv /tmp/mysub_subst.tmp /tmp/mysub_subst.json
            count=$((count+1))
            total_parsed=$((total_parsed+1))
        else
            log "WARN: Recognized link but failed to produce a valid outbound (malformed URI?)."
            debug "Failed to parse or missing server field. Outbound was: $outbound"
            skipped=$((skipped+1))
            total_skipped=$((total_skipped+1))
        fi
    done < /tmp/mysub_links.txt
    
    rm -f /tmp/mysub_links.txt
    log "Found $count valid servers. Skipped $skipped unsupported/unparsed link(s)."
done

echo "]" >> /tmp/mysub_outbounds.json
log "Total servers parsed: $total_parsed. Total skipped: $total_skipped."

# --- Режим анализа: замер, сортировка и запись шаблона. Конфиг не трогаем. ---
if [ "$ANALYZE_MODE" = "1" ]; then
    if run_analysis; then
        log "=== Анализ завершён (основной конфиг не изменялся) ==="
        rm -f /tmp/mysub_outbounds.json
        exit 0
    fi
    log "=== Анализ завершён с ошибкой ==="
    rm -f /tmp/mysub_outbounds.json
    exit 1
fi

# --- Шаблон анализа включён: оставляем только серверы из шаблона ---
if template_enabled; then
    if ! apply_server_template; then
        log "Обновление прервано: конфиг оставлен без изменений, старые серверы продолжают работать."
        rm -f /tmp/mysub_outbounds.json
        exit 1
    fi
else
    debug "Шаблон анализа выключен — используются все найденные серверы."
fi

if [ "$total_parsed" -gt 0 ]; then
    log "Merging with base config ($base_config) using marker method..."
    
    jq --slurpfile new_obs /tmp/mysub_outbounds.json --slurpfile subst /tmp/mysub_subst.json '
      # 1. Tags for {all_subs} replacement (link nodes + Xray country groups)
      ($subst[0]) as $new_tags |
      
      # 2. Append new outbounds to existing outbounds array
      .outbounds = (if .outbounds then .outbounds else [] end) |
      .outbounds += $new_obs[0] |
      
      # 3. Replace {all_subs} marker with new tags in selector/urltest groups
      .outbounds = [
        .outbounds[] |
        if has("outbounds") and (.type == "selector" or .type == "urltest") then
          if (.outbounds | index("{all_subs}")) != null then
            .outbounds = (.outbounds - ["{all_subs}"] + $new_tags)
          else 
            . 
          end
        else 
          . 
        end
      ]
    ' "$base_config" > /tmp/mysub_config.json 2> /tmp/jq_merge_err.log
    
    if [ $? -eq 0 ] && jq empty < /tmp/mysub_config.json 2>/dev/null; then
        mv /tmp/mysub_config.json "$output_config"
        log "SUCCESS: Validation passed. Output saved to $output_config"
        log "Config updated successfully. Restart your service manually if needed."
    else
        log "ERROR: Invalid JSON generated or merge failed. Restart aborted!"
        if [ -f /tmp/jq_merge_err.log ]; then
            err_msg=$(cat /tmp/jq_merge_err.log | tr '\n' ' ')
            log "JQ ERROR DETAILS: $err_msg"
        fi
        rm -f /tmp/mysub_config.json
    fi
else
    log "No servers to add. Skipping."
fi

rm -f /tmp/mysub_outbounds.json
log "=== Done ==="