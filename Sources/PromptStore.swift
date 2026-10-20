import Foundation

/// 底层提示词仓库：所有系统级提示词都在设置页可改
/// 四类：AI 助手脚设 / 鲸聊聊天前缀 / 网关默认系统 / 工具说明
final class PromptStore {
    static let shared = PromptStore()

    private let D = UserDefaults.standard
    private enum K {
        static let agent    = "jl.prompt.agent"
        static let chat     = "jl.prompt.chat"
        static let gateway  = "jl.prompt.gateway"
        static let tools    = "jl.prompt.tools"
    }

    var agentSystem: String {
        get { D.string(forKey: K.agent) ?? Self.defaultAgent }
        set { D.set(newValue, forKey: K.agent) }
    }
    /// 鲸聊自己聊天时附加在每条消息前的提示词（可空）
    var chatPrefix: String {
        get { D.string(forKey: K.chat) ?? "" }
        set { D.set(newValue, forKey: K.chat) }
    }
    /// 第三方 App 请求没带 system 消息时，网关用它顶上（可空）
    var gatewayDefault: String {
        get { D.string(forKey: K.gateway) ?? "" }
        set { D.set(newValue, forKey: K.gateway) }
    }
    /// AI 助手的工具说明附加段（高级）
    var toolsNote: String {
        get { D.string(forKey: K.tools) ?? "" }
        set { D.set(newValue, forKey: K.tools) }
    }

    static let defaultAgent = """
你是瑶台的 AI 开发助手，运行在一个内置 Linux 风格终端 + 文件系统 + GitHub 能力的 App 里。
你可以通过工具直接操作用户的环境：
- run_command: 在瑶台 shell 执行命令（支持 ls/cat/mkdir/echo/node/grep/sed/git/curl 等，node 用内置 JS 引擎真实执行）
- read_file / write_file / append_file / file_edit: 读写与精确替换沙盒文件（根目录 ~/）
- list_files / search_files: 看目录结构 / 全文搜索
- http_fetch: 抓取网页或 API 内容
- git_clone: 从 GitHub 克隆仓库（公开仓库直接拉；私有仓库需用户在设置页填 PAT）

【行动铁律】
1. 用户下达任务后，第一步永远是调用工具开干（列目录/读文件/搜索/抓取），禁止先反问"你需要什么格式、要改哪里"。
2. 每一步基于上一步的工具结果继续，连续执行直到任务真的完成，再一次性汇报结论。
3. 信息不够就先读文件/搜内容自己拿，不要问用户要原文；拿不到再最小限度确认一次。
4. 长内容分段写：大文件用 append_file 分段追加；局部修改用 file_edit，不要整文件重写。
5. 敢干也能认：工具报错就换思路重试（换路径/换命令/换工具），连续两次失败才回来汇报卡点。
回复用中文，语气自然，行动要快。
"""
}
