local m, s, urls, base, out, cron, log_level, btn, log, config_view

-- Возвращает установленную версию пакета от пакетного менеджера (apk/opkg).
-- "" если не определяется.
local function installed_version()
    local out, ver = "", ""
    if nixio.fs.access("/usr/bin/apk") then
        local h = io.popen("apk list --installed 2>/dev/null | grep '^luci-app-mysub-'")
        if h then out = h:read("*a") or ""; h:close() end
    else
        local h = io.popen("opkg status luci-app-mysub 2>/dev/null | grep '^Version:'")
        if h then out = h:read("*a") or ""; h:close() end
    end
    ver = out:match("([%d%.]+%-?r?%d*)") or ""
    return ver:match("^%s*$") and "" or ver
end

m = Map("mysub", translate("Sing-box Subscription Manager"), translate("Управление VLESS/VMess/Trojan/Hysteria2 подписками."))

-- ИСПОЛЬЗУЕМ NamedSection, так как конфиг имеет вид: config mysub 'main'
s = m:section(NamedSection, "main", "mysub", "")

-- Создаем вкладки (Tabs) для удобного интерфейса
s:tab("general", translate("Настройки / Settings"))
s:tab("analysis", translate("Анализ подписок / Subscription Analysis"))
s:tab("logs", translate("Логи / Logs"))
s:tab("config", translate("Готовый конфиг / Result Config"))

-- ================= Вкладка General =================
local ver = s:taboption("general", Value, "_version", translate("Installed Version"), translate("Текущая установленная версия пакета."))
ver.default = installed_version()
ver.rmempty = true
ver.readonly = true

urls = s:taboption("general", DynamicList, "urls", translate("Subscription URLs"), translate("Ссылки на подписки (v2rayN, Base64)."))

base = s:taboption("general", Value, "base_config", translate("Base Config File"), translate("Путь к базовому конфигу (в него добавятся прокси)."))
base.default = "/etc/mysub/template.json"

out = s:taboption("general", Value, "output_config", translate("Output Config File"), translate("Куда сохранить результат (Base + Подписки)."))
out.default = "/etc/mysub/mysub.json"

cron = s:taboption("general", Value, "cron", translate("Cron Interval"), translate("Стандартный формат cron, например '0 4 * * *'."))
cron.default = "0 4 * * *"

log_level = s:taboption("general", ListValue, "log_level", translate("Log Level"), translate("Уровень детализации логов."))
log_level:value("info", "Info")
log_level:value("debug", "Debug")
log_level.default = "info"

btn = s:taboption("general", Button, "_update", translate("Update Now"))
btn.inputtitle = translate("Run Update")
btn.inputstyle = "action"
btn.description = translate("Запустить скачивание и парсинг подписок прямо сейчас.")
btn.write = function(self, section)
    m.uci:commit("mysub")
    os.execute("/usr/libexec/mysub-update.sh > /dev/null 2>&1 &")
end

-- ================= Вкладка Analysis =================
local use_tpl = s:taboption("analysis", Flag, "use_analysis_template",
    translate("Использовать шаблон анализа"),
    translate("Если включено, парсер добавляет в конфиг только серверы из шаблона и в том порядке, в котором они записаны в шаблоне. Если выключено — добавляются все найденные серверы, как раньше."))
use_tpl.default = "0"
use_tpl.enabled = "1"
use_tpl.disabled = "0"

local max_delay = s:taboption("analysis", Value, "max_delay_ms",
    translate("Максимальная задержка (мс)"),
    translate("Замеряется реальным подключением через sing-box (не ICMP), поэтому файрволы хостеров не мешают. Серверы медленнее этого значения в шаблон не попадут. Для Reality-серверов рекомендуется 1500–2500: реальная задержка заметно шумнее, чем ICMP."))
max_delay.default = "500"
max_delay.datatype = "uinteger"

local excl = s:taboption("analysis", DynamicList, "exclude_keywords",
    translate("Слова-исключения"),
    translate("Сервер, в названии (теге) которого встречается любое из этих слов, не попадёт в шаблон. Регистр учитывается только для русских слов (ограничение BusyBox), для латиницы — не учитывается."))

local st = s:taboption("analysis", TextValue, "analysis_status",
    translate("Результат последнего анализа"),
    translate("Время завершения, длительность и итог последнего анализа. Заполняется кнопкой ниже; чтобы увидеть свежий результат, обновите страницу (F5)."))
st.readonly = true
-- readonly-поле не должно попадать в UCI при сохранении формы
st.write = function(self, section) end
st.rows = 3
st.cfgvalue = function(self, section)
    return m.uci:get("mysub", section, "analysis_status") or translate("Анализ ещё не запускался.")
end

local btn_an = s:taboption("analysis", Button, "_analyze", translate("Анализ подписок"))
btn_an.inputtitle = translate("Сделать анализ подписок")
btn_an.inputstyle = "apply"
btn_an.description = translate("Скачать подписки, отбросить серверы по словам-исключениям, замерить реальную задержку каждого сервера и отсортировать по возрастанию. Результат пишется в поле «Шаблон серверов». Текущий конфиг и запущенный сервис не затрагиваются. Занимает ~30–60 секунд и выполняется в фоне, LuCI при этом не блокируется: после завершения обновите страницу (F5) — время и итог появятся в поле «Результат последнего анализа». ВАЖНО: сам анализ конфиг не меняет, чтобы серверы попали в конфиг, после анализа нажмите «Run Update» (или дождитесь cron).")
btn_an.write = function(self, section)
    m.uci:commit("mysub")
    os.execute("/usr/libexec/mysub-update.sh --analyze > /dev/null 2>&1 &")
end

local tpl = s:taboption("analysis", TextValue, "server_template",
    translate("Шаблон серверов"),
    translate("Список серверов в формате адрес:порт, по одному в строке. Генерируется кнопкой анализа, но можно править вручную. В конфиг попадут только строки БЕЗ решётки в начале — именно они и есть список активных серверов; строки, начинающиеся с #, игнорируются, в них анализ показывает отсеянные серверы с причиной (для справки, их можно удалить). Работает, только если включена галочка выше. Привязка идёт к адресу и порту (а не к названию), поэтому шаблон не ломается при изменении состава подписки."))
tpl.rows = 22
tpl.wrap = "off"
tpl.rmempty = false
tpl.cfgvalue = function(self, section)
    local v = m.uci:get_list("mysub", section, "server_template") or {}
    return table.concat(v, "\n")
end
tpl.write = function(self, section, value)
    -- UCI не умеет хранить многострочный option, поэтому держим список (list).
    -- В luci.model.uci доступен только set_list (метода add_list нет).
    local vals = {}
    for line in tostring(value or ""):gmatch("[^\r\n]+") do
        local s_line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if s_line ~= "" then
            vals[#vals + 1] = s_line
        end
    end
    m.uci:set_list("mysub", section, "server_template", vals)
end

-- ================= Вкладка Logs =================
local get_log_url = luci.dispatcher.build_url("admin", "services", "mysub", "get_log")
log = s:taboption("logs", TextValue, "_log", translate("Parser Log"), translate("История выполнения скрипта. Логи обновляются автоматически каждые 2 секунды.") .. 
    [[<br/><br/><button class="btn cbi-button cbi-button-apply" type="button" onclick="
        var ta = document.getElementById('cbid.mysub.main._log');
        if (ta) {
            XHR.get(']] .. get_log_url .. [[', null,
                function(x) {
                    if (x && x.responseText) {
                        ta.value = x.responseText;
                        ta.scrollTop = ta.scrollHeight;
                    }
                }
            );
        }
    ">Refresh Logs</button>
    <script type="text/javascript">
        setInterval(function() {
            var ta = document.getElementById('cbid.mysub.main._log');
            if (ta && ta.offsetParent !== null) { // only if visible
                XHR.get(']] .. get_log_url .. [[', null,
                    function(x) {
                        if (x && x.responseText && ta.value !== x.responseText) {
                            var isBottom = (ta.scrollHeight - ta.offsetHeight) - ta.scrollTop < 20;
                            ta.value = x.responseText;
                            if (isBottom) {
                                ta.scrollTop = ta.scrollHeight;
                            }
                        }
                    }
                );
            }
        }, 2000);
    </script>]])
log.readonly = true
-- readonly-поля не должны попадать в UCI: иначе лог (и полный JSON конфига)
-- копится в /etc/config/mysub и изнашивает флеш-память роутера.
log.write = function(self, section) end
log.rows = 20
log.cfgvalue = function(self, section)
    return nixio.fs.readfile("/var/log/mysub.log") or "Логи пусты. Нажмите 'Run Update', чтобы запустить парсер."
end

-- ================= Вкладка Config =================
config_view = s:taboption("config", TextValue, "_config_view", translate("Generated Config (JSON)"), translate("Финальный результат после слияния базового конфига и скачанных серверов."))
config_view.readonly = true
config_view.write = function(self, section) end
config_view.rows = 30
config_view.cfgvalue = function(self, section)
    local out_path = m.uci:get("mysub", "main", "output_config") or "/etc/mysub/mysub.json"
    return nixio.fs.readfile(out_path) or "Конфиг еще не сгенерирован или файл не найден."
end

-- Хук для обновления crontab при сохранении настроек
function m.on_after_commit(self)
    local c = m.uci:get("mysub", "main", "cron")
    os.execute("sed -i '/mysub-update/d' /etc/crontabs/root 2>/dev/null")
    if c and c ~= "" then
        -- shellquote() prevents cron (a free-text UCI value) from being
        -- interpreted as shell syntax, e.g. "0 4 * * *'; rm -rf / #"
        local safe_line = luci.util.shellquote(c .. " /usr/libexec/mysub-update.sh")
        os.execute("echo " .. safe_line .. " >> /etc/crontabs/root")
    end
    os.execute("/etc/init.d/cron restart")
end

return m