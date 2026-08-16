import Foundation
import Network
import AuralinkCore

/// A tiny, dependency-free localhost HTTP server the MCP server talks to.
///
/// It binds **only** to `127.0.0.1` (loopback) and requires a bearer capability
/// stored in the user's Application Support directory. Loopback alone is not an
/// authentication boundary: browser tabs and unrelated local processes can also
/// reach it. Browser-originated requests are rejected and write requests must be
/// JSON. Every handler hops to the `@MainActor` to read or mutate `AppModel`.
///
/// Endpoints (all JSON):
/// - `GET  /state`        → AudioState (+ current preset id/name)
/// - `GET  /devices`      → [OutputDevice]
/// - `GET  /presets`      → [EQPreset]
/// - `GET  /preset?id=…`  → EQPreset
/// - `POST /apply` {id, confirmed?} → { ok, needsConfirm }
/// - `POST /select-output` {uid, confirmed?} → { ok, needsConfirm, message }
/// - `POST /audition-preset` {preset, confirmed?} → { ok, needsConfirm, saved:false }
/// - `POST /save-current-preset` {name?, id?, tags?, confirmed?} → saved EQPreset or {ok, needsConfirm}
/// - `POST /rollback` {confirmed?} → { ok, needsConfirm }
/// - `POST /preset` {preset, confirmed?} or a bare EQPreset → saved EQPreset or {ok, needsConfirm}
/// - `POST /validate` <EQPreset> → ValidationResult
/// - `POST /reload-presets` → { ok, presetCount }  (disk reread; not gated)
/// - `POST /reload-knowledge` → { ok, profileCount, targetCurveCount }  (disk reread; not gated)
/// - `POST /route-system-audio` {confirmed?} → { ok, needsConfirm }
/// - `POST /restore-system-audio` {confirmed?} → { ok, needsConfirm }
/// - `POST /stop-routing` {confirmed?} → { ok, needsConfirm }
/// - `GET  /debug`       → internal routing diagnostics
// Note: `ControlServer` is internal (not `public`) because it consumes the
// app-internal `AppModel`. It is only ever instantiated from `AuralinkApp`
// inside this same target, so internal visibility is sufficient and avoids the
// "public initializer uses an internal type" access-control error.
final class ControlServer {

    private let model: AppModel
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private var bearerToken: String?
    private let queue = DispatchQueue(label: "com.auralink.eq.control")
    private let maximumRequestBytes = 1_048_576

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(model: AppModel, port: UInt16 = 8765) {
        self.model = model
        self.port = NWEndpoint.Port(rawValue: port) ?? 8765
    }

    // MARK: - Lifecycle

    @discardableResult
    func start() -> Bool {
        do {
            let bearerToken = try ControlAuthorization.loadOrCreateToken()
            let params = NWParameters.tcp
            // Loopback-only: require the local interface so we never bind 0.0.0.0.
            params.requiredInterfaceType = .loopback
            params.allowLocalEndpointReuse = true

            let listener = try NWListener(using: params, on: port)
            self.listener = listener
            self.bearerToken = bearerToken

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    NSLog("Auralink ControlServer failed: \(error)")
                }
            }
            listener.start(queue: queue)
            return true
        } catch {
            NSLog("Auralink ControlServer could not start: \(error)")
            listener = nil
            bearerToken = nil
            return false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        bearerToken = nil
    }

    // MARK: - Connection handling

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
    }

    /// Reads until we have headers (and the full body if Content-Length says so),
    /// then dispatches. Keeps it simple: one request per connection, then close.
    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if accumulated.count > self.maximumRequestBytes {
                self.send(self.error(413, "request exceeds 1 MiB limit"), on: connection)
                return
            }

            if let request = HTTPRequest(raw: accumulated), request.isComplete {
                self.route(request, on: connection)
                return
            }

            if isComplete || error != nil {
                // Connection ended before a full request arrived.
                connection.cancel()
                return
            }

            // Need more bytes.
            self.receiveRequest(on: connection, buffer: accumulated)
        }
    }

    // MARK: - Routing

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        Task { @MainActor in
            let response = self.dispatch(request)
            self.send(response, on: connection)
        }
    }

    /// All AppModel access happens here on the main actor.
    @MainActor
    private func dispatch(_ request: HTTPRequest) -> HTTPResponse {
        guard request.headers["origin"] == nil else {
            return error(403, "browser-originated requests are not allowed")
        }
        guard let bearerToken,
              ControlAuthorization.isAuthorized(headers: request.headers, token: bearerToken) else {
            return error(401, "missing or invalid control authorization")
        }
        if request.headers["transfer-encoding"] != nil {
            return error(400, "chunked transfer-encoding is not supported")
        }
        if request.method == "POST" {
            let contentType = request.headers["content-type"]?.lowercased() ?? ""
            guard contentType == "application/json" || contentType.hasPrefix("application/json;") else {
                return error(415, "POST requests require application/json")
            }
        }

        model.noteMCPActivity()

        switch (request.method, request.path) {

        case ("GET", "/state"):
            return json(model.audioState)

        case ("GET", "/debug"):
            return json(DebugResponse(
                audioState: model.audioState,
                statusMessage: model.statusMessage,
                lastError: model.lastError,
                routingRequested: model.routingRequested,
                systemEQActive: model.systemEQActive,
                engine: model.engine.debugSnapshot(),
                recentAudioEvents: model.recentAudioEvents
            ))

        case ("GET", "/devices"):
            return json(model.outputDevices)

        case ("GET", "/presets"):
            return json(model.presets)

        case ("GET", "/preset"):
            guard let id = request.query["id"] else {
                return error(400, "missing ?id")
            }
            if let p = (try? model.store.get(id: id)) ?? nil {
                return json(p)
            }
            if let p = model.presets.first(where: { $0.id == id }) {
                return json(p)
            }
            return error(404, "preset \(id) not found")

        case ("POST", "/apply"):
            return handleApply(body: request.body)

        case ("POST", "/select-output"):
            return handleSelectOutput(body: request.body)

        case ("POST", "/audition-preset"):
            return handleAuditionPreset(body: request.body)

        case ("POST", "/save-current-preset"):
            return handleSaveCurrentPreset(body: request.body)

        case ("POST", "/rollback"):
            return handleRollback(body: request.body)

        case ("POST", "/preset"):
            return handleSavePreset(body: request.body)

        case ("POST", "/validate"):
            return handleValidate(body: request.body)

        case ("POST", "/reload-presets"):
            model.loadPresets()
            return json(PresetsReloadResponse(
                ok: true,
                needsConfirm: false,
                presetCount: model.presets.count,
                message: "Preset library refreshed."
            ))

        case ("POST", "/reload-knowledge"):
            let counts = model.reloadKnowledge()
            return json(KnowledgeReloadResponse(
                ok: true,
                needsConfirm: false,
                profileCount: counts.profileCount,
                targetCurveCount: counts.targetCurveCount,
                message: model.statusMessage
            ))

        case ("POST", "/route-system-audio"):
            return handleRouteSystemAudio(body: request.body)

        case ("POST", "/restore-system-audio"):
            return handleRestoreSystemAudio(body: request.body)

        case ("POST", "/stop-routing"):
            return handleStopRouting(body: request.body)

        default:
            return error(404, "no route for \(request.method) \(request.path)")
        }
    }

    // MARK: - POST handlers

    @MainActor
    private func gate(_ kind: ControlWriteKind, confirmed: Bool?) -> ControlWriteDecision {
        model.audioState.permissionMode.decision(for: kind, confirmed: confirmed == true)
    }

    @MainActor
    private func forbiddenWrite() -> HTTPResponse {
        error(403, "permission mode is read-only; writes are not allowed")
    }

    @MainActor
    /// Re-points the live path at another real output device by UID.
    private func handleSelectOutput(body: Data) -> HTTPResponse {
        struct SelectBody: Decodable {
            let uid: String
            let confirmed: Bool?
        }
        guard let req = try? decoder.decode(SelectBody.self, from: body) else {
            return error(400, "expected { \"uid\": \"…\" }")
        }
        switch gate(.applyLive, confirmed: req.confirmed) {
        case .forbidden:
            return forbiddenWrite()
        case .needsConfirm:
            return json(SimpleOK(
                ok: false,
                needsConfirm: true,
                message: "The app requires confirmation before switching the live output."
            ))
        case .allow:
            let accepted = model.selectOutputDevice(uid: req.uid)
            return json(SimpleOK(
                ok: accepted,
                needsConfirm: false,
                message: accepted
                    ? "Output switch accepted."
                    : (model.lastError ?? model.statusMessage ?? "Output switch rejected.")
            ))
        }
    }

    @MainActor
    private func handleApply(body: Data) -> HTTPResponse {
        struct ApplyBody: Decodable {
            let id: String
            let confirmed: Bool?
        }
        guard let req = try? decoder.decode(ApplyBody.self, from: body) else {
            return error(400, "expected { \"id\": \"…\" }")
        }

        // Resolve the preset to apply (disk first, then the in-memory library).
        let preset = ((try? model.store.get(id: req.id)) ?? nil)
            ?? model.presets.first(where: { $0.id == req.id })
        guard let preset else {
            return error(404, "preset \(req.id) not found")
        }

        switch gate(.applyLive, confirmed: req.confirmed) {
        case .forbidden:
            return forbiddenWrite()
        case .needsConfirm:
            return json(ApplyResponse(
                ok: false,
                needsConfirm: true,
                presetId: preset.id,
                requestedRenderGeneration: nil
            ))
        case .allow:
            model.load(preset: preset, audition: true)
            return json(ApplyResponse(
                ok: true,
                needsConfirm: false,
                presetId: preset.id,
                requestedRenderGeneration: model.audioState.requestedRenderGeneration
            ))
        }
    }

    @MainActor
    private func handleAuditionPreset(body: Data) -> HTTPResponse {
        struct AuditionBody: Decodable {
            let preset: EQPreset
            let confirmed: Bool?
        }
        guard let req = try? decoder.decode(AuditionBody.self, from: body) else {
            return error(400, "expected { \"preset\": <EQPreset>, \"confirmed\": true|false }")
        }

        switch gate(.applyLive, confirmed: req.confirmed) {
        case .forbidden:
            return forbiddenWrite()
        case .needsConfirm:
            return json(AuditionResponse(
                ok: false,
                needsConfirm: true,
                saved: false,
                presetId: req.preset.id,
                presetName: req.preset.name,
                activeBands: req.preset.activeBands.count,
                clippingRisk: nil,
                requestedRenderGeneration: nil,
                message: "The app requires confirmation before auditioning live audio."
            ))
        case .allow:
            let preset = req.preset.normalized()
            let validation = model.validator.validate(preset)
            model.auditionTransientPreset(
                preset,
                message: "Auditioning \"\(preset.name)\". It is not saved yet."
            )
            return json(AuditionResponse(
                ok: true,
                needsConfirm: false,
                saved: false,
                presetId: preset.id,
                presetName: preset.name,
                activeBands: preset.activeBands.count,
                clippingRisk: validation.clippingRisk.rawValue,
                requestedRenderGeneration: model.audioState.requestedRenderGeneration,
                message: model.statusMessage
            ))
        }
    }

    @MainActor
    private func handleSaveCurrentPreset(body: Data) -> HTTPResponse {
        struct SaveBody: Decodable {
            let name: String?
            let id: String?
            let tags: [String]?
            let confirmed: Bool?
        }
        let req = (try? decoder.decode(SaveBody.self, from: body)) ?? SaveBody(name: nil, id: nil, tags: nil, confirmed: nil)
        switch gate(.createPreset, confirmed: req.confirmed) {
        case .forbidden:
            return forbiddenWrite()
        case .needsConfirm:
            return json(SimpleOK(
                ok: false,
                needsConfirm: true,
                message: "The app requires confirmation before saving a preset."
            ))
        case .allow:
            do {
                let saved = try model.saveLoadedPreset(name: req.name, id: req.id, extraTags: req.tags ?? [])
                return json(saved)
            } catch {
                return self.error(500, "save current preset failed: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func handleSavePreset(body: Data) -> HTTPResponse {
        struct Wrapped: Decodable {
            let preset: EQPreset
            let confirmed: Bool?
        }
        let wrapped = try? decoder.decode(Wrapped.self, from: body)
        let preset = wrapped?.preset ?? (try? decoder.decode(EQPreset.self, from: body))
        guard let preset else {
            return error(400, "invalid EQPreset JSON")
        }
        switch gate(.createPreset, confirmed: wrapped?.confirmed) {
        case .forbidden:
            return forbiddenWrite()
        case .needsConfirm:
            return json(SimpleOK(
                ok: false,
                needsConfirm: true,
                message: "The app requires confirmation before saving a preset."
            ))
        case .allow:
            do {
                let saved = try model.store.save(preset.normalized())
                model.loadPresets()
                return json(saved)
            } catch {
                return self.error(500, "save failed: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    private func handleRollback(body: Data) -> HTTPResponse {
        struct ConfirmBody: Decodable { let confirmed: Bool? }
        let confirmed = (try? decoder.decode(ConfirmBody.self, from: body))?.confirmed
        switch gate(.applyLive, confirmed: confirmed) {
        case .forbidden:
            return forbiddenWrite()
        case .needsConfirm:
            return json(RollbackResponse(
                ok: false,
                needsConfirm: true,
                presetId: nil,
                presetName: nil,
                requestedRenderGeneration: nil,
                message: "The app requires confirmation before rolling back live audio."
            ))
        case .allow:
            if let target = model.rollback() {
                return json(RollbackResponse(
                    ok: true,
                    needsConfirm: false,
                    presetId: target.id,
                    presetName: target.name,
                    requestedRenderGeneration: model.audioState.requestedRenderGeneration,
                    message: "Rollback request accepted; verify realtime commit state."
                ))
            }
            return json(RollbackResponse(
                ok: false,
                needsConfirm: false,
                presetId: nil,
                presetName: nil,
                requestedRenderGeneration: model.audioState.requestedRenderGeneration,
                message: "Nothing to roll back."
            ))
        }
    }

    @MainActor
    private func handleRouteSystemAudio(body: Data) -> HTTPResponse {
        struct ConfirmBody: Decodable { let confirmed: Bool? }
        let confirmed = (try? decoder.decode(ConfirmBody.self, from: body))?.confirmed
        switch gate(.applyLive, confirmed: confirmed) {
        case .forbidden:
            return forbiddenWrite()
        case .needsConfirm:
            return json(SimpleOK(
                ok: false,
                needsConfirm: true,
                message: "The app requires confirmation before routing system audio."
            ))
        case .allow:
            model.routeMacSoundThroughAuralink()
            return json(SimpleOK(
                ok: model.systemEQActive,
                needsConfirm: false,
                message: model.lastError ?? model.statusMessage
            ))
        }
    }

    @MainActor
    private func handleRestoreSystemAudio(body: Data) -> HTTPResponse {
        struct ConfirmBody: Decodable { let confirmed: Bool? }
        let confirmed = (try? decoder.decode(ConfirmBody.self, from: body))?.confirmed
        switch gate(.applyLive, confirmed: confirmed) {
        case .forbidden:
            return forbiddenWrite()
        case .needsConfirm:
            return json(SimpleOK(
                ok: false,
                needsConfirm: true,
                message: "The app requires confirmation before restoring system audio."
            ))
        case .allow:
            model.restoreMacSoundOutput()
            return json(SimpleOK(
                ok: !model.systemOutputRoutedToAuralink,
                needsConfirm: false,
                message: model.lastError ?? model.statusMessage
            ))
        }
    }

    @MainActor
    private func handleStopRouting(body: Data) -> HTTPResponse {
        struct ConfirmBody: Decodable { let confirmed: Bool? }
        let confirmed = (try? decoder.decode(ConfirmBody.self, from: body))?.confirmed
        switch gate(.applyLive, confirmed: confirmed) {
        case .forbidden:
            return forbiddenWrite()
        case .needsConfirm:
            return json(SimpleOK(
                ok: false,
                needsConfirm: true,
                message: "The app requires confirmation before stopping audio routing."
            ))
        case .allow:
            model.stopRouting()
            model.refreshDevices()
            return json(SimpleOK(
                ok: !model.audioState.routingActive,
                needsConfirm: false,
                message: model.lastError ?? model.statusMessage
            ))
        }
    }

    @MainActor
    private func handleValidate(body: Data) -> HTTPResponse {
        guard let preset = try? decoder.decode(EQPreset.self, from: body) else {
            return error(400, "invalid EQPreset JSON")
        }
        let result = model.validator.validate(preset.normalized())
        return json(result)
    }

    // MARK: - Response building

    private func json<T: Encodable>(_ value: T) -> HTTPResponse {
        if let data = try? encoder.encode(value) {
            return HTTPResponse(status: 200, reason: "OK", contentType: "application/json", body: data)
        }
        return error(500, "encoding failed for \(String(describing: T.self))")
    }

    private func error(_ status: Int, _ message: String) -> HTTPResponse {
        let payload = ["error": message]
        let body = (try? encoder.encode(payload)) ?? Data("{\"error\":\"unknown\"}".utf8)
        return HTTPResponse(status: status, reason: "Error", contentType: "application/json", body: body)
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        let data = response.serialized()
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private struct DebugResponse: Encodable {
    var audioState: AudioState
    var statusMessage: String?
    var lastError: String?
    var routingRequested: Bool
    var systemEQActive: Bool
    var engine: AudioEngineDebugSnapshot
    /// Timestamped trail of audible/notable path incidents, newest last.
    var recentAudioEvents: [AudioPathEvent]
}

// MARK: - Tiny response payloads

private struct SimpleOK: Encodable {
    let ok: Bool
    let needsConfirm: Bool?
    let message: String?
}

private struct KnowledgeReloadResponse: Encodable {
    let ok: Bool
    let needsConfirm: Bool?
    let profileCount: Int
    let targetCurveCount: Int
    let message: String?
}

private struct PresetsReloadResponse: Encodable {
    let ok: Bool
    let needsConfirm: Bool?
    let presetCount: Int
    let message: String?
}

private struct ApplyResponse: Encodable {
    let ok: Bool
    let needsConfirm: Bool
    let presetId: String
    let requestedRenderGeneration: UInt64?
}

private struct RollbackResponse: Encodable {
    let ok: Bool
    let needsConfirm: Bool?
    let presetId: String?
    let presetName: String?
    let requestedRenderGeneration: UInt64?
    let message: String?
}

private struct AuditionResponse: Encodable {
    let ok: Bool
    let needsConfirm: Bool
    let saved: Bool
    let presetId: String
    let presetName: String
    let activeBands: Int
    let clippingRisk: String?
    let requestedRenderGeneration: UInt64?
    let message: String?
}

// MARK: - Minimal HTTP/1.1 parsing & serialization

/// A parsed HTTP request — just the pieces this API needs.
private struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
    /// True once the full body (per Content-Length) has been received.
    let isComplete: Bool

    init?(raw: Data) {
        // Split headers / body on the first CRLFCRLF.
        guard let headerEndRange = HTTPRequest.range(of: Data("\r\n\r\n".utf8), in: raw) else {
            // Headers not fully received yet.
            return nil
        }
        let headerData = raw.subdata(in: raw.startIndex..<headerEndRange.lowerBound)
        let bodyStart = headerEndRange.upperBound
        let bodyData = raw.subdata(in: bodyStart..<raw.endIndex)

        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        // Request line: METHOD PATH?QUERY HTTP/1.1
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        self.method = String(requestLine[0]).uppercased()

        let fullPath = String(requestLine[1])
        if let qIndex = fullPath.firstIndex(of: "?") {
            self.path = String(fullPath[..<qIndex])
            self.query = HTTPRequest.parseQuery(String(fullPath[fullPath.index(after: qIndex)...]))
        } else {
            self.path = fullPath
            self.query = [:]
        }

        var hdrs: [String: String] = [:]
        for line in lines where !line.isEmpty {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                hdrs[key] = value
            }
        }
        self.headers = hdrs

        // Decide completeness against Content-Length (0 for GETs).
        let expected = Int(hdrs["content-length"] ?? "0") ?? 0
        self.body = bodyData
        self.isComplete = bodyData.count >= expected
    }

    private static func parseQuery(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            result[key] = value
        }
        return result
    }

    /// Find the byte range of `pattern` within `data` (no Foundation NSData dance).
    private static func range(of pattern: Data, in data: Data) -> Range<Data.Index>? {
        guard !pattern.isEmpty, data.count >= pattern.count else { return nil }
        let end = data.endIndex - pattern.count
        var i = data.startIndex
        while i <= end {
            if data[i..<(i + pattern.count)].elementsEqual(pattern) {
                return i..<(i + pattern.count)
            }
            i += 1
        }
        return nil
    }
}

/// A serializable HTTP/1.1 response.
private struct HTTPResponse {
    let status: Int
    let reason: String
    let contentType: String
    let body: Data

    func serialized() -> Data {
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += "Connection: close\r\n"
        header += "Cache-Control: no-store\r\n"
        header += "X-Content-Type-Options: nosniff\r\n"
        header += "\r\n"
        var data = Data(header.utf8)
        data.append(body)
        return data
    }
}
