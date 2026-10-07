import XCTest
@testable import ArqmeterCore

final class ClaudeUsageControlTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func payload() -> [String: Any] {
        ["subscription_type": "pro", "rate_limits_available": true, "behaviors": NSNull(),
         "rate_limits": ["model_scoped": [],
            "five_hour": ["utilization": 26.5, "resets_at": "2027-01-15T10:00:00Z"],
            "seven_day": ["utilization": 73.0, "resets_at": "2027-01-19T10:00:00Z"]]]
    }
    func assertFailure(_ wanted: ClaudeCLIQuotaReport.Failure, _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation()) { XCTAssertEqual($0 as? ClaudeCLIQuotaReport.Failure, wanted) }
    }
    func testOnlyControlRequestsAndNoBehaviorScan() throws {
        let data = try ClaudeUsageControl.request(id: "quota", subtype: "get_usage")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "control_request")
        let request = try XCTUnwrap(object["request"] as? [String: Any])
        XCTAssertEqual(request["skip_behaviors"] as? Bool, true)
        XCTAssertNil(object["message"])
        assertFailure(.unsupported) { _ = try ClaudeUsageControl.request(id: "x", subtype: "user") }
        XCTAssertTrue(ClaudeUsageControl.arguments.contains("--no-session-persistence"))
        XCTAssertTrue(ClaudeUsageControl.arguments.contains("--safe-mode"))
        XCTAssertTrue(ClaudeUsageControl.arguments.contains("{\"disableAllHooks\":true}"))
    }
    func testConnectedSubscriberRequiredBeforeRequest() throws {
        XCTAssertEqual(try ClaudeUsageControl.subscription(fromInitialize: ["account": ["apiProvider": "firstParty", "subscriptionType": "pro"]]), "pro")
        for provider in ["bedrock", "vertex", "gateway"] {
            assertFailure(.unavailable) { _ = try ClaudeUsageControl.subscription(fromInitialize: ["account": ["apiProvider": provider, "subscriptionType": "pro"]]) }
        }
        assertFailure(.unavailable) { _ = try ClaudeUsageControl.subscription(fromInitialize: ["account": ["apiProvider": "firstParty"]]) }
    }
    func testPublicCanonicalAuthVersusOptionalSDKLabels() throws {
        let auth = Data(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","subscriptionType":"pro","email":"not-retained@example.test"}"#.utf8)
        let plan = try ClaudeUsageControl.subscription(fromPublicAuth: auth)
        XCTAssertEqual(plan, "pro")
        XCTAssertEqual(try ClaudeUsageControl.subscription(fromInitialize: ["account": ["apiProvider":"firstParty","subscriptionType":"display-label-not-a-canonical-enum"]], publicAuthSubscription: plan), "pro")
        XCTAssertEqual(try ClaudeUsageControl.subscription(fromInitialize: ["account": [:]], publicAuthSubscription: plan), "pro")
        assertFailure(.unavailable) { _ = try ClaudeUsageControl.subscription(fromInitialize: ["account": ["apiProvider":"gateway"]], publicAuthSubscription: plan) }
        assertFailure(.unavailable) { _ = try ClaudeUsageControl.subscription(fromInitialize: ["account": ["subscriptionType":"max"]], publicAuthSubscription: plan) }
        assertFailure(.authentication) { _ = try ClaudeUsageControl.subscription(fromPublicAuth: Data(#"{"loggedIn":false}"#.utf8)) }
        assertFailure(.unavailable) { _ = try ClaudeUsageControl.subscription(fromPublicAuth: Data(#"{"loggedIn":true,"authMethod":"api_key","apiProvider":"firstParty","subscriptionType":"pro"}"#.utf8)) }
        assertFailure(.unavailable) { _ = try ClaudeUsageControl.subscription(fromPublicAuth: Data(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"gateway","subscriptionType":"pro"}"#.utf8)) }
    }
    func testLiveEndpointWindowsAndResets() throws {
        let report = try ClaudeUsageControl.report(payload(), observedAt: now, subscription: "pro")
        XCTAssertEqual(report.currentWindow(.fiveHour, at: now)?.remainingPercent, 73)
        XCTAssertEqual(report.currentWindow(.sevenDay, at: now)?.remainingPercent, 27)
        XCTAssertNotNil(ClaudePlanQuotaReadout.makeCode(statusLine: nil, cli: report, at: now)?.weekly?.resetsAt)
        XCTAssertEqual(report.transportKind, "official-get-usage-live")
        XCTAssertEqual(report.subscriptionType, "pro")
        XCTAssertNil(report.currentWindow(.sevenDay, at: now.addingTimeInterval(180)))
        XCTAssertEqual(try JSONDecoder().decode(ClaudeCLIQuotaReport.self, from: JSONEncoder().encode(report)), report)
    }
    func testNullQuotaDoesNotInventAuthenticationFailure() {
        var p = payload(); p["rate_limits"] = NSNull()
        assertFailure(.unavailable) { _ = try ClaudeUsageControl.report(p, observedAt: now, subscription: "pro") }
    }
    func testCachedQuotaCannotReceiveNewTimestamp() {
        var p = payload(); var limits = p["rate_limits"] as! [String: Any]; limits.removeValue(forKey: "model_scoped"); p["rate_limits"] = limits
        assertFailure(.lastKnown) { _ = try ClaudeUsageControl.report(p, observedAt: now, subscription: "pro") }
    }
    func testPartialWindowsNoFakeQuotaOrReset() throws {
        var p = payload(); var limits = p["rate_limits"] as! [String: Any]
        limits["five_hour"] = ["utilization": 12.0, "resets_at": NSNull()]; p["rate_limits"] = limits
        let report = try ClaudeUsageControl.report(p, observedAt: now, subscription: "pro")
        XCTAssertNil(report.session); XCTAssertNotNil(report.weekly)
        for bad: Any in [true, -1.0, 101.0, "23"] {
            limits["seven_day"] = ["utilization": bad, "resets_at": "2027-01-19T10:00:00Z"]; p["rate_limits"] = limits
            assertFailure(.unsupported) { _ = try ClaudeUsageControl.report(p, observedAt: now, subscription: "pro") }
        }
    }
    func testWrongResponseAndActualServerErrors() throws {
        let wrong = Data(#"{"type":"control_response","response":{"subtype":"success","request_id":"other","response":{}}}"#.utf8)
        XCTAssertNil(try ClaudeUsageControl.response(wrong, requestID: "quota"))
        let error = Data(#"{"type":"control_response","response":{"subtype":"error","request_id":"quota","error":"Usage endpoint is rate limited (429)"}}"#.utf8)
        assertFailure(.limited) { _ = try ClaudeUsageControl.response(error, requestID: "quota") }
        for type in ["assistant", "user", "result", "control_request"] {
            let message = try JSONSerialization.data(withJSONObject: ["type": type])
            assertFailure(.unsupported) { _ = try ClaudeUsageControl.response(message, requestID: "quota") }
        }
    }
    func testOldArchivesRemainReadableAndPassiveStillWorks() throws {
        let old = Data(#"{"observedAt":821692800,"session":{"usedPercent":20,"resetLabel":"Resets in 1h"}}"#.utf8)
        let archived = try JSONDecoder().decode(ClaudeCLIQuotaReport.self, from: old)
        XCTAssertNil(archived.transportKind)
        let passive = try ClaudeQuotaReport.decodeStatusLine(Data(#"{"rate_limits":{"five_hour":{"used_percentage":8,"resets_at":1800018000}}}"#.utf8), receivedAt: now)
        XCTAssertEqual(ClaudePlanQuotaReadout.makeCode(statusLine: passive, cli: nil, at: now)?.session?.remainingPercent, 92)
        XCTAssertNil(ClaudePlanQuotaReadout.makeCode(statusLine: nil, cli: nil, at: now))
    }
    func testSkippedAcquisitionDoesNotDefeatPersistedBackoff() throws {
        var policy = ClaudeCLIRefreshPolicy(); policy.record(.limited, at: now)
        let original = policy
        // Receiving passive quota does not call policy.record(nil).
        let reloaded = try JSONDecoder().decode(ClaudeCLIRefreshPolicy.self, from: JSONEncoder().encode(policy))
        XCTAssertEqual(reloaded, original); XCTAssertFalse(reloaded.permits(at: now.addingTimeInterval(599)))
        policy.record(.unavailable, at: now.addingTimeInterval(10))
        XCTAssertGreaterThanOrEqual(policy.nextAttemptAt!, original.nextAttemptAt!)
    }

    func testDiagnosticExplainsAvailabilityAndPlanRejections() throws {
        typealias Reason = ClaudeUsageControl.UsageDiagnostic.Rejection
        let cases: [(String, Any?, Reason)] = [
            ("rate_limits_available", nil, .availabilityAbsent),
            ("rate_limits_available", NSNull(), .availabilityNull),
            ("rate_limits_available", false, .availabilityFalse),
            ("rate_limits_available", "true", .availabilityInvalidType),
            ("subscription_type", nil, .planAbsent),
            ("subscription_type", NSNull(), .planNull),
            ("subscription_type", [], .planInvalidType),
            ("subscription_type", "max", .planConflict),
            ("rate_limits", nil, .limitsAbsent),
            ("rate_limits", NSNull(), .limitsNull),
            ("rate_limits", [], .limitsInvalidType)
        ]
        for (key, value, reason) in cases {
            var p = payload(); p[key] = value
            let result = ClaudeUsageControl.evaluate(p, observedAt: now, subscription: "pro")
            XCTAssertEqual(result.diagnostic.rejection, reason)
            assertFailure(.unavailable) { _ = try result.result.get() }
            assertFailure(.unavailable) { _ = try ClaudeUsageControl.report(p, observedAt: now, subscription: "pro") }
        }
        let invalid = ClaudeUsageControl.evaluate(payload(), observedAt: now, subscription: "unknown")
        XCTAssertEqual(invalid.diagnostic.rejection, .invalidVerifiedSubscription)
        assertFailure(.unavailable) { _ = try invalid.result.get() }
    }

    func testUnavailableIsNotMisclassifiedAsCached() {
        var p = payload(); p["rate_limits_available"] = false
        var limits = p["rate_limits"] as! [String: Any]; limits.removeValue(forKey: "model_scoped"); p["rate_limits"] = limits
        let result = ClaudeUsageControl.evaluate(p, observedAt: now, subscription: "pro")
        XCTAssertEqual(result.diagnostic.modelScopedKind, .absent)
        XCTAssertEqual(result.diagnostic.rejection, .availabilityFalse)
        assertFailure(.unavailable) { _ = try result.result.get() }
        p["rate_limits_available"] = true
        let cached = ClaudeUsageControl.evaluate(p, observedAt: now, subscription: "pro")
        XCTAssertEqual(cached.diagnostic.rejection, .liveMarkerAbsent)
        assertFailure(.lastKnown) { _ = try cached.result.get() }
        for (value, reason): (Any, ClaudeUsageControl.UsageDiagnostic.Rejection) in [(NSNull(), .liveMarkerNull), ("not-an-array", .liveMarkerInvalidType)] {
            limits["model_scoped"] = value; p["rate_limits"] = limits
            let rejected = ClaudeUsageControl.evaluate(p, observedAt: now, subscription: "pro")
            XCTAssertEqual(rejected.diagnostic.rejection, reason)
            assertFailure(.lastKnown) { _ = try rejected.result.get() }
        }
    }

    func testWindowShapeRecordsValidationWithoutQuotaOrDates() throws {
        var p = payload(); var limits = p["rate_limits"] as! [String: Any]
        limits["five_hour"] = ["utilization": true, "resets_at": "not-a-date"]
        p["rate_limits"] = limits
        let partial = ClaudeUsageControl.evaluate(p, observedAt: now, subscription: "pro")
        XCTAssertNil(partial.diagnostic.rejection)
        XCTAssertEqual(partial.diagnostic.fiveHour?.utilization, .boolean)
        XCTAssertEqual(partial.diagnostic.fiveHour?.reset, .invalidDate)
        XCTAssertEqual(partial.diagnostic.sevenDay?.utilization, .valid)
        XCTAssertEqual(partial.diagnostic.sevenDay?.reset, .future)
        XCTAssertNil(try partial.result.get().session)
        XCTAssertNotNil(try partial.result.get().weekly)
        limits["seven_day"] = ["utilization": 101.0, "resets_at": "2020-01-01T00:00:00Z"]; p["rate_limits"] = limits
        let invalid = ClaudeUsageControl.evaluate(p, observedAt: now, subscription: "pro")
        XCTAssertEqual(invalid.diagnostic.rejection, .noValidWindow)
        XCTAssertEqual(invalid.diagnostic.sevenDay?.utilization, .outOfRange)
        XCTAssertEqual(invalid.diagnostic.sevenDay?.reset, .elapsed)
        assertFailure(.unsupported) { _ = try invalid.result.get() }
        limits["five_hour"] = NSNull(); limits.removeValue(forKey: "seven_day"); p["rate_limits"] = limits
        let absent = ClaudeUsageControl.evaluate(p, observedAt: now, subscription: "pro")
        XCTAssertEqual(absent.diagnostic.fiveHour?.kind, .null)
        XCTAssertEqual(absent.diagnostic.sevenDay?.kind, .absent)
        XCTAssertNil(absent.diagnostic.fiveHour?.utilization)
    }

    func testDiagnosticEncodingIsClosedAllowlist() throws {
        var p = payload()
        p["subscription_type"] = "SECRET_PLAN"
        p["account"] = ["email": "SECRET_EMAIL", "token": "SECRET_TOKEN"]
        p["session"] = "SECRET_SESSION"; p["model_usage"] = ["SECRET_MODEL": "SECRET_USAGE"]
        var limits = p["rate_limits"] as! [String: Any]
        limits["model_scoped"] = [["model": "SECRET_MODEL", "reset": "SECRET_RESET"]]
        p["rate_limits"] = limits
        let evaluated = ClaudeUsageControl.evaluate(p, observedAt: now, subscription: "pro")
        XCTAssertNil(evaluated.diagnostic.rejection)
        XCTAssertEqual(evaluated.diagnostic.subscriptionType, .otherString)
        XCTAssertNil(evaluated.diagnostic.canonicalPlanMatches)
        _ = try evaluated.result.get() // Same previously accepted SDK label; not guessed.
        let encoded = try JSONEncoder().encode(evaluated.diagnostic)
        XCTAssertLessThan(encoded.count, 2048)
        let text = String(decoding: encoded, as: UTF8.self)
        for privateText in ["SECRET", "session", "model_usage", "email", "token", "behaviors", "2027", "26.5", "73.0"] {
            XCTAssertFalse(text.contains(privateText), privateText)
        }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(json.keys), Set(["availabilityKind", "rateLimitsAvailable", "planKind", "subscriptionType", "limitsKind", "modelScopedKind", "fiveHour", "sevenDay"]))
        XCTAssertEqual(try JSONDecoder().decode(ClaudeUsageControl.UsageDiagnostic.self, from: encoded), evaluated.diagnostic)
        p["behaviors"] = ["SECRET_BEHAVIOR"]
        let rejected = ClaudeUsageControl.evaluate(p, observedAt: now, subscription: "pro")
        XCTAssertEqual(rejected.diagnostic.rejection, .unexpectedPayload)
        assertFailure(.unsupported) { _ = try rejected.result.get() }
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(rejected.diagnostic), as: UTF8.self).contains("SECRET"))
    }

    func testPublicErrorDiagnosticIsCorrelatedAndCategorical() throws {
        var captured: [ClaudeCLIQuotaReport.Failure] = []
        func error(_ id: String, _ text: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "control_response", "response": ["subtype": "error", "request_id": id, "error": text]])
        }
        XCTAssertNil(try ClaudeUsageControl.response(error("other", "SECRET_EMAIL 429"), requestID: "quota", onPublicError: { captured.append($0) }))
        XCTAssertTrue(captured.isEmpty)
        for (raw, wanted): (String, ClaudeCLIQuotaReport.Failure) in [("SECRET_TOKEN 429", .limited), ("SECRET_EMAIL login required", .authentication), ("SECRET_PATH timed out", .timeout), ("SECRET_TEXT", .unsupported)] {
            assertFailure(wanted) { _ = try ClaudeUsageControl.response(error("quota", raw), requestID: "quota", onPublicError: { captured.append($0) }) }
            XCTAssertEqual(captured.last, wanted)
        }
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(captured), as: UTF8.self).contains("SECRET"))
    }
}
