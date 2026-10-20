import Foundation

/// 客户端拟态身份：UA + x-client-* 头 + 设备指纹（对齐官方 Web 客户端抓包）
struct DSIdentity {
    var deviceID: String

    init(deviceID: String) {
        self.deviceID = deviceID.isEmpty ? UUID().uuidString : deviceID
    }

    var tzOffsetMinutes: String {
        String(TimeZone.current.secondsFromGMT() / 60)
    }

    func baseHeaders(site: String) -> [String: String] {
        [
            "User-Agent": DSConfig.userAgent,
            "Accept": "*/*",
            "Accept-Language": "zh-CN",
            "Referer": DSConfig.origin + "/",
            "Origin": DSConfig.origin,
            "Sec-Fetch-Dest": "empty",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Site": site,
            "Sec-Ch-Ua": DSConfig.secChUa,
            "Sec-Ch-Ua-Mobile": "?0",
            "Sec-Ch-Ua-Platform": "\"Windows\"",
            "X-Device-Id": deviceID,
            "X-Device-Model": DSConfig.deviceModel,
            "X-Client-Timezone-Offset": tzOffsetMinutes,
            "X-Client-Version": DSConfig.clientVersion,
            "X-Client-Platform": DSConfig.clientPlatform,
            "X-Client-Locale": DSConfig.clientLocale,
            "X-Client-Bundle-Id": DSConfig.clientBundleID,
        ]
    }

    func authedHeaders(site: String, token: String) -> [String: String] {
        var h = baseHeaders(site: site)
        h["Authorization"] = "Bearer " + token
        return h
    }

    static func request(_ url: URL, method: String, headers: [String: String],
                        jsonBody: [String: Any]? = nil, timeout: Double = 60) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let b = jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: b)
        }
        return req
    }
}

// ── HTTP JSON 便捷 ────────────────────────────────────────────────────

enum DSHttp {
    static func fetchJSON(_ req: URLRequest) async throws -> DSEnvelope {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 202, let h = (resp as? HTTPURLResponse)?.allHeaderFields["x-amzn-waf-action"] as? String, !h.isEmpty {
            throw DSError(message: "触发 AWS WAF 风控（境外 IP 限制），请换网络环境重试")
        }
        guard let env = DSEnvelope.parse(data) else {
            throw DSError(message: "响应解析失败 HTTP \(status)：\(String(data: data.prefix(200), encoding: .utf8) ?? "")")
        }
        if env.code != 0 {
            throw DSError(message: "上游错误 code=\(env.code) msg=\(env.msg)")
        }
        if env.bizCode != 0 {
            throw DSError(message: "上游业务错误 biz_code=\(env.bizCode) msg=\(env.bizMsg)")
        }
        return env
    }
}
