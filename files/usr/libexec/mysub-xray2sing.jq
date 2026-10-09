def country_of($r):
  ([ ($r // "") | explode[] | select(
       (. >= 65 and . <= 90) or (. >= 97 and . <= 122) or
       (. >= 1040 and . <= 1103) or . == 1025 or . == 1105 or . == 32
     ) ] | implode) as $clean
  | [ $clean | split(" ") | .[] | select(. != "") ] as $words
  | ( [ $words | to_entries[] | (.value) as $w | select((["\u0421\u0442\u0430\u0431\u0438\u043b\u044c\u043d\u044b\u0439","\u041c\u0430\u043a\u0441","\u0411\u0435\u043b\u044b\u0439","\u0411\u0435\u043b\u044b\u0435","\u041f\u043e\u043b\u043d\u044b\u0439","\u0427\u0430\u0441\u0442\u0438\u0447\u043d\u044b\u0439","\u041c\u043e\u0431\u0438\u043b\u044c\u043d\u044b\u0439","\u041f\u0440\u044f\u043c\u043e\u0435","\u0441\u043f\u0438\u0441\u043e\u043a","\u0441\u043f\u0438\u0441\u043a\u0438","\u043e\u0431\u0445\u043e\u0434","\u0441\u043a\u043e\u0440\u043e\u0441\u0442\u044c","\u043f\u043e\u0434\u043a\u043b\u044e\u0447\u0435\u043d\u0438\u0435","\u0441\u043e\u0446\u0441\u0435\u0442\u0438"] | index($w)) != null) | .key ] | first ) as $stop
  | ( if $stop == null then $words else $words[0:$stop] end ) as $cw
  | ( ($cw | join(" ")) as $s | if $s == "" then "other" else $s end );

(if type=="array" then . else [.] end) as $_in
| [
  $_in[] | (.remarks // "") as $r | (country_of($r)) as $country
  | (.outbounds // [])[]
  | select((.protocol // "") == "vless" or (.protocol // "") == "trojan")
  | (((.streamSettings // {}).network) // "tcp") as $net
  | select($net != "xhttp")
  | (((.settings // {}).vnext // ((.settings // {}).servers) // [])[0]) as $v
  | select(($v != null) and ((($v.address // "")) != ""))
  | (.streamSettings // {}) as $ss
  | (($ss.realitySettings // {})) as $rs
  | (($ss.tlsSettings // {})) as $ts
  | (($ss.security // "")) as $sec
  | {
      country: $country,
      ob: (
        {
          type: (if .protocol == "vless" then "vless" else "trojan" end),
          tag: "",
          server: $v.address,
          server_port: (($v.port // 443) | tonumber),
          packet_encoding: "xudp"
        }
        + (if .protocol == "vless" then { uuid: ((($v.users // [])[0].id) // "") } else { password: ((($v.users // [])[0].password) // ($v.password // "")) } end)
        + (if (((($v.users // [])[0].flow) // "")) != "" then { flow: $v.users[0].flow } else {} end)
        + (if ($sec == "tls" or $sec == "reality") then {
              tls: (
                {
                  enabled: true,
                  server_name: ((($rs.serverName // $ts.serverName)) // $v.address),
                  insecure: (if (((($ts.allowInsecure // $ts.insecure) // 0)) == true or ((($ts.allowInsecure // $ts.insecure) // 0)) == 1) then true else false end),
                  utls: { enabled: true, fingerprint: ((($rs.fingerprint // $ts.fingerprint)) // "chrome") }
                }
                + (if $sec == "reality" then { reality: ({ enabled: true, public_key: (($rs.publicKey // "")) } + (if (($rs.shortId // "")) != "" then { short_id: $rs.shortId } else {} end)) } else {} end)
                + (if (($ts.alpn // null)) != null then { alpn: $ts.alpn } else {} end)
              )
            } else {} end)
        + (if $net == "grpc" then { transport: { type: "grpc", service_name: ((($ss.grpcSettings // {}).serviceName) // "") } }
           elif $net == "ws" then { transport: ({ type: "ws", path: ((($ss.wsSettings // {}).path) // "/") } + (if ((($ss.wsSettings // {}).host) // "") != "" then { headers: { Host: $ss.wsSettings.host } } else {} end)) }
           else {} end)
      )
    }
] as $nodes
| ($nodes | group_by(.country)) as $groups
| {
    outbounds: (
      [ $groups[]
        | (.[0].country) as $c
        | ( . | to_entries | map({ tag: ($c + " n" + (((.key + 1)) | tostring)), node: .value }) ) as $tg
        | ( $tg | map( .node.ob + { tag: .tag } ) )
        + [ { type: "urltest", tag: ($c + " auto"), outbounds: ($tg | map(.tag)), url: "https://www.gstatic.com/generate_204", interval: "1m", tolerance: 100, interrupt_exist_connections: true } ]
      ] | add // []
    ),
    group_tags: ( [ $groups[] | (.[0].country + " auto") ] )
  }
