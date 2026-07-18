import Foundation

enum L10n {
    static let isChinese = Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true

    static var waiting: String { text("等待 Token", "Waiting for tokens") }
    static var displayFields: String { text("菜单栏显示字段", "Menu bar fields") }
    static var lockTask: String { text("锁定当前任务", "Lock current task") }
    static var lockedTask: String { text("已锁定当前任务", "Current task locked") }
    static var launchAtLogin: String { text("登录时启动", "Launch at login") }
    static var openSessions: String { text("打开会话日志目录", "Open session log folder") }
    static var openProject: String { text("打开项目主页", "Open project page") }
    static var quit: String { text("退出", "Quit") }
    static var noTokenSnapshot: String { text("当前任务尚无 Token 数据", "No token data for the current task") }
    static var ipcConnected: String { text("任务跟随：已连接 Codex", "Task tracking: connected to Codex") }
    static var ipcFallback: String { text("任务跟随：最近会话回退模式", "Task tracking: recent-session fallback") }
    static var currentTask: String { text("当前任务", "Current task") }
    static var launchAtLoginFailed: String { text("无法修改登录启动设置", "Unable to change launch-at-login setting") }
    static var confirmSource: String {
        text("请确认应用位于标准 .app 包内；如果仍失败，可在系统设置的“通用 → 登录项”中管理。",
             "Make sure the app is running from a standard .app bundle. You can also manage it in System Settings under General → Login Items.")
    }

    static func fieldName(_ field: DisplayField) -> String {
        switch field {
        case .total: return text("总 Token", "Total")
        case .input: return text("输入 Token", "Input")
        case .output: return text("输出 Token", "Output")
        case .cacheHit: return text("缓存命中", "Cache hit")
        case .cacheMiss: return text("缓存未命中", "Cache miss")
        case .context: return text("上下文", "Context")
        case .contextPercent: return text("上下文百分比", "Context percent")
        case .reasoning: return text("推理输出", "Reasoning")
        case .thread: return text("任务 ID", "Task ID")
        default: return text("未知", "Unknown")
        }
    }

    static func fieldValue(_ field: DisplayField, _ value: String) -> String {
        let prefix: String
        switch field {
        case .total: prefix = text("总", "Total")
        case .input: prefix = text("入", "In")
        case .output: prefix = text("出", "Out")
        case .cacheHit: prefix = text("命中", "Hit")
        case .cacheMiss: prefix = text("未命中", "Miss")
        case .context: prefix = text("上下文", "Ctx")
        case .reasoning: prefix = text("推理", "Reason")
        case .thread: prefix = text("任务", "Task")
        default: prefix = ""
        }
        return prefix.isEmpty ? value : "\(prefix) \(value)"
    }

    static func text(_ chinese: String, _ english: String) -> String {
        isChinese ? chinese : english
    }
}
