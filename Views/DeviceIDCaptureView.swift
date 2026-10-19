import SwiftUI
import WebKit

/// 内置浏览器登录 chat.deepseek.com，拦截 users/login 请求体提取 device_id
struct DeviceIDCaptureView: View {
    @Binding var deviceID: String
    @Environment(\.dismiss) private var dismiss
    @State private var captured = false
    @State private var manual = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if captured {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 44))
                            .foregroundColor(Color.green)
                        Text("已抓到 device_id")
                            .font(.headline)
                        Text(deviceID)
                            .font(.caption)
                            .textSelection(.enabled)
                            .foregroundColor(.secondary)
                        Button("完成") { dismiss() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 80)
                    Spacer()
                } else {
                    DSLoginWebView { body in
                        if let d = Self.extract(body) {
                            deviceID = d
                            captured = true
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("在此页面登录一次 DeepSeek，登录请求里的 device_id 会自动填回表单。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            TextField("或手动粘贴 device_id", text: $manual)
                                .font(.caption)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("填入") {
                                if !manual.isEmpty {
                                    deviceID = manual
                                    captured = true
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(10)
                    .background(Color(.secondarySystemBackground))
                }
            }
            .navigationTitle("抓取 device_id")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    static func extract(_ body: String) -> String? {
        guard let d = body.data(using: .utf8),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return j.dstr("device_id")
    }
}

struct DSLoginWebView: UIViewRepresentable {
    var onLoginBody: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoginBody: onLoginBody)
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
        var onLoginBody: (String) -> Void
        init(onLoginBody: @escaping (String) -> Void) { self.onLoginBody = onLoginBody }
        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "did", let b = message.body as? String else { return }
            DispatchQueue.main.async { self.onLoginBody(b) }
        }
    }

    static let hookJS = #"""
    (function(){
      try {
        var of = window.fetch;
        window.fetch = function(input, init) {
          try {
            var url = typeof input === 'string' ? input : (input && input.url) || '';
            if (url.indexOf('/users/login') >= 0 && init && init.body) {
              webkit.messageHandlers.did.postMessage(String(init.body));
            }
          } catch(e) {}
          return of.apply(this, arguments);
        };
        var oo = XMLHttpRequest.prototype.open;
        var os = XMLHttpRequest.prototype.send;
        XMLHttpRequest.prototype.open = function(m, u) {
          this.__u = u; return oo.apply(this, arguments);
        };
        XMLHttpRequest.prototype.send = function(b) {
          try {
            if (this.__u && this.__u.indexOf('/users/login') >= 0 && b) {
              webkit.messageHandlers.did.postMessage(String(b));
            }
          } catch(e) {}
          return os.apply(this, arguments);
        };
      } catch(e) {}
    })();
    """#
}
