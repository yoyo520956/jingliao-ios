import SwiftUI
import WebKit

/// 内置浏览器登录：全量拦截 deepseek.com 域请求/响应 + localStorage 轮询抓 token
struct DeviceIDCaptureView: View {
    @Binding var deviceID: String
    @Binding var token: String
    @Binding var userID: String
    @Environment(\.dismiss) private var dismiss
    @State private var gotDevice = false
    @State private var gotToken = false
    @State private var manual = ""
    @State private var logs: [String] = []
    @State private var reloadTick = 0
    @State private var validated: Set<String> = []
    @State private var validating: Set<String> = []
    @State private var failedLogged: Set<String> = []

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusStrip
                if gotToken {
                    capturedPanel
                } else {
                    DSLoginWebView { msg in
                        Self.handle(msg,
                                    onDevice: { d in deviceID = d; gotDevice = true },
                                    onCandidate: { t, s in
                                        Task { await validateCandidate(t, source: s) }
                                    },
                                    onLog: { l in appendLog(l) })
                    }
                    .id(reloadTick)
                    .frame(minHeight: 300)
                    .task {
                        while !gotToken {
                            harvestCookies()
                            try? await Task.sleep(nanoseconds: 3_000_000_000)
                        }
                    }
                    diagPanel
                }
            }
            .navigationTitle("网页登录导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 8) {
            chip("device_id", got: gotDevice)
            chip("token", got: gotToken)
            Spacer()
            Text("拦截 \(logs.count) 条")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private var capturedPanel: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundColor(Color.green)
            Text("登录态已抓到")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("token: " + mask(token))
                Text("device_id: " + (deviceID.isEmpty ? "（未捕获，可手填）" : deviceID))
            }
            .font(.caption)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .textSelection(.enabled)
            Button("完成，写回账号") { dismiss() }
                .buttonStyle(.borderedProminent)
            Spacer()
        }
        .padding(.top, 60)
        .frame(maxWidth: .infinity)
    }

    private var diagPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("抓包日志（登录页若白屏这里会一直空）")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Button("复制诊断") {
                    UIPasteboard.general.string = logs.joined(separator: "\n")
                }
                .font(.caption2)
                .buttonStyle(.borderless)
            }
            ForEach(logs.suffix(5), id: \.self) { l in
                Text(l)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            HStack {
                TextField("手动粘贴 device_id（可选）", text: $manual)
                    .font(.caption)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("填入") {
                    if !manual.isEmpty {
                        deviceID = manual
                        gotDevice = true
                    }
                }
                .buttonStyle(.bordered)
                Button("清登录重来") {
                    WKWebsiteDataStore.default().removeData(
                        ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                        modifiedSince: Date(timeIntervalSince1970: 0),
                        completionHandler: {})
                    logs.append("已清除网页登录数据，重新登录一次")
                    reloadTick += 1
                }
                .buttonStyle(.bordered)
                .font(.caption)
            }
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
    }

    private func chip(_ title: String, got: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: got ? "checkmark.circle.fill" : "circle.dotted")
            Text(title).font(.caption2)
        }
        .foregroundColor(got ? Color.green : Color.secondary)
    }

    private func mask(_ s: String) -> String {
        guard s.count > 12 else { return String(repeating: "*", count: s.count) }
        return String(s.prefix(6)) + "…" + String(s.suffix(4))
    }

    // ── 候选验证：所有 token 候选先打 users/current 验真，过了才亮灯 ──

    private func validateCandidate(_ raw: String, source: String) async {
        let t = raw.trimmingCharacters(in: .whitespaces)
        guard t.count >= 15, t.count < 2000,
              !validated.contains(t), !validating.contains(t),
              !failedLogged.contains(t) else { return }
        validating.insert(t)
        defer { validating.remove(t) }
        let ok = await Self.checkToken(t, deviceID: deviceID)
        let head = String(t.prefix(10))
        if ok {
            validated.insert(t)
            token = t
            userID = ""
            gotToken = true
            appendLog("✓ 验证通过 [\(source)] len=\(t.count) head=\(head)…")
        } else {
            failedLogged.insert(t)
            appendLog("✗ 候选失败 [\(source)] len=\(t.count) head=\(head)…")
        }
    }

    private func appendLog(_ l: String) {
        guard logs.last != l else { return }
        logs.append(l)
        if logs.count > 14 { logs.removeFirst(logs.count - 14) }
    }

    static func checkToken(_ tok: String, deviceID: String) async -> Bool {
        let identity = DSIdentity(deviceID: deviceID)
        guard let url = URL(string: DSConfig.apiBase + "/users/current") else { return false }
        let req = DSIdentity.request(url, method: "GET",
                                     headers: identity.authedHeaders(site: "same-origin", token: tok),
                                     timeout: 20)
        return (try? await DSHttp.fetchJSON(req)) != nil
    }

    private func harvestCookies() {
        WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
            DispatchQueue.main.async {
                var names: [String] = []
                for c in cookies where c.domain.lowercased().contains("deepseek") {
                    names.append(c.name)
                    let val = c.value
                    let name = c.name.lowercased()
                    let jwtish = val.hasPrefix("ey") && !val.contains("{") && val.count > 40
                    let nameish = (name.contains("token") || name.contains("session") || name.contains("auth"))
                        && val.count > 20 && val.count < 2000 && !val.contains("{")
                    if jwtish || nameish {
                        Task { await self.validateCandidate(val, source: "cookie:" + c.name) }
                    }
                }
                if !names.isEmpty {
                    appendLog("cookie: " + names.joined(separator: ","))
                }
            }
        }
    }

    // ── 消息分发 ─────────────────────────────────────────────────────

    static func handle(_ body: String, onDevice: @escaping (String) -> Void,
                       onCandidate: @escaping (String, String) -> Void,
                       onLog: @escaping (String) -> Void) {
        if body.hasPrefix("__BODY__") {
            let payload = String(body.dropFirst(8))
            if let d = payload.data(using: .utf8),
               let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
               let dev = j.dstr("device_id") {
                onDevice(dev)
            }
        } else if body.hasPrefix("__RESP__") {
            let payload = String(body.dropFirst(8))
            if let t = Self.tokenFromJSON(payload) {
                onCandidate(t.0, "登录响应")
            }
        } else if body.hasPrefix("__LS__") {
            let kv = String(body.dropFirst(6))
            if let eq = kv.firstIndex(of: "=") {
                let key = String(kv[..<eq]).lowercased()
                let val = String(kv[kv.index(after: eq)...])
                // 登录 token 只认：userToken 键，或 JWT 特征（eyJ 开头且非 JSON）
                let isJWT = val.hasPrefix("ey") && !val.contains("{") && val.count > 40
                let isUserTokenKey = key.contains("usertoken")
                if (isUserTokenKey || isJWT), val.count > 40, val.count < 2000, !val.contains("{") {
                    onCandidate(val, "LS")
                }
            }
        } else if body.hasPrefix("__LSD__") {
            let kv = String(body.dropFirst(7))
            if let eq = kv.firstIndex(of: "=") {
                let val = String(kv[kv.index(after: eq)...])
                // 数美 device_id 兜底：纯字符串、无 JSON 结构、长度像指纹
                if val.count >= 20, val.count <= 128, !val.contains("{"), !val.contains(" "),
                   val.range(of: "^[A-Za-z0-9+/=_-]+$", options: .regularExpression) != nil {
                    onDevice(val)
                }
            }
        } else if body.hasPrefix("__LST__") {
            let kv = String(body.dropFirst(7))
            if let eq = kv.firstIndex(of: "=") {
                let key = String(kv[..<eq])
                var val = String(kv[kv.index(after: eq)...])
                var src = "LS:" + key
                // JSON 包裹的值（如缓存对象）先拆包提取 token/value 字段
                if val.hasPrefix("{"), let d = val.data(using: .utf8),
                   let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
                    if let inner = j["token"] as? String, !inner.isEmpty {
                        val = inner
                        src = "LS:" + key + ".token"
                    } else if let inner = j["value"] as? String, !inner.isEmpty {
                        val = inner
                        src = "LS:" + key + ".value"
                    }
                }
                if val.count >= 15, val.count <= 2000 {
                    onCandidate(val, src)
                }
            }
        } else if body.hasPrefix("__LSJ__") {
            let kv = String(body.dropFirst(7))
            if let eq = kv.firstIndex(of: "=") {
                let val = String(kv[kv.index(after: eq)...])
                onCandidate(val, "LSJWT:" + String(kv[..<eq]))
            }
        } else if body.hasPrefix("__AUTH__") {
            var t = String(body.dropFirst(8))
            if t.hasPrefix("Bearer ") { t = String(t.dropFirst(7)) }
            if t.count > 30, t.count < 2000, !t.contains("{"), !t.contains(" ") {
                onCandidate(t, "请求头")
            }
        } else if body.hasPrefix("__LSK__") {
            onLog("LS键: " + String(body.dropFirst(7)))
        } else if body.hasPrefix("__REQ__") || body.hasPrefix("__RES__") {
            onLog(String(body.prefix(150)))
        } else if let d = body.data(using: .utf8),
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let dev = j.dstr("device_id") {
            onDevice(dev)
        }
    }

    static func tokenFromJSON(_ s: String) -> (String, String)? {
        guard let d = s.data(using: .utf8),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        let user = (j["data"] as? [String: Any])?["user"] as? [String: Any]
            ?? (j["user"] as? [String: Any])
            ?? (j["biz_data"] as? [String: Any])?["user"] as? [String: Any]
        // 只认 user 对象里的 token（hif 风控令牌的裸 token 字段一律拒收）
        if let user, let t = user["token"] as? String, t.count > 30 {
            return (t, user["id"] as? String ?? "")
        }
        return nil
    }
}

struct DSLoginWebView: UIViewRepresentable {
    var onMessage: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onMessage: onMessage)
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "did")
        let hook = WKUserScript(source: Self.hookJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        cfg.userContentController.addUserScript(hook)
        let wv = WKWebView(frame: .zero, configuration: cfg)
        if let url = URL(string: "https://chat.deepseek.com/sign_in") {
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKScriptMessageHandler {
        var onMessage: (String) -> Void
        init(onMessage: @escaping (String) -> Void) { self.onMessage = onMessage }
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "did", let b = message.body as? String else { return }
            DispatchQueue.main.async { self.onMessage(b) }
        }
    }

    static let hookJS = #"""
    (function(){
      function post(m){ try { webkit.messageHandlers.did.postMessage(m); } catch(e){} }
      function isDS(u){ return u && u.indexOf('deepseek.com') >= 0; }
      function sb(b){ try { return typeof b === 'string' ? b : JSON.stringify(b); } catch(e){ return ''; } }
      function grabAuth(h, url){
        try {
          if (!h) return;
          var a = null;
          if (typeof Headers !== 'undefined' && h instanceof Headers) {
            a = h.get('authorization');
          } else if (Object.prototype.toString.call(h) === '[object Array]') {
            for (var i = 0; i < h.length; i++) { if (String(h[i][0]).toLowerCase() === 'authorization') a = h[i][1]; }
          } else if (typeof h === 'object') {
            for (var k in h) { if (k.toLowerCase() === 'authorization') a = h[k]; }
          }
          if (a && String(a).length > 20 && url && url.indexOf('/api/v0/') >= 0) post('__AUTH__' + String(a));
        } catch(e){}
      }
      var of = window.fetch;
      if (of) {
        window.fetch = function(input, init){
          var url = typeof input === 'string' ? input : (input && input.url) || '';
          var body = (init && init.body) ? sb(init.body) : '';
          var isD = isDS(url);
          if (isD) post('__REQ__F ' + url + (body ? ' | ' + body.slice(0, 300) : ''));
          grabAuth(init && init.headers, url);
          if (body && body.indexOf('device_id') >= 0) post('__BODY__' + body.slice(0, 3000));
          var p = of.apply(this, arguments);
          if (isD) {
            p.then(function(resp){
              try {
                resp.clone().text().then(function(t){
                  post('__RES__' + resp.status + ' ' + url + ' | ' + t.slice(0, 200));
                  if (t.indexOf('"token"') >= 0) post('__RESP__' + t.slice(0, 4000));
                });
              } catch(e){}
            }).catch(function(){});
          }
          return p;
        };
      }
      var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
      var orh = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.setRequestHeader = function(n, v){
        try { this.__hh = this.__hh || {}; this.__hh[String(n).toLowerCase()] = v; } catch(e){}
        return orh.apply(this, arguments);
      };
      XMLHttpRequest.prototype.open = function(m, u){ this.__u = u; this.__m = m; return oo.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function(b){
        var self = this;
        try {
          var body = sb(b);
          if (isDS(this.__u)) {
            post('__REQ__X ' + this.__u + (body ? ' | ' + body.slice(0, 300) : ''));
            grabAuth(this.__hh, this.__u);
            if (body && body.indexOf('device_id') >= 0) post('__BODY__' + body.slice(0, 3000));
            this.addEventListener('load', function(){
              try {
                var t = String(self.responseText || '');
                post('__RES__' + self.status + ' ' + self.__u + ' | ' + t.slice(0, 200));
                if (t.indexOf('"token"') >= 0) post('__RESP__' + t.slice(0, 4000));
              } catch(e){}
            });
          }
        } catch(e){}
        return os.apply(this, arguments);
      };
      var seen = {};
      function scanLS(){
        try {
          for (var i = 0; i < localStorage.length; i++) {
            var k = localStorage.key(i);
            if (!seen[k]) { seen[k] = 1; post('__LSK__' + k); }
            var v = String(localStorage.getItem(k) || '');
            if (/token/i.test(k) && v.length > 15 && v.length < 4000) post('__LST__' + k + '=' + v);
            if (/device|shumei|_sm|fm/i.test(k) && v.length >= 20 && v.length <= 300 && v.indexOf('{') < 0) post('__LSD__' + k + '=' + v);
          }
        } catch(e){}
      }
      setInterval(scanLS, 2500);
      setTimeout(scanLS, 800);
    })();
    """#
}
