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
                                    onLogin: { t, u in token = t; userID = u; gotToken = true },
                                    onLog: { l in
                                        logs.append(l)
                                        if logs.count > 14 { logs.removeFirst(logs.count - 14) }
                                    })
                    }
                    .frame(minHeight: 300)
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

    // ── 消息分发 ─────────────────────────────────────────────────────

    static func handle(_ body: String, onDevice: @escaping (String) -> Void,
                       onLogin: @escaping (String, String) -> Void,
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
                onLogin(t.0, t.1)
            }
        } else if body.hasPrefix("__LS__") {
            let kv = String(body.dropFirst(6))
            if let eq = kv.firstIndex(of: "=") {
                let key = String(kv[..<eq])
                let val = String(kv[kv.index(after: eq)...])
                if key.lowercased().contains("token"), val.count > 20, val.count < 2000,
                   val.hasPrefix("ey") || !val.lowercased().contains("undefined") {
                    onLogin(val, "")
                }
            }
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
        if let user, let t = user["token"] as? String, !t.isEmpty {
            return (t, user["id"] as? String ?? "")
        }
        if let t = j["token"] as? String, t.count > 20 {
            return (t, "")
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
      var of = window.fetch;
      if (of) {
        window.fetch = function(input, init){
          var url = typeof input === 'string' ? input : (input && input.url) || '';
          var body = (init && init.body) ? sb(init.body) : '';
          var isDS = isDS(url);
          if (isDS) post('__REQ__F ' + url + (body ? ' | ' + body.slice(0, 300) : ''));
          if (body && body.indexOf('device_id') >= 0) post('__BODY__' + body.slice(0, 3000));
          var p = of.apply(this, arguments);
          if (isDS) {
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
      XMLHttpRequest.prototype.open = function(m, u){ this.__u = u; this.__m = m; return oo.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function(b){
        var self = this;
        try {
          var body = sb(b);
          if (isDS(this.__u)) {
            post('__REQ__X ' + this.__u + (body ? ' | ' + body.slice(0, 300) : ''));
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
      function scanLS(){
        try {
          for (var i = 0; i < localStorage.length; i++) {
            var k = localStorage.key(i);
            var v = String(localStorage.getItem(k) || '');
            if (/token/i.test(k) && v.length > 20 && v.length < 2000) post('__LS__' + k + '=' + v);
          }
        } catch(e){}
      }
      setInterval(scanLS, 2500);
      setTimeout(scanLS, 800);
    })();
    """#
}
