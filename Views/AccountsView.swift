import SwiftUI

struct AccountsView: View {
    @EnvironmentObject var store: DSAccountStore
    @State private var showAdd = false
    @State private var busyID = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(store.accounts) { a in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(a.display).fontWeight(.medium)
                                Spacer()
                                Text(a.statusText)
                                    .font(.caption2)
                                    .foregroundColor(Color.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(chipColor(a)))
                            }
                            Text("device_id: " + a.deviceID)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .textSelection(.enabled)
                            HStack {
                                if busyID == a.id {
                                    ProgressView().scaleEffect(0.7)
                                } else {
                                    Button("登录 / 刷新") { Task { await login(a) } }
                                        .buttonStyle(.bordered)
                                        .font(.caption)
                                }
                                Button("删除", role: .destructive) { store.remove(a.id) }
                                    .buttonStyle(.bordered)
                                    .font(.caption)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } header: {
                    Text("DeepSeek 账号池（空闲最久优先）")
                } footer: {
                    Text("建议使用小号。device_id 必须来自真实浏览器登录——点「抓取」在内置浏览器登录一次自动提取；伪造值会触发 RISK_DEVICE_DETECTED。")
                }
                Section {
                    Button {
                        showAdd = true
                    } label: {
                        Label("添加账号", systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle("账号")
            .sheet(isPresented: $showAdd) { AddAccountSheet() }
        }
    }

    private func chipColor(_ a: DSAccount) -> Color {
        if a.token.isEmpty { return Color.gray }
        if a.muted { return Color.orange }
        return Color.green
    }

    private func login(_ a: DSAccount) async {
        busyID = a.id
        defer { busyID = "" }
        do {
            let u = try await DSAuth.login(email: a.email, mobile: a.mobile,
                                           areaCode: a.areaCode, password: a.password,
                                           deviceID: a.deviceID)
            var m = a
            m.token = u.token
            m.userID = u.id
            m.muted = u.isMuted
            m.muteUntil = u.muteUntil
            store.update(m)
            let dev = m.deviceID
            let tok = u.token
            Task.detached {
                await DSAuth.checkDevice(token: tok, deviceID: dev)
            }
            EngineLog.shared.add("登录成功: \(m.display)")
        } catch {
            EngineLog.shared.add("登录失败 \(a.display): \(error.localizedDescription)")
        }
    }
}

struct AddAccountSheet: View {
    @EnvironmentObject var store: DSAccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var useEmail = true
    @State private var email = ""
    @State private var mobile = ""
    @State private var areaCode = "+86"
    @State private var password = ""
    @State private var deviceID = ""
    @State private var showCapture = false

    var body: some View {
        NavigationStack {
            Form {
                Section("备注") {
                    TextField("可选，如「小号1」", text: $label)
                }
                Section("登录方式") {
                    Picker("", selection: $useEmail) {
                        Text("邮箱").tag(true)
                        Text("手机号").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if useEmail {
                        TextField("邮箱", text: $email)
                            .keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        HStack {
                            TextField("+86", text: $areaCode).frame(width: 70)
                            TextField("手机号", text: $mobile).keyboardType(.phonePad)
                        }
                    }
                    SecureField("密码", text: $password)
                }
                Section("设备指纹 device_id") {
                    HStack {
                        TextField("登录抓取或手动粘贴", text: $deviceID)
                            .font(.caption)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("抓取") { showCapture = true }
                            .buttonStyle(.bordered)
                    }
                }
                Section {
                    Button("保存并加入账号池") {
                        var a = DSAccount()
                        a.label = label
                        a.email = useEmail ? email : ""
                        a.mobile = useEmail ? "" : mobile
                        a.areaCode = areaCode
                        a.password = password
                        if !deviceID.isEmpty { a.deviceID = deviceID }
                        store.add(a)
                        dismiss()
                    }
                    .disabled(password.isEmpty || (useEmail ? email.isEmpty : mobile.isEmpty))
                }
            }
            .navigationTitle("添加账号")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .sheet(isPresented: $showCapture) {
                DeviceIDCaptureView(deviceID: $deviceID)
            }
        }
    }
}
