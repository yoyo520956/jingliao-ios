import SwiftUI

/// 人设预设库——一键切换内置必发提示词；微信 8.0.79 风格
struct PresetListView: View {
    @State private var presets: [PersonaPreset] = PromptStore.shared.presets
    @State private var editing: PersonaPreset?
    @State private var isNew = false
    @State private var appliedName: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                groupHeader("点「启用」即刻生效：内容会替换「内置必发提示词」，每条请求都带")
                WXGroup {
                    ForEach(presets) { p in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                WXRowIcon(name: "ic_prompt")
                                Text(p.name).font(WX.MBF.serif(17)).foregroundColor(WX.titleBlack)
                                Spacer(minLength: 6)
                                Button("启用") {
                                    PromptStore.shared.applyPreset(p)
                                    appliedName = p.name
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { appliedName = nil }
                                }
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(WX.green))
                                Button("编辑") { editing = p; isNew = false }
                                    .font(.system(size: 14))
                                    .foregroundColor(WX.green)
                            }
                            Text(p.content)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(WX.secondary)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 12)
                    }
                    .onDelete { offsets in
                        for i in offsets { PromptStore.shared.removePreset(presets[i].id) }
                        presets = PromptStore.shared.presets
                    }
                }
                groupFooter("预设只存在本机。改完想永久生效记得去「底层提示词」看一眼内置必发内容是否已替换。")
            }
        }
        .background(WX.listBG)
        .scrollContentBackground(.hidden)
        .navigationTitle("人设预设库")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    editing = PersonaPreset(name: "", content: "")
                    isNew = true
                } label: {
                    Image(systemName: "plus").foregroundColor(WX.green)
                }
            }
        }
        .sheet(item: $editing) { p in
            PresetEditView(preset: p, isNew: isNew) {
                presets = PromptStore.shared.presets
            }
        }
        .overlay(alignment: .bottom) {
            if let n = appliedName {
                Text("已启用「\(n)」✓")
                    .font(.caption)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Capsule().fill(WX.green))
                    .foregroundColor(.white)
                    .padding(.bottom, 24)
            }
        }
    }

    private func groupHeader(_ t: String) -> some View {
        Text(t).font(.system(size: 13)).foregroundColor(WX.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 6)
    }
    private func groupFooter(_ t: String) -> some View {
        Text(t).font(.system(size: 12)).foregroundColor(WX.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 0).padding(.bottom, 4)
    }
}

/// 预设编辑（新建/改名改内容）
private struct PresetEditView: View {
    @State var preset: PersonaPreset
    let isNew: Bool
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("名称").font(.system(size: 12)).foregroundColor(WX.secondary)
                    TextField("如：软桃·倾瑶", text: $preset.name)
                        .font(.system(size: 15))
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: WX.rowCorner).stroke(WX.separator, lineWidth: 0.5))
                    Text("提示词内容（将随每条请求全量发送）").font(.system(size: 12)).foregroundColor(WX.secondary)
                    TextEditor(text: $preset.content)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 300)
                        .overlay(RoundedRectangle(cornerRadius: WX.rowCorner).stroke(WX.separator, lineWidth: 0.5))
                }
                .padding(15)
            }
            .background(WX.listBG)
            .scrollContentBackground(.hidden)
            .navigationTitle(isNew ? "新建预设" : "编辑预设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        guard !preset.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                        PromptStore.shared.upsertPreset(preset)
                        onDone()
                        dismiss()
                    }
                    .foregroundColor(WX.green)
                }
            }
        }
    }
}
