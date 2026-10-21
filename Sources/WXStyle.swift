import SwiftUI
import Foundation

/// 墨白札记设计系统（MoBai Journal）
/// 东方书卷气：宣纸底 + 松烟墨 + 鸽血红一枚钤印。字体衬线（Songti SC）做标题，
/// 气泡去尾、直角 2pt 圆角，页面如翻开一册旧书。
/// 命名沿用 WX 前缀，保证其余视图零改动即可整体换肤。
enum WX {
    // MARK: 颜色（墨白札Note）
    static let green = Color(red: 0xA6/255, green: 0x3D/255, blue: 0x2A/255)   // 鸽血红（钤印色：按钮/选中/开关/徽标，取代原微信绿）
    static let bubbleMine = Color(red: 0x24/255, green: 0x20/255, blue: 0x16/255)  // 我的气泡：松烟墨
    static let titleBlack = Color(red: 0x2C/255, green: 0x26/255, blue: 0x18/255)  // 主文字（浓墨）
    static let secondary = Color(red: 0x8D/255, green: 0x82/255, blue: 0x71/255)   // 次级文字（淡墨）
    static let listBG = Color(red: 0xEF/255, green: 0xEA/255, blue: 0xDD/255)       // 列表底（陈纸）
    static let cellBG = Color(red: 0xFF/255, green: 0xFD/255, blue: 0xF7/255)       // 卡片底（宣纸）
    static let separator = Color(red: 0xE5/255, green: 0xDE/255, blue: 0xD0/255)    // 发丝线
    static let inputBar = Color(red: 0xF3/255, green: 0xEE/255, blue: 0xE2/255)     // 输入栏底
    static let inputField = Color(red: 0xFF/255, green: 0xFD/255, blue: 0xF7/255)   // 输入框底（宣纸）
    static let badgeRed = Color(red: 0xF7/255, green: 0xEE/255, blue: 0xE0/255)     // 警示钤印色改浅：错误气泡底用鸽血红
    /// 气泡上的正文字色（宣纸白，用于墨色气泡内）
    static let onInk = Color(red: 0xF5/255, green: 0xEF/255, blue: 0xE2/255)
    /// 思考区淡墨底
    static let faintInk = Color(red: 0xEC/255, green: 0xE5/255, blue: 0xD6/255)

    // MARK: 尺寸
    static let rowCorner: CGFloat = 6           // 书页小圆角（原微信 8）
    static let rowIcon: CGFloat = 29
    static let navTitle: CGFloat = 19
    /// 栏与栏之间的粗分隔（书口线）
    static let ruleWidth: CGFloat = 1.0

    // MARK: 字体（衬线标题 = 书卷气核心）
    enum MBF {
        /// 衬线标题字体；iOS 自带 Songti SC，缺失时退回系统衬线
        static func serif(_ size: CGFloat) -> Font {
            .custom("Songti SC", size: size)
        }
        static func serifFixed(_ size: CGFloat) -> Font {
            .custom("Songti SC", size: size)
        }
        /// 正文（保持系统无衬线，长文可读性优先）
        static func body(_ size: CGFloat = 17) -> Font {
            .system(size: size)
        }
    }

    // MARK: 视图修饰
    /// 列表单元格：宣纸底、6pt 圆角、左 15+头像+10+标题、右 chevron
    static func rowContent<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) { content(); Spacer(minLength: 0) }
            .padding(.horizontal, 15)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(WX.cellBG)
            .contentShape(Rectangle())
    }

    /// 分组卡片（书页卡）：宣纸卡 + 左右 15 inset + 底 8 分隔 + 细边框
    static var cardPadding: EdgeInsets { EdgeInsets(top: 0, leading: 15, bottom: 8, trailing: 15) }

    static var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(Color(red: 0xC6/255, green: 0xBA/255, blue: 0xA4/255))
    }

    /// 钤印色小圆点（替代红点角标）
    static func sealDot() -> some View {
        Circle().fill(WX.green).frame(width: 8, height: 8)
    }
}

/// 行首小图标（29pt 宣纸底 + 鸽血红线性图标）
struct WXRowIcon: View {
    let name: String
    var size: CGFloat = WX.rowIcon
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7).fill(WX.green.opacity(0.14))
            Image(uiImage: UIImage(named: name)?.withRenderingMode(.alwaysTemplate) ?? UIImage())
            .resizable()
            .renderingMode(.template)
            .foregroundColor(WX.green)
            .padding(size * 0.2)
        }
        .frame(width: size, height: size)
    }
}

/// 分组列表外壳：陈纸底 + 宣纸圆角卡 + 细边框
struct WXGroup<Content: View>: View {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(WX.cellBG)
            .overlay(
                RoundedRectangle(cornerRadius: WX.rowCorner)
                    .stroke(WX.separator, lineWidth: 0.5)
            )
            .cornerRadius(WX.rowCorner)
            .padding(.horizontal, 15)
            .padding(.bottom, 8)
    }
}

/// 札记导航栏：宣纸底、居中衬线标题、底部发丝线、返回按钮
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
                    .font(WX.MBF.serif(WX.navTitle))
                    .foregroundColor(WX.titleBlack)
                Spacer(minLength: 44)
            }
            .frame(height: 44)
            .background(WX.cellBG)
            Rectangle().fill(WX.separator).frame(height: 0.5)
        }
        .background(WX.cellBG.ignoresSafeArea(edges: .top))
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
                Text(title).font(WX.MBF.serif(17)).foregroundColor(WX.titleBlack)
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

/// 札记 tab 自定义图标（PNG 模板着色；找不到资源则 SF Symbol「铅字」兜底）
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
                    Image(systemName: "circle.fill")
                }
            }
            .foregroundColor(selected ? WX.green : WX.secondary)
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(selected ? WX.green : WX.secondary)
        }
    }
}
