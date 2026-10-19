import Foundation

struct DSUser {
    var id: String
    var token: String
    var isMuted: Bool
    var muteUntil: Double
}

enum DSAuth {
    /// POST /users/login —— email/mobile 二选一，另一个传空串（真实客户端固定 6 个 key）
    static func login(email: String, mobile: String, areaCode: String,
                      password: String, deviceID: String) async throws -> DSUser {
        let identity = DSIdentity(deviceID: deviceID)
        let body: [String: Any] = [
            "email": email,
            "mobile": mobile,
            "password": password,
            "area_code": areaCode,
            "device_id": identity.deviceID,
            "os": DSConfig.clientOS,
        ]
        let url = URL(string: DSConfig.apiBase + "/users/login")!
        let req = DSIdentity.request(url, method: "POST",
                                     headers: identity.baseHeaders(site: "same-origin"),
                                     jsonBody: body)
        let env = try await DSHttp.fetchJSON(req)
        guard let user = (env.data?["user"] as? [String: Any])
                ?? (env.bizData?["user"] as? [String: Any])
                ?? (env.data?["biz_data"] as? [String: Any])?["user"] as? [String: Any] else {
            throw DSError(message: "登录响应缺少 user 字段")
        }
        guard let token = user["token"] as? String, !token.isEmpty else {
            throw DSError(message: "登录响应缺少 token")
        }
        var muted = false
        var muteUntil = 0.0
        if let chat = user["chat"] as? [String: Any] {
            if let b = chat["is_muted"] as? Bool { muted = b }
            else if let n = chat["is_muted"] as? NSNumber { muted = n.intValue == 1 }
            muteUntil = (chat["mute_until"] as? NSNumber)?.doubleValue ?? 0
        }
        return DSUser(id: user["id"] as? String ?? "", token: token, isMuted: muted, muteUntil: muteUntil)
    }

    /// 登录后上报一次设备校验（对齐真实客户端）
    static func checkDevice(token: String, deviceID: String) async {
        guard !token.isEmpty else { return }
        let identity = DSIdentity(deviceID: deviceID)
        if let url = URL(string: DSConfig.apiBase + "/users/auth_token/check_device") {
            let req = DSIdentity.request(url, method: "POST",
                                         headers: identity.authedHeaders(site: "same-origin", token: token),
                                         jsonBody: [:], timeout: 30)
            _ = try? await DSHttp.fetchJSON(req)
        }
    }
}
