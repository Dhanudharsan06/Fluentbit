# Fluentbit
testing fluent bit


- Format of the data required by elasticsearch
```	
	{
	"hostIp": "127.0.0.1",
	"syslog_severity_code": 6,
	"syslog_timestamp": "2026-09-01T05:43:01.387508100Z",
	"rawmessage": "<14>1 2026-09-01T05.43.01.360389+00:00 SYSKEYDEV-00130 SyslogTester 14236 dfc632a2-9faf-4d6c-b987-109fff7d [customSturcturedData@32473 Environment=\"Windows 10\" Hardware=\"Desktop PC\"] ﻿Fluentbit forward test",
	"host": "127.0.0.1",
	"@timestamp": "2026-09-01T05:43:01.387508100Z",
	"syslog_facility_code": 1,
	"@version": "1",
	"syslog_message_format": "Rfc3164",
	"message": "1 2026-09-01T05.43.01.360389+00:00 SYSKEYDEV-00130 SyslogTester 14236 dfc632a2-9faf-4d6c-b987-109fff7d [customSturcturedData@32473 Environment=\"Windows 10\" Hardware=\"Desktop PC\"] ﻿Fluentbit forward test",
	"syslog_pri": 14,
	"syslog_timestamp_original": "",
	"ingest_protocol": "syslog"
}
```

- The data returned by the default Rfc5424 filter, when Rfc5424 format is sent, is as follows:
[2026/09/01 15:20:09.766] [ warn] [parser:syslog-rfc5424] invalid time format %Y-%m-%dT%H:%M:%S.%L%z for '2026-09-01T09.50.09.744805+00:00'
[0] syslog: [[1788256209.766211100, {}], {"pri"=>"14", "host"=>"SYSKEYDEV-00130", "ident"=>"SyslogTester", "pid"=>"41928", "msgid"=>"aee187b5-faf6-4343-a9e8-69107fa9", "extradata"=>"[customSturcturedData@32473 Environment="Windows 10" Hardware="Desktop PC"]", "message"=>"∩╗┐Fluentbit forward test", "hostIp"=>"tcp://127.0.0.1:62513"}]

- when default Rfc5424 parser is used, and other format is sent
   [2026/09/01 15:24:38.378] [ warn] [input:syslog:syslog.0] error parsing log message with parser 'syslog-rfc5424'


So to recieve all format of the logs custom parser is required to be used, which can parse all the formats of the logs. So the custom parser is created and used in the configuration file. The custom parser is as follows:
```
[PARSER
    Name    syslog-passthrough
    Format  regex
    Regex   ^(?:\<(?<pri>[0-9]{1,5})\>)?(?<message>.*)$

```

The output of the custom parser is as follows:

Rfc3164 format:
Raw-message: 71 <14>Sep  2 10:28:08 SYSKEYDEV-00130 SyslogTester:Fluentbit forward test

[2026/09/02 10:27:35.591] [ info] [engine] Shutdown Grace Period=5, Shutdown Input Grace Period=2
[0] syslog: [[1788325088.366688300, {}], {"pri"=>"14", "message"=>"Sep  2 10:28:08 SYSKEYDEV-00130 SyslogTester:Fluentbit forward test", "hostIp"=>"tcp://127.0.0.1:61823"}]
[0] syslog: [[1788325088.366688300, {}], {"pri"=>"14", "message"=>"Sep  2 10:28:08 SYSKEYDEV-00130 SyslogTester:Fluentbit forward test", "hostIp"=>"tcp://127.0.0.1:61823"}]

Rfc5424 format:
Raw-message: 208 <14>1 2026-09-02T05.09.22.557550+00:00 SYSKEYDEV-00130 SyslogTester 22828 b90b7abc-e54d-4f9e-b1de-0a506fca [customSturcturedData@32473 Environment="Windows 10" Hardware="Desktop PC"] ?Fluentbit forward test

[0] syslog: [[1788325762.577822300, {}], {"pri"=>"14", "message"=>"1 2026-09-02T05.09.22.557550+00:00 SYSKEYDEV-00130 SyslogTester 22828 b90b7abc-e54d-4f9e-b1de-0a506fca [customSturcturedData@32473 Environment="Windows 10" Hardware="Desktop PC"] ∩╗┐Fluentbit forward test", "hostIp"=>"tcp://127.0.0.1:56174"}]

Now we can target to achieve the format required for the elasticsearch, by using the custom parser and the filter. The filter is as follows:
```
[FILTER]
    Name    lua
    Match   syslog
    script  enrich_syslog.lua
    call    enrich
```

where enrich_syslog.lua is a lua script which is used to enrich the data and make it in the format required for the elasticsearch.

steps in the enrich_syslog.lua script are as follows:

- recieve the data from the input syslog which is taged as syslog.
- parse the message field to get the syslog_timestamp, syslog_facility_code, syslog_severity_code, syslog_message_format, syslog_pri, syslog_timestamp_original and message fields.
- enrich the data with the hostIp, host and ingest_protocol fields.
- return the enriched data to the output elasticsearch.


processed Rfc5424 log:

raw log: 208 <14>1 2026-09-02T07.49.38.846798+00:00 SYSKEYDEV-00130 SyslogTester 33340 0722586a-4c09-4198-8e45-663a20ab [customSturcturedData@32473 Environment="Windows 10" Hardware="Desktop PC"] ?Fluentbit forward test

Processed message:
```
[0] syslog: [[1788335378.846797943, {}], 
	{
		"message"=>"[customSturcturedData@32473 Environment="Windows 10" Hardware="Desktop PC"] Fluentbit forward test",
		"rawmessage"=>"<14>1 2026-09-02T07.49.38.846798+00:00 SYSKEYDEV-00130 SyslogTester 33340 0722586a-4c09-4198-8e45-663a20ab [customSturcturedData@32473 Environment="Windows 10" Hardware="Desktop PC"] ∩╗┐Fluentbit forward test", "syslog_timestamp_original"=>"2026-09-02T07:49:38.8467980+00:00",
		"syslog_host"=>"SYSKEYDEV-00130", "syslog_program"=>"SyslogTester",
		"syslog_process_id"=>"33340",
		"@timestamp"=>"2026-09-02T07:49:38.867Z",
		"@version"=>"1",
		"syslog_message_format"=>"Rfc5424",
		"syslog_pri"=>14, "syslog_facility_code"=>1,
		"syslog_severity_code"=>6,
		"ingest_protocol"=>"syslog",
		"syslog_timestamp"=>"2026-09-02T07:49:38.8467980+00:00",
		"hostIp"=>"127.0.0.1",
		"host"=>"127.0.0.1",
		"syslog_message_id"=>"0722586a-4c09-4198-8e45-663a20ab"
	}]
```

Processed Rfc3164 log:

raw log: 71 <14>Sep  2 13:23:38 SYSKEYDEV-00130 SyslogTester:Fluentbit forward test

processed message:
```
[0] syslog: [[1788335618.000000000, {}], 
	{"
		message"=>"SyslogTester:Fluentbit forward test",
		"rawmessage"=>"<14>Sep  2 13:23:38 SYSKEYDEV-00130 SyslogTester:Fluentbit forward test",
		"syslog_severity_code"=>6, "ingest_protocol"=>"syslog",
		"syslog_timestamp_original"=>"",
		"syslog_host"=>"SYSKEYDEV-00130",
		"hostIp"=>"127.0.0.1",
		"host"=>"127.0.0.1",
		"@timestamp"=>"2026-09-02T07:53:38.653Z",
		"@version"=>"1",
		"syslog_timestamp"=>"2026-09-02T13:23:38.0000000+05:30",
		"syslog_facility_code"=>1,
		"syslog_pri"=>14,
		"syslog_message_format"=>"Rfc3164"
	}]
```



## Forwarding to the downstream collector (Logstash `output { syslog { ... } }`)

The Logstash block being replaced emits, per record:

```
<PRI>1 TIMESTAMP SOURCEHOST APPNAME PROCID MSGID MESSAGE\n
```

with `tcp_framing => "non-transparent-framing"` (the trailing LF) and `-` for
any field the record does not carry.

**The `syslog` OUTPUT plugin cannot produce that frame.** In `rfc5424` mode
`out_syslog` always writes the STRUCTURED-DATA NILVALUE and a UTF-8 BOM in
front of MSG. Both are RFC 5424 conformant, both are absent from Logstash's
output, and neither is configurable. Captured from the wire:

```
out_syslog : <165>1 ...Z hostname webapp 9981 evt-777 - <BOM>[meta@1 env="prod"] Full 5424 payload
Logstash   : <165>1 ...Z hostname webapp 9981 evt-777 [meta@1 env="prod"] Full 5424 payload
```

When MSGID is also absent the difference shows up as a doubled dash
(`... 5150 - - [meta@1 ...`), which is what the integration tests were failing on.

So the frame is assembled in `enrich_syslog.lua` (`build_forward`) into a
`rawforward` field and shipped by the plain **`tcp`** OUTPUT:

```
[OUTPUT]
    Name             tcp
    Match            syslog.forward
    Host             10.10.1.92
    Port             1514
    raw_message_key  $rawforward
```

`raw_message_key` is a record accessor (the `$` is required -- without it the
literal text is sent) and writes the field's bytes untouched, terminating the
frame with LF. That is exactly non-transparent framing.

TIMESTAMP is rendered as UTC with six fractional digits and a `Z` suffix
(`2024-11-20T12:35:30.123456Z`), matching what the receiver already expects.

`rawforward` must never reach Elasticsearch, so the pipeline splits after the
Lua filter: `rewrite_tag` emits a copy tagged `syslog.forward` for the TCP
output (keeping the original on `syslog`), and `record_modifier` strips the
field from the stored record. Every other OUTPUT matches the exact tag
`syslog`, so nothing is written twice.

`ssl_verify => "true"` in the Logstash block is inert under `protocol => tcp`
(it only applies to `ssl-tcp`), so this stays a plain TCP connection.
