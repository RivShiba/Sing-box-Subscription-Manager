#!/bin/sh
# : /usr/libexec/mysub-update.sh
# : chmod +x /usr/libexec/mysub-update.sh

CONFIG_FILE="/etc/config/mysub"
LOG_FILE="/var/log/mysub.log"

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

log "Base config: $base_config"
log "Output config: $output_config"

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

if [ -z "$urls" ]; then
    log "No URLs to parse."
    exit 1
fi

echo "[" > /tmp/mysub_outbounds.json
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

for url in $urls; do
    log "Fetching: $url"
    
    raw_b64=""
    curl_err=""
    attempt=0
    max_retries=3
    while [ $attempt -lt $max_retries ]; do
        attempt=$((attempt+1))
        curl_err=$(curl -s -f --connect-timeout 10 --max-time 30 -H "User-Agent: v2rayN/6.23" -w "\n%{http_code}" "$url" 2>&1)
        curl_exit=$?
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
                v_sni=$(echo "$vmess_json" | jq -r '.sni // empty')
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

if [ "$total_parsed" -gt 0 ]; then
    log "Merging with base config ($base_config) using marker method..."
    
    jq --slurpfile new_obs /tmp/mysub_outbounds.json '
      # 1. Collect tags of all new outbounds
      ($new_obs[0] | map(.tag)) as $new_tags |
      
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