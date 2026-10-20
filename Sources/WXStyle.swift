import SwiftUI
import Foundation

/// 微信 8.0.79 设计规范（对齐主流客户端口感）
/// 颜色/圆角/分隔线/导航栏/聊天气泡/输入栏全部按微信实测值
enum WX {
    // MARK: 颜色
    static let green = Color(red: 0x07/255, green: 0xC1/255, blue: 0x60/255)   // 品牌绿（按钮/选中态）
    static let bubbleMine = Color(red: 0x95/255, green: 0xEC/255, blue: 0x69/255)  // 我的气泡绿
    static let titleBlack = Color(red: 0x18/255, green: 0x18/255, blue: 0x18/255)  // 主文字
    static let secondary = Color(red: 0x8A/255, green: 0x8A/255, blue: 0x8F/255)   // 次级文字
    static let listBG = Color(red: 0xEF/255, green: 0xEF/255, blue: 0xF4/255)       // 列表背景
    static let cellBG = Color.white
    static let separator = Color(red: 0xE5/255, green: 0xE5/255, blue: 0xE5/255)
    static let inputBar = Color(red: 0xF7/255, green: 0xF7/255, blue: 0xF7/255)
    static let inputField = Color.white
    static let badgeRed = Color(red: 0xFA/255, green: 0x51/255, blue: 0x51/255)

    // MARK: 尺寸
    static let rowCorner: CGFloat = 8
    static let rowIcon: CGFloat = 29          // 行首图标（微信 29pt）
    static let navTitle: CGFloat = 17

    // MARK: 视图修饰
    /// 列表单元格：白底、8pt 圆角、左 15+头像+10+标题、右 chevron
    static func rowContent<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content(); Spacer(minLength: 0) }
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(WX.cellBG)
            .contentShape(Rectangle())
    }

    /// 分组卡片（微信设置风格）：圆角白卡 + 左右 15 inset + 底 8 分隔
    static var cardPadding: EdgeInsets { EdgeInsets(top: 0, leading: 15, bottom: 8, trailing: 15) }

    /// 系统 chevron（无资源依赖）
    static var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundColor(Color(red: 0xC8/255, green: 0xC8/255, blue: 0xCD/255))
    }
}

/// 行首小图标（29pt 圆角白底 + 绿色线性图标，微信风格）
struct WXRowIcon: View {
    let name: String
    var size: CGFloat = WX.rowIcon
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(WX.green.opacity(0.12))
            Image(uiImage: UIImage(named: name)?.withRenderingMode(.alwaysTemplate) ?? UIImage())
            .resizable()
            .renderingMode(.template)
            .foregroundColor(WX.green)
            .padding(size * 0.2)
        }
        .frame(width: size, height: size)
    }
}

/// 微信分组列表外壳：灰底 + 圆角白卡
struct WXGroup<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(WX.cellBG)
            .cornerRadius(WX.rowCorner)
            .padding(.horizontal, 15)
            .padding(.bottom, 8)
    }
}

/// 微信导航栏修饰：白底、居中 17pt 标题、底部发丝线、返回按钮
struct WXNavigationBar: ViewModifier {
    let title: String
    let showBack: Bool
    @Environment(\.presentationMode) var presentationMode
    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if showBack {
                    Button {
                        presentationMode.wrappedValue.dismiss()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 20, weight: .medium))
                            Text("返回")
                                .font(.system(size: 17))
                        }
                        .foregroundColor(WX.titleBlack)
                        .padding(.leading, 8)
                    }
                }
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: WX.navTitle, weight: .semibold))
                    .foregroundColor(WX.titleBlack)
                Spacer(minLength: 44)
            }
            .frame(height: 44)
            .background(Color.white)
            Rectangle().fill(WX.separator).frame(height: 0.5)
        }
        .background(Color.white.ignoresSafeArea(edges: .top))
        content
    }
}

struct WXRowCell: View {
    let icon: String?
    let title: String
    let subtitle: String?
    let value: String?
    let showChevron: Bool
    var body: some View {
        WX.rowContent {
            if let icon { WXRowIcon(name: icon) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 17)).foregroundColor(WX.titleBlack)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 13)).foregroundColor(WX.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let value, !value.isEmpty {
                Text(value).font(.system(size: 15)).foregroundColor(WX.secondary)
                    .lineLimit(1)
            }
            if showChevron { WX.chevron }
        }
    }
}

/// 微信 tab 自定义图标（PNG 模板着色；找不到资源则纯文字）
struct WXTabIcon: View {
    let name: String
    let title: String
    let selected: Bool
    var body: some View {
        VStack(spacing: 3) {
            Group {
                if let u = UIImage(named: name) {
                    Image(uiImage: u).renderingMode(.template)
                } else {
                    Image(systemName: "circle")
                }
            }
            .foregroundColor(selected ? WX.green : WX.secondary)
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(selected ? WX.green : WX.secondary)
        }
    }
}
