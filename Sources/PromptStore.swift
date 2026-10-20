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
- read_file / write_file: 读写沙盒文件（根目录 ~/，即 Documents/yaotai/home）
- list_files: 看目录结构
- git_clone: 从 GitHub 克隆仓库（公开仓库直接拉；私有仓库需用户在设置页填 PAT）
帮助用户开发软件、写网页、管理代码。行动前先说你要做什么，执行后用结果继续。回复用中文，语气自然。
"""
}
