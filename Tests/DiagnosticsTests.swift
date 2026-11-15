import Foundation

extension TestRunner {
    static func diagnosticsTests() {
        let probeDate = Date()
        func direct(_ status: String, _ value: Any? = nil) -> DirectTelephonyReading? {
            var row: [String: Any] = ["slot": 1, "metric": "imsVoice", "status": status, "date": probeDate,
                                      "code": 13, "domain": "private-phone-79991234567", "description": "IMSI secret"]
            row["value"] = value
            return DirectTelephonyReading.decode([row]).first
        }
        check(direct("value", false)?.text == "Не зарегистрирован", "explicit negative direct IMS response survives")
        check(direct("error", false)?.value == nil && direct("error")?.text == "Ошибка 13", "denied direct request cannot become false")
        check(direct("empty")?.value == nil && direct("empty")?.text == "Нет данных", "empty direct response is unknown")
        check(direct("value", 0)?.status == .invalid, "numeric zero is not a typed BOOL response")
        check(direct("value", "false")?.status == .invalid, "string false cannot masquerade as a BOOL")
        check(direct("future-status") == nil, "unknown direct response status rejected")
        check(direct("error")?.reportLine.contains("79991234567") == false && direct("error")?.reportLine.contains("secret") == false, "direct report strips arbitrary domains and error contents")
        let connection = DirectTelephonyReading.decode([["slot": 2, "metric": "imsConnection", "status": "value", "value": true, "date": probeDate]])
        check(connection.first?.metric == .imsConnection && connection.first?.text == "Есть", "IMS connection is distinct from voice registration")
        check(DirectTelephonyReading.decode([["slot": 7, "metric": "imsVoice", "status": "value", "value": true, "date": probeDate]]).isEmpty, "unknown direct slot never becomes SIM 1 or SIM 2")
        let cancelProbe = DirectTelephonyCancellation()
        check(!cancelProbe.isCancelled, "direct probe begins active")
        cancelProbe.cancel(); cancelProbe.cancel()
        check(cancelProbe.isCancelled, "direct cancellation is idempotent")
        let parser = DiagnosticParser()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func parse(_ message: String, category: String = "reg.ctr.1", process: String = "/System/Library/Frameworks/CoreTelephony.framework/Support/CommCenter", date: Date? = nil) -> [DiagnosticReading] {
            parser.parse(process: process, category: category, message: message, date: date ?? now)
        }
        check(parse("IMS Voice registered: true", process: "OtherProcess").isEmpty, "diagnostics reject other processes")
        check(parse("IMS Voice registered: true" + String(repeating: "x", count: 32768)).isEmpty, "diagnostics bound entry size")
        check(parse("Operator name is being overridden to 'MTS WiFi'").isEmpty, "operator display name is not IMS evidence")
        check(parse("IMS Voice registered: unknown").isEmpty, "unknown IMS flag is not false")
        let voice = parse("1.7 IMS Voice registered: true IMSI=250011234567890")
        check(voice.count == 1 && voice[0].slot == "kOne" && voice[0].value == "Да" && voice[0].date == now, "IMS event keeps scalar, slot and date only")
        check(parse("IMS Voice registered: false").first?.value == "Нет", "negative IMS event is preserved")
        check(parse("IMS registered : true, Over Wifi : true").first?.value == "Зарегистрирован через Wi-Fi", "IMS Wi-Fi registration")
        check(parse("IMS registered : true, Over Wifi : false").first?.value == "IMS зарегистрирован, не через Wi-Fi", "IMS cellular registration distinguished")
        check(parse("IMS registered : false, Over Wifi : true").first?.value == "Нет регистрации IMS", "Wi-Fi flag cannot override failed registration")
        let capabilities = parse("VoLTE Feature support: kTrue, VoNR Feature support: kFalse, VoWiFi Feature support: true")
        check(capabilities.map(\.metric) == [.volteCapability, .vonrCapability, .vowifiCapability] && capabilities.map(\.value) == ["Да", "Нет", "Да"], "capabilities do not emit active-service claims")
        check(DiagnosticParser.slot(message: "2.4 IMS Voice registered: true", category: "") == "kTwo", "slot from prefix")
        check(DiagnosticParser.slot(message: "event slot kTwo", category: "") == "kTwo", "slot from explicit marker")
        check(DiagnosticParser.slot(message: "event", category: "sip.dump.ims.2.1") == "kTwo", "slot before category suffix")
        check(DiagnosticParser.slot(message: "1.4 event slot kTwo", category: "") == "general", "conflicting slot evidence remains general")
        check(DiagnosticParser.slot(message: "2.4 event", category: "reg.ctr.1") == "general", "prefix and category conflict remains general")
        check(parse("IMS Voice registered: true", category: "unknown").first?.slot == "general", "unknown slot never becomes selected SIM")
        check(parse("Registration status is kRegistrationDenied").first?.value == "Отказ сети", "registration failure")
        check(parse("current RAT set to kRatLTE").first?.value == "4G · LTE", "known RAT")
        check(parse("current RAT set to kRatLTEUnknown").isEmpty, "unknown RAT not truncated")
        let signal = parse("Rsrp={y=-105 : 1}, Sinr={y=12.5 : 1}")
        check(signal.map(\.metric) == [.rsrp, .sinr] && signal.map(\.value) == ["-105 дБм", "12.5 дБ"], "signal values with units")
        check(parse("Rsrp={y=-999 : 1}, Sinr={y=12 : 1}").map(\.metric) == [.sinr], "invalid RSRP cannot suppress valid SINR")
        check(parse("Rsrp={y=NaN : 1}, Sinr={y=12 : 1}").map(\.metric) == [.sinr], "non-numeric RSRP cannot suppress valid SINR")
        check(parse("<NEIKEv2Transport> UDP 192.0.2.1:500 -> 198.51.100.2:4500").first?.value == "198.51.100.2", "ePDG destination only")
        check(parse("<NEIKEv2Transport> UDP NAT-T 192.0.2.1:500 -> [2001:db8::1]:4500").first?.value == "2001:db8::1", "IPv6 ePDG")
        check(parse("<NEIKEv2Transport> UDP a -> phone+79991234567:500").isEmpty, "unvalidated endpoint discarded")
        check(parse("NEIKEv2ErrorDomain Code=24 \"private phone +79991234567\"").first?.value == "Код 24", "IKE error text is not retained")
        check(parse("NEIKEv2ErrorDomain Code=79991234567").isEmpty, "oversized error code discarded")
        check(parse("IKEv2IKESA[private] state Connecting -> Established").first?.value == "Connecting → Established", "IKE state excludes identifier")

        func sip(_ lines: [String], category: String = "sip.dump.ims.1.4", end: Date? = nil) -> [DiagnosticReading] {
            _ = parse("==== source --> destination ====", category: category)
            for line in lines { _ = parse(line, category: category) }
            return parse("================", category: category, date: end)
        }
        let body = ["CSeq: 4 INVITE", "P-Access-Network-Info: IEEE-802.11;private=123456789012345", "m=audio 4000 RTP/AVP 96 101", "a=rtpmap:96 EVS/16000", "a=rtpmap:101 telephone-event/8000"]
        let answer = sip(["SIP/2.0 200 OK"] + body)
        check(answer.map(\.metric) == [.callNetwork, .sdpCodec] && answer.map(\.value) == ["Wi-Fi", "EVS/16000"], "successful SIP response yields allowlisted metadata")
        check(sip(["INVITE sip:private SIP/2.0"] + body).isEmpty, "SIP request is not a response")
        check(sip(["SIP/2.0 488 Rejected"] + body).isEmpty, "failed SIP response is not call evidence")
        check(sip(["SIP/2.0 200 OK"] + body.map { $0.replacingOccurrences(of: "INVITE", with: "REGISTER") }).isEmpty, "registration SIP is not a call")
        check(!sip(["SIP/2.0 200 OK"] + body + ["m=audio 4000 RTP/AVP 96 97", "a=rtpmap:97 AMR-WB/16000"]).contains { $0.metric == .sdpCodec }, "multiple speech codecs do not assert a chosen codec")
        check(!sip(["SIP/2.0 200 OK"] + body + ["m=audio 4000 RTP/AVP 96 99"]).contains { $0.metric == .sdpCodec }, "unknown payload does not assert a chosen codec")
        check(!sip(["SIP/2.0 200 OK"] + body.map { $0.replacingOccurrences(of: "audio 4000", with: "audio 0") }).contains { $0.metric == .sdpCodec }, "disabled media is not codec evidence")
        check(!sip(["SIP/2.0 200 OK"] + body + ["m=audio 0 RTP/AVP 96"]).contains { $0.metric == .sdpCodec }, "ambiguous audio sections rejected")
        check(sip(["SIP/2.0 200 OK"] + body + ["m=video 5000 RTP/AVP 96", "a=rtpmap:96 AMR/8000"]).first { $0.metric == .sdpCodec }?.value == "EVS/16000", "other media cannot replace audio codec")
        check(sip(["SIP/2.0 200 OK"] + body, end: now.addingTimeInterval(16)).isEmpty, "incomplete old SIP message expires")
        check(parse("SIP/2.0 200 OK", category: "sip.dump.ims.1.4").isEmpty && parse("=====", category: "sip.dump.ims.1.4").isEmpty, "unframed SIP data ignored")
        _ = parse("==== start ====", category: "sip.dump.ims.1.4")
        _ = parse("SIP/2.0 200 OK", category: "sip.dump.ims.1.4")
        check(sip(["SIP/2.0 200 OK"] + body, category: "sip.dump.ims.2.4").allSatisfy { $0.slot == "kTwo" }, "simultaneous SIP categories remain separate")
        check(parse("=====", category: "sip.dump.ims.1.4").isEmpty, "other SIM cannot complete partial SIP message")

        let collector = DiagnosticCollector()
        _ = collector.ingest(process: "Other", category: "", message: "private text", timestamp: 0, receivedAt: now)
        check(collector.stats.total == 1 && collector.stats.commCenter == 0, "trace stats distinguish missing CommCenter")
        _ = collector.ingest(process: "CommCenter", category: "", message: "IMS Voice registered: <private>", timestamp: Int64(now.timeIntervalSince1970), receivedAt: now)
        check(collector.stats.commCenter == 1 && collector.stats.redacted == 1 && collector.stats.parsed == 0, "redacted values counted without invented readings")
        let delayed = collector.ingest(process: "CommCenter", category: "reg.ctr.1", message: "IMS Voice registered: true", timestamp: Int64(now.addingTimeInterval(-120).timeIntervalSince1970), receivedAt: now)
        check(delayed.first?.date == now.addingTimeInterval(-120) && delayed.first?.timestampIsReceipt == false, "clock differences no longer silently discard valid values")
        let undated = collector.ingest(process: "CommCenter", category: "reg.ctr.1", message: "IMS Voice registered: false", timestamp: 0, receivedAt: now)
        check(undated.first?.timestampIsReceipt == true && undated.first?.date == now && collector.stats.invalidTimestamps == 1, "unusable event timestamp is explicitly marked as reception time")
        check(collector.stats.parsed == 2, "recognized-event counter excludes private or unrelated messages")
        let services = ["opaque-9": "CTRadioAccessTechnologyLTE", "opaque-1": "CTRadioAccessTechnologyNRNSA"]
        let local = RadioSnapshot.make(services: services, dataService: "opaque-9")
        check(local.dataTechnology == "4G · LTE" && local.otherTechnologies == ["5G · NSA"], "data service comes from explicit identifier, not sorted position")
        let noSelection = RadioSnapshot.make(services: services, dataService: nil)
        check(noSelection.dataTechnology == nil && noSelection.otherTechnologies.count == 2, "unknown data line is not guessed")
        check(RadioSnapshot.make(services: ["a": "future-radio"], dataService: "a").dataTechnology == nil, "unknown radio technology not inferred as LTE or 5G")

        let partialFeatures = parse("VoLTE Feature support: true, VoNR Feature support: <private>, VoWiFi Feature support: kFalse")
        check(partialFeatures.map(\.metric) == [.volteCapability, .vowifiCapability] && partialFeatures.map(\.value) == ["Да", "Нет"], "one hidden feature cannot discard its public neighbors")
        check(parse("Rsrp={y=<private> : 1}, Sinr={y=9.2 : 1}").map(\.metric) == [.sinr], "SINR survives private RSRP")
        check(parse("Rsrp={y=-98 : 1}, Sinr={y=<private> : 1}").map(\.metric) == [.rsrp], "RSRP survives private SINR")
        check(parse("IMS Voice registered: kTrue").first?.value == "Да", "IMS supports kTrue without guessing unknown tokens")
        check(parse("IMS registered : false, Over Wifi : <private>").first?.value == "Нет регистрации IMS", "explicit negative registration does not depend on hidden access type")
        check(parse("IMS registered : <private>, Over Wifi : true").isEmpty, "access type cannot prove hidden IMS registration")
        check(parse("UE is Registered for Voice+SMS on WLAN").first?.metric == .imsServices, "recognized IMS service registration event")
        check(parse("UE is Registered for private-user on WLAN").isEmpty, "IMS service allowlist excludes arbitrary identifiers")
        let probe = DiagnosticParser.fieldEvidence(message: "IMS Voice registered: true phone=<private>", category: "")
        check(probe[.imsVoice] == false, "unrelated private text does not mark public IMS field as hidden")
        let mixedProbe = DiagnosticParser.fieldEvidence(message: "VoLTE Feature support: true, VoNR Feature support: <private>", category: "")
        check(mixedProbe[.volteCapability] == false && mixedProbe[.vonrCapability] == true, "field-specific redaction evidence")
        check(DiagnosticParser.fieldEvidence(message: "m=audio 4000 RTP/AVP 96\na=rtpmap:96 EVS/16000\nFrom: <private>", category: "sip.dump.ims")[.sdpCodec] == false, "hidden SIP identity cannot mark public codec as hidden")
        check(DiagnosticParser.fieldEvidence(message: "a=rtpmap:96 <private>", category: "sip.dump.ims")[.sdpCodec] == true, "hidden codec has field-specific evidence")
        check(collector.stats.coverage[.imsVoice]?.decoded == 2 && collector.stats.coverage[.imsVoice]?.redacted == 1, "coverage keeps public and private counts separately")
        var sparse = DiagnosticStreamStats()
        sparse.total = 427223; sparse.commCenter = 23363; sparse.redacted = 17624; sparse.parsed = 24
        sparse.coverage = [.network: DiagnosticFieldCoverage(seen: 20, decoded: 20), .roaming: DiagnosticFieldCoverage(seen: 4, decoded: 4)]
        check(!sparse.hasDetailedMetrics && sparse.explanation.contains("только общие"), "network and roaming alone cannot claim successful IMS diagnostics")
        check((sparse.coverage[.imsVoice] ?? DiagnosticFieldCoverage()).status == "Событий не было", "aggregate redaction cannot be attributed to an absent IMS field")
        var retries = DiagnosticReconnectPolicy()
        check(!retries.shouldRetry(at: now, deadline: nil), "initial connection failure does not enter reconnect loop")
        check(retries.shouldRetry(at: now, deadline: now.addingTimeInterval(90)), "opened stream can reconnect")
        check(!retries.shouldRetry(at: now.addingTimeInterval(21), deadline: now.addingTimeInterval(90)), "outage retry window is bounded")
        retries.recovered()
        check(retries.shouldRetry(at: now.addingTimeInterval(30), deadline: now.addingTimeInterval(90)), "new outage after recovery can retry")
        check(retries.shouldRetry(at: now.addingTimeInterval(31), deadline: now.addingTimeInterval(90)) && !retries.shouldRetry(at: now.addingTimeInterval(32), deadline: now.addingTimeInterval(90)), "session retry count is bounded")
        var expired = DiagnosticReconnectPolicy()
        check(!expired.shouldRetry(at: now, deadline: now), "deadline never extended by reconnect")
        let prefixed = DiagnosticParser()
        let prefixedLines = ["==== start ====", "SIP/2.0 200 OK"] + body + ["====="]
        var prefixedResult: [DiagnosticReading] = []
        for line in prefixedLines { prefixedResult += prefixed.parse(process: "CommCenter", category: "sip.dump.ims.1.4", message: "1.4 " + line, date: now) }
        check(prefixedResult.contains { $0.metric == .sdpCodec && $0.value == "EVS/16000" }, "SIP subscription prefix is stripped before parsing")

        let reconnectCollector = DiagnosticCollector()
        let timestamp = Int64(now.timeIntervalSince1970)
        for line in ["==== start ====", "SIP/2.0 200 OK"] + body {
            _ = reconnectCollector.ingest(process: "CommCenter", category: "sip.dump.ims.1.4", message: line, timestamp: timestamp, receivedAt: now)
        }
        reconnectCollector.beginReconnect()
        check(reconnectCollector.ingest(process: "CommCenter", category: "sip.dump.ims.1.4", message: "=====", timestamp: timestamp, receivedAt: now).isEmpty, "SIP fragments never join across reconnects")
        check(reconnectCollector.stats.commCenter > 1 && reconnectCollector.stats.reconnectAttempts == 1, "reconnect keeps accumulated counters")

        let cancelled = DiagnosticSession()
        let closed = DispatchSemaphore(value: 0)
        cancelled.stop()
        cancelled.arm { closed.signal() }
        check(closed.wait(timeout: .now() + 1) == .success && cancelled.isStopped, "stop before stream is armed closes it")
        cancelled.stop(); cancelled.stop()
        check(closed.wait(timeout: .now() + 0.05) == .timedOut, "stop closes stream exactly once")
        cancelled.disarm()
        let closing = DiagnosticSession()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), cleanup = DispatchSemaphore(value: 0)
        closing.arm { entered.signal(); _ = release.wait(timeout: .now() + 2) }
        closing.stop()
        check(entered.wait(timeout: .now() + 1) == .success, "close callback started")
        DispatchQueue.global().async { closing.disarm(); cleanup.signal() }
        check(cleanup.wait(timeout: .now() + 0.05) == .timedOut, "transport cleanup waits for concurrent close")
        release.signal()
        check(cleanup.wait(timeout: .now() + 1) == .success, "cleanup resumes after close")
        let disarmed = DiagnosticSession()
        let unexpected = DispatchSemaphore(value: 0)
        disarmed.arm { unexpected.signal() }; disarmed.disarm(); disarmed.stop()
        check(unexpected.wait(timeout: .now() + 0.05) == .timedOut, "disarm prevents closing freed transport")
    }
}
