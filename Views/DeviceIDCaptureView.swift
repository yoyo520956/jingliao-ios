import SwiftUI
import WebKit

/// 内置浏览器登录 chat.deepseek.com：拦截 users/login 请求体（device_id）与响应体（token）
struct DeviceIDCaptureView: View {
    @Binding var deviceID: String
    @Binding var token: String
    @Binding var userID: String
    @Environment(\.dismiss) private var dismiss
    @State private var gotDevice = false
    @State private var gotToken = false
    @State private var manual = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusStrip
                if gotToken {
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
                    }
                    .padding(.top, 60)
                    Spacer()
                } else {
                    DSLoginWebView { body in
                        Self.handle(body,
                                    onDevice: { d in deviceID = d; gotDevice = true },
                                    onLogin: { t, u in token = t; userID = u; gotToken = true })
                    }
                    tipsBar
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
            chip("登录态token", got: gotToken)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemBackground))
    }

    private func chip(_ title: String, got: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: got ? "checkmark.circle.fill" : "circle.dotted")
            Text(title).font(.caption2)
        }
        .foregroundColor(got ? Color.green : Color.secondary)
    }

    private var tipsBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("验证码 / 扫码均可：在此页面完成登录，请求里的 device_id 与响应里的 token 会自动抓取。")
                .font(.caption)
                .foregroundColor(.secondary)
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
            }
        }
        .padding(10)
        .background(Color(.secondarySystemBackground))
    }

    private func mask(_ s: String) -> String {
        guard s.count > 12 else { return String(repeating: "*", count: s.count) }
        return String(s.prefix(6)) + "…" + String(s.suffix(4))
    }

    static func handle(_ body: String, onDevice: @escaping (String) -> Void,
                       onLogin: @escaping (String, String) -> Void) {
        if body.hasPrefix("__RESP__") {
            let payload = String(body.dropFirst(8))
            guard let d = payload.data(using: .utf8),
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
            let user = (j["data"] as? [String: Any])?["user"] as? [String: Any]
                ?? (j["user"] as? [String: Any])
            guard let user else { return }
            if let t = user["token"] as? String, !t.isEmpty {
                onLogin(t, user["id"] as? String ?? "")
            }
        } else if let d = body.data(using: .utf8),
                  let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let dev = j.dstr("device_id") {
            onDevice(dev)
        }
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
      try {
        var of = window.fetch;
        window.fetch = function(input, init) {
          var url = typeof input === 'string' ? input : (input && input.url) || '';
          var p = of.apply(this, arguments);
          try {
            if (url.indexOf('/users/login') >= 0) {
              p.then(function(resp) {
                try {
                  resp.clone().text().then(function(t) {
                    webkit.messageHandlers.did.postMessage('__RESP__' + t);
                  });
                } catch(e) {}
              }).catch(function(){});
            }
          } catch(e) {}
          return p;
        };
        var oo = XMLHttpRequest.prototype.open;
        var os = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(m, u) {
          this.__u = u; return oo.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function(b) {
          try {
            if (this.__u && this.__u.indexOf('/users/login') >= 0) {
              var self = this;
              this.addEventListener('load', function() {
                try { webkit.messageHandlers.did.postMessage('__RESP__' + String(self.responseText)); } catch(e) {}
              });
            }
          } catch(e) {}
          return os.apply(this, arguments);
        };
      } catch(e) {}
    })();
    """#
}
