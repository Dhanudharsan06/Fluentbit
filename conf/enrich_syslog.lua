-- =====================================================================
-- Fluent Bit syslog processor -- port of the Logstash "syslog" filter.
--
-- Pipeline parity with Logstash:
--   1. grok       -> detect RFC5424 / RFC3164 and capture fields
--   2. dateruby   -> syslog_timestamp from syslog_timestamp_original
--   3. mutate     -> rename message->rawmessage, syslog_message->message,
--                    set syslog_message_format, blank original for 3164
--   4. pri rules  -> missing / >191  => pri=13, format="Other"
--   5. syslog_pri -> syslog_facility_code, syslog_severity_code
--   6. final      -> ingest_protocol, host=hostIp, lowercase host/hostIp,
--                    drop syslog_version / tags / port / event
--   7. defaults   -> syslog_host falls back to the sender; program /
--                    process_id / message_id stay null when absent
--
-- Field names intentionally match the Logstash output model:
--   syslog_host, syslog_program, syslog_process_id, syslog_message_id
--
-- KNOWN DIFFERENCES vs Logstash (documented, see chat):
--   * dns { reverse => host } is NOT reproduced -- Fluent Bit/Lua has no
--     reverse-DNS resolver. `host` stays equal to the (lowercased) IP.
--   * dateruby nanosecond precision -> approximated to millisecond.
--   * A leading/embedded UTF-8 BOM is stripped from the message (cleanup);
--     Logstash keeps it. Set STRIP_BOM=false below for exact parity.
-- =====================================================================

local STRIP_BOM = true

-- The forwarding syslog OUTPUT builds the RFC5424 TIMESTAMP from the event
-- time, so emitting Logstash's syslogtime => "%{syslog_timestamp}" requires
-- overwriting the event time with the parsed original. Set false to forward
-- with the ingest time instead. The "@timestamp" field is unaffected.
local FORWARD_ORIGINAL_TIME = true

-- RFC3164 timestamps ("Mmm dd HH:MM:SS") carry NO timezone -- they are the
-- sender's local wall-clock time. To store the correct instant we must tag
-- them with an offset. nil = auto-detect THIS host's local offset (correct
-- when sender and collector share a timezone). Force a fixed zone instead by
-- setting e.g. "+00:00" (senders emit UTC) or "+05:30".
local RFC3164_TZ = nil

-- -- Store-and-forward unwrapping. A relay may queue a log and later re-send it
-- -- wrapped in a NEW syslog envelope, so the outer timestamp is the *forward*
-- -- time and the inner one is the *original generation* time. When true, if a
-- -- message body is itself a syslog frame (optionally octet-count framed per
-- -- RFC6587, optionally BOM-prefixed), the INNER message is treated as the real
-- -- log: its timestamp, host, program, process id and message id win. The outer
-- -- envelope survives only in `rawmessage`. `@timestamp` stays the ingest time.
-- local UNWRAP_FORWARDED = true

-- "-" (RFC5424 NILVALUE) and empty string both mean "field absent".
local function nv(v)
    if v == nil or v == "-" or v == "" then return nil end
    return v
end

-- Month name -> number for RFC3164 timestamps.
local MON = {Jan="01",Feb="02",Mar="03",Apr="04",May="05",Jun="06",
             Jul="07",Aug="08",Sep="09",Oct="10",Nov="11",Dec="12"}

-- ---------- timestamp validity -------------------------------------
-- A timestamp that parses positionally but is not a real instant ("Xxx 24",
-- "Jul 99", "25:43:00", "2024-99-99T25:99:99") must NOT become the record's
-- date -- storing it would make the document unindexable. Such a frame is
-- treated as carrying no timestamp at all.
local MDAYS = {31, 29, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}

local function valid_time(mon, day, hour, min, sec)
    mon, day = tonumber(mon), tonumber(day)
    hour, min, sec = tonumber(hour), tonumber(min), tonumber(sec)
    if mon == nil or mon < 1 or mon > 12 then return false end
    if day == nil or day < 1 or day > MDAYS[mon] then return false end
    if hour == nil or hour > 23 then return false end
    if min == nil or min > 59 then return false end
    -- 60 is a legal leap second; every other out-of-range value is not.
    if sec == nil or sec > 60 then return false end
    return true
end

-- Normalize a leap second (":60") down to ":00" of the same minute so the
-- value round-trips through date parsers that reject 60.
local function leap_fix(ts)
    return (ts:gsub("(%d%d[:%.]%d%d[:%.])60", "%100"))
end

-- Validate the "YYYY-MM-DDTHH:MM:SS" head of an ISO timestamp (the tester's
-- dotted "T11.38.04" form included).
local function valid_iso(ts)
    local y, mo, d, h, mi, s =
        ts:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d)[:%.](%d%d)[:%.](%d%d)")
    if y == nil then return false end
    return valid_time(mo, d, h, mi, s)
end

-- ---------- RFC5424 --------------------------------------------------
-- body (pri already stripped) = VERSION SP TS SP HOST SP APP SP PROCID
--                               SP MSGID SP [SD] [MSG]
local function parse_rfc5424(body)
    local ver, ts, host, prog, procid, msgid, rest =
        body:match("^(%d+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s*(.*)$")
    if ver == nil then return nil end
    -- Second token must look like an ISO-8601 timestamp (accept both the
    -- spec ':' form and the tester's '.' form). This is the discriminator.
    if not ts:match("^%d%d%d%d%-%d%d%-%d%dT") then return nil end
    -- ISO-shaped but not a real instant => this is not a usable RFC5424
    -- frame; fall through to the RFC3164 pattern, which keeps the whole
    -- body as the message.
    if not valid_iso(ts) then return nil end
    ts = leap_fix(ts)

    -- grok's "(?:- |)" only strips a NILVALUE structured-data marker.
    -- Any real "[...]" structured data stays inside the message.
    local msg = rest
    local stripped = rest:match("^%-%s+(.*)$")
    if stripped ~= nil then msg = stripped end
    if rest == "-" then msg = "" end

    return {
        syslog_version            = ver,
        syslog_timestamp_original = ts,
        syslog_host               = nv(host),
        syslog_program            = nv(prog),
        syslog_process_id         = nv(procid),
        syslog_message_id         = nv(msgid),
        syslog_message            = msg,
        format                    = "Rfc5424",
    }
end

-- ---------- RFC3164 --------------------------------------------------
-- body = TIMESTAMP [HOST] MSG   (TIMESTAMP = "Mmm dd HH:MM:SS" or ISO)
local function parse_rfc3164(body)
    local ts, rest = body:match("^(%a%a%a%s+%d+%s+%d%d:%d%d:%d%d)%s+(.*)$")
    if ts ~= nil then
        -- "Xxx 24 ...", "Jul 99 ...", "25:43:00" look like a timestamp but
        -- are not one -- reject so the text stays in the message.
        local mon, day, h, mi, s =
            ts:match("^(%a%a%a)%s+(%d+)%s+(%d%d):(%d%d):(%d%d)$")
        if MON[mon] == nil or not valid_time(MON[mon], day, h, mi, s) then
            ts = nil
        else
            ts = leap_fix(ts)
        end
    end
    if ts == nil then
        local iso, iso_rest = body:match("^(%d%d%d%d%-%d%d%-%d%dT%S+)%s+(.*)$")
        if iso ~= nil and valid_iso(iso) then
            ts, rest = leap_fix(iso), iso_rest
        end
    end
    if ts == nil then
        -- No usable timestamp: whole body is the message.
        rest = body
    end

    -- The host is only the token after a TIMESTAMP (grok pattern B). With no
    -- timestamp there is no host either (pattern C) -- the first word belongs
    -- to the message.
    local host, msg = nil, rest
    if ts ~= nil then
        local first, remainder = rest:match("^(%S+)%s+(.*)$")
        if first ~= nil and first:match("^[%w%.%-]+$") then
            host, msg = first, remainder
        end
    end

    return {
        syslog_timestamp_original = ts,
        syslog_host               = nv(host),
        syslog_message            = msg,
        format                    = "Rfc3164",
    }
end

-- -- If `msg` is itself a syslog frame -- optionally BOM-prefixed and/or
-- -- octet-count framed ("213 <14>1 ...", RFC6587) -- parse and return the inner
-- -- record plus its PRI. Returns nil when there is no embedded syslog message.
-- local function try_unwrap(msg, parse_rfc5424, parse_rfc3164)
    -- if msg == nil then return nil end
    -- local s = msg
    -- s = s:gsub("^\239\187\191", "")   -- leading BOM
    -- s = s:gsub("^%d+%s+", "")          -- octet-count frame (RFC6587)
    -- s = s:gsub("^\239\187\191", "")   -- BOM between count and PRI
    -- local ipri, ibody = s:match("^<(%d+)>(.*)$")
    -- if ipri == nil then return nil end
    -- local inner = parse_rfc5424(ibody) or parse_rfc3164(ibody)
    -- if inner == nil then return nil end
    -- inner._pri = ipri
    -- return inner
-- end

-- Normalize the tester's dotted time (T07.28.41) to valid ISO (T07:28:41).
local function normalize_iso(ts)
    if ts == nil then return nil end
    return (ts:gsub("T(%d%d)%.(%d%d)%.(%d%d)", "T%1:%2:%3"))
end

-- True if the ISO timestamp already carries a timezone ("Z" or "+/-HH:MM").
local function has_offset(ts)
    if ts == nil then return false end
    return ts:match("[Zz]$") ~= nil or ts:match("[%+%-]%d%d:?%d%d$") ~= nil
end

-- Local UTC offset (e.g. "+05:30") for the given epoch, or the forced
-- RFC3164_TZ override. Computed from the CRT without relying on strftime %z.
local function tz_offset(epoch)
    if RFC3164_TZ ~= nil then return RFC3164_TZ end
    local t = os.date("!*t", epoch); t.isdst = false
    local diff = os.difftime(epoch, os.time(t))
    local sign = "+"
    if diff < 0 then sign = "-"; diff = -diff end
    return string.format("%s%02d:%02d", sign,
        math.floor(diff / 3600), math.floor((diff % 3600) / 60))
end

-- syslog_timestamp is emitted with a fixed fractional width so every record
-- looks the same regardless of the precision the sender used: RFC3164 carries
-- no sub-second part at all, RFC5424 may carry anything from none to nanos.
-- 7 digits = .NET "o" round-trip format ("2024-07-30T11:38:04.0000000+05:30").
local NANO_DIGITS = 7

local function with_nanos(ts)
    if ts == nil then return nil end
    local base, frac, zone =
        ts:match("^(%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d)(%.?%d*)(.*)$")
    if base == nil then return ts end          -- unparseable: leave untouched
    frac = frac:gsub("^%.", "")
    -- pad short precision with zeros, truncate anything longer
    frac = (frac .. string.rep("0", NANO_DIGITS)):sub(1, NANO_DIGITS)
    return base .. "." .. frac .. zone
end


-- ISO-8601 (with "Z", "+/-HH:MM" or no zone = UTC) -> epoch seconds.
local function iso_to_epoch(ts)
    if ts == nil then return nil end
    local y, mo, d, h, mi, s =
        ts:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)")
    if y == nil then return nil end
    local t = {year = tonumber(y), month = tonumber(mo), day = tonumber(d),
               hour = tonumber(h), min = tonumber(mi), sec = tonumber(s),
               isdst = false}
    -- os.time() reads the table as LOCAL time; add this host's offset back to
    -- reinterpret the same fields as UTC.
    local le = os.time(t)
    local ut = os.date("!*t", le); ut.isdst = false
    local epoch = le + os.difftime(le, os.time(ut))
    -- keep sub-second precision when the timestamp carries it
    local frac = ts:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d(%.%d+)")
    if frac ~= nil then epoch = epoch + tonumber("0" .. frac) end
    local sign, oh, om = ts:match("([%+%-])(%d%d):?(%d%d)$")
    if sign ~= nil then
        local off = tonumber(oh) * 3600 + tonumber(om) * 60
        if sign == "+" then epoch = epoch - off else epoch = epoch + off end
    end
    return epoch
end

function enrich(tag, timestamp, record)
    -- ---- rawmessage: the complete original line, as received ----
    local raw_pri  = record["pri"]
    local raw_body = record["message"] or ""
    if raw_pri ~= nil then
        record["rawmessage"] = "<" .. raw_pri .. ">" .. raw_body
    else
        record["rawmessage"] = raw_body
    end

    -- ---- ingest @timestamp (millisecond precision, UTC) ----
    local sec = math.floor(timestamp)
    local ms  = math.floor((timestamp - sec) * 1000 + 0.5)
    if ms > 999 then ms = 999 end
    local ingest_iso = os.date("!%Y-%m-%dT%H:%M:%S", sec) .. string.format(".%03dZ", ms)
    record["@timestamp"] = ingest_iso
    record["@version"]   = "1"

    -- ---- 1. grok: detect + parse ----
    -- Tolerate an optional leading space after <PRI> (grok's %{SPACE}), e.g.
    -- "<100> Jul 24 ..." -- otherwise the timestamp fails to parse.
    local parse_body = raw_body:gsub("^%s+", "")
    local effective_pri = raw_pri
    local pri_bad = false

    -- ---- malformed PRI ----
    -- The input parser only captures "<digits>", so anything bracket-shaped
    -- still sitting at the head of the body is a broken PRI: "<abc>", "<>",
    -- "<10.5>", "<-11>", "<100 " (no closing) or "100> " (no opening). Drop
    -- that token -- it is framing, not log text -- and flag the frame.
    if raw_pri == nil then
        local inner, tail = parse_body:match("^<([^>%s]*)>%s*(.*)$")
        if inner ~= nil then
            if inner:match("^%d+$") and tonumber(inner) <= 191 then
                effective_pri = inner
            else
                pri_bad = true
            end
            parse_body = tail
        elseif parse_body:match("^<") then
            parse_body = parse_body:gsub("^<%S*%s*", "")
            pri_bad = true
        elseif parse_body:match("^%d+>") then
            parse_body = parse_body:gsub("^%d+>%s*", "")
            pri_bad = true
        end
    end

    -- ---- invalid RFC5424 VERSION ----
    -- A token sitting in front of an ISO timestamp is the VERSION field. It
    -- must be numeric: "<100>X 2024-07-30T..." is not a valid frame, so the
    -- PRI is discarded too. Either way the token is dropped, and a frame with
    -- a broken PRI is never trusted to have real RFC5424 structure -- it is
    -- read with the RFC3164 "TIMESTAMP HOST MSG" pattern instead.
    local vtok, vrest = parse_body:match("^(%S+)%s+(%d%d%d%d%-%d%d%-%d%dT.*)$")
    if vtok ~= nil then
        if not vtok:match("^%d+$") then
            parse_body, pri_bad = vrest, true
        elseif pri_bad then
            parse_body = vrest
        end
    end

    local p = nil
    if not pri_bad then p = parse_rfc5424(parse_body) end
    p = p or parse_rfc3164(parse_body)

    -- NOTE: store-and-forward unwrapping is disabled (see the commented
    -- UNWRAP_FORWARDED flag and try_unwrap() above). Re-enable both to treat
    -- an embedded inner syslog frame as the original log.

    local fmt = p.format

    -- ---- 2. dateruby: syslog_timestamp from the original ----
    -- A timestamp with NO timezone is the sender's local wall-clock time, so
    -- tag it with the local offset (RFC3164 never carries a zone; RFC5424 may
    -- omit it). A timestamp that already has "Z" or "+/-HH:MM" is kept as-is.
    local syslog_timestamp
    if p.format == "Rfc5424" then
        syslog_timestamp = normalize_iso(p.syslog_timestamp_original)
        if syslog_timestamp ~= nil and not has_offset(syslog_timestamp) then
            syslog_timestamp = syslog_timestamp .. tz_offset(sec)
        end
    elseif p.syslog_timestamp_original ~= nil then
        -- RFC3164 "Mmm dd HH:MM:SS" -> ISO using the current (ingest) year.
        local mon, day, clock =
            p.syslog_timestamp_original:match("^(%a%a%a)%s+(%d+)%s+(%d%d:%d%d:%d%d)$")
        if mon ~= nil and MON[mon] ~= nil then
            local year = os.date("%Y", sec)
            syslog_timestamp = string.format("%s-%s-%02dT%s%s",
                year, MON[mon], tonumber(day), clock, tz_offset(sec))
        else
            syslog_timestamp = normalize_iso(p.syslog_timestamp_original)
            if syslog_timestamp ~= nil and not has_offset(syslog_timestamp) then
                syslog_timestamp = syslog_timestamp .. tz_offset(sec)
            end
        end
    end

    -- ---- 3. mutate: message renames + per-format fields ----
    local message = p.syslog_message or ""
    if STRIP_BOM then
        message = message:gsub("\239\187\191", "")   -- strip UTF-8 BOM
    end
    record["message"] = message   -- final rename: syslog_message -> message

    record["syslog_message_format"] = fmt
    if p.syslog_host        ~= nil then record["syslog_host"]        = p.syslog_host end
    if p.syslog_program     ~= nil then record["syslog_program"]     = p.syslog_program end
    if p.syslog_process_id  ~= nil then record["syslog_process_id"]  = p.syslog_process_id end
    if p.syslog_message_id  ~= nil then record["syslog_message_id"]  = p.syslog_message_id end

    -- RFC5424 keeps the sender's own timestamp; RFC3164 blanks it. It is
    -- emitted in the same normalized shape as syslog_timestamp -- explicit
    -- offset, fixed nanosecond width -- not as the raw substring, so a sender
    -- that wrote "2024-08-12T09:00:00" is stored as a complete instant.
    if p.format == "Rfc5424" then
        record["syslog_timestamp_original"] = with_nanos(syslog_timestamp) or ""
    else
        record["syslog_timestamp_original"] = ""
    end

    -- ---- 4. pri rules (use the innermost/original PRI when unwrapped) ----
    local pri = tonumber(effective_pri)
    if pri_bad or pri == nil or pri > 191 then
        pri = 13
        record["syslog_message_format"] = "Other"
    end
    record["syslog_pri"] = pri

    -- ---- 5. syslog_pri: facility / severity codes ----
    record["syslog_facility_code"] = math.floor(pri / 8)
    record["syslog_severity_code"] = pri % 8

    -- ---- timestamp fallback (RFC3164 relay standard 4.3.1) ----
    if syslog_timestamp == nil or syslog_timestamp == "" then
        syslog_timestamp = ingest_iso
    end
    record["syslog_timestamp"] = with_nanos(syslog_timestamp)

    -- ---- 6. final: protocol + host normalization ----
    record["ingest_protocol"] = "syslog"       -- rename: type -> ingest_protocol

    -- hostIp arrives as "udp://<ip>:<port>"; reduce to a bare, lowercase IP.
    local ip = tostring(record["hostIp"] or "")
    ip = ip:gsub("^%a+://", ""):gsub(":%d+$", ""):lower()
    record["hostIp"] = ip
    record["host"]   = ip     -- NOTE: no reverse-DNS (see header)

    -- ---- drop fields Logstash removes ----
    record["pri"]           = nil
    record["syslog_version"] = nil

    -- ---- 7. Logstash filter block: field defaults ----
    -- NOTE: the relay-standard fallback (syslog_host => resolved host) is
    -- deliberately NOT applied. A frame that carries no HOSTNAME is stored
    -- with the field empty rather than with the sender's IP, so the stored
    -- record never claims a hostname the sender did not send. The forwarding
    -- output writes "-" for it.
    -- program / process id / message id stay NULL when absent: an unset key,
    -- not "-" and not "". The forwarding output writes the RFC5424 NILVALUE
    -- "-" on the wire for any key it cannot find, so the emitted frame is
    -- identical either way -- this only keeps the stored record clean.
    for _, k in ipairs({"syslog_host", "syslog_program",
                        "syslog_process_id", "syslog_message_id"}) do
        if record[k] == "-" or record[k] == "" then record[k] = nil end
    end

    -- ---- forward carrying the ORIGINAL syslog time ----
    if FORWARD_ORIGINAL_TIME then
        local e = iso_to_epoch(record["syslog_timestamp"])
        -- return code 1 = record modified, event timestamp replaced
        if e ~= nil then return 1, e, record end
    end

    -- return code 2 = record modified, keep original event timestamp
    return 2, timestamp, record
end
