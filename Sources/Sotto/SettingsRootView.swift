import AppKit
import SwiftUI
import SottoCore

private enum SettingsPane: String, CaseIterable, Identifiable {
    case start = "开始"
    case speech = "语音"
    case providers = "百炼"
    case privacy = "隐私"
    case about = "关于"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .start: "sparkles"
        case .speech: "waveform"
        case .providers: "server.rack"
        case .privacy: "hand.raised"
        case .about: "info.circle"
        }
    }
}

struct SettingsRootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var permissions: PermissionCenter
    @State private var selection: SettingsPane? = .start

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.rawValue, systemImage: pane.symbol)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 152, ideal: 172, max: 190)
        } detail: {
            Group {
                switch selection ?? .start {
                case .start: StartSettingsView()
                case .speech: SpeechSettingsView()
                case .providers: ProviderSettingsView()
                case .privacy: PrivacySettingsView()
                case .about: AboutSettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 760, height: 560)
        .task {
            permissions.refresh()
        }
    }
}

private struct StartSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var permissions: PermissionCenter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speak. Keep typing.")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("单击 fn 开始，自然说话，再次单击 fn，把整理后的文字写回原输入框。")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(spacing: 0) {
                    PermissionRow(
                        kind: .microphone,
                        title: "麦克风",
                        detail: "只在你主动开始听写时使用",
                        state: permissions.microphone
                    )
                    Divider().padding(.leading, 44)
                    PermissionRow(
                        kind: .accessibility,
                        title: "辅助功能",
                        detail: "写回原输入框，并识别独立的 fn 按键",
                        state: permissions.accessibility
                    )
                }
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前语音服务")
                            .font(.headline)
                        Text(settings.provider.title)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: model.canStart ? "checkmark.circle.fill" : "key.horizontal")
                        .foregroundStyle(model.canStart ? Color.green : Color.orange)
                    Text(model.canStart ? "已配置" : "需要完整服务配置")
                        .foregroundStyle(.secondary)
                }

                Button("完成设置") {
                    settings.onboardingComplete = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    permissions.microphone != .granted
                        || permissions.accessibility != .granted
                        || !model.canStart
                )
            }
            .padding(32)
        }
    }
}

private struct PermissionRow: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var permissions: PermissionCenter

    let kind: AppPermissionKind
    let title: String
    let detail: String
    let state: PermissionCenter.State

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(state == .granted ? Color.green : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(effectiveDetail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state == .granted {
                Text("已允许")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if permissions.isRequesting(kind) {
                ProgressView()
                    .controlSize(.small)
                Text("等待授权")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if permissions.action(for: kind) == .unavailable {
                Text(state.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button(actionTitle) {
                    Task {
                        let result = await permissions.perform(kind)
                        if result == .completedInApp {
                            model.restoreSettingsAfterPermissionPrompt()
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    private var actionTitle: String {
        switch permissions.action(for: kind) {
        case .request: "允许"
        case .openSystemSettings: "打开设置"
        case .none: "已允许"
        case .unavailable: state.title
        }
    }

    private var effectiveDetail: String {
        switch state {
        case .restricted:
            "这项权限被系统策略或设备管理限制"
        case .misconfigured:
            "请运行打包并签名后的 Sotto.app"
        default:
            detail
        }
    }
}

private struct SpeechSettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section("识别") {
                Picker("语言", selection: $settings.languageRawValue) {
                    Text("自动识别").tag(ASRLanguage.automatic.rawValue)
                    Text("中文").tag(ASRLanguage.chinese.rawValue)
                    Text("English").tag(ASRLanguage.english.rawValue)
                }
                LabeledContent("快捷键") {
                    Text("单击 fn 开始／结束")
                        .foregroundStyle(.secondary)
                }
            }

            Section("fn 与 macOS") {
                Text("如果 macOS 把 fn／🌐 设为“显示表情与符号”，一次按键会同时触发两个动作。请在键盘设置里将“按下 fn／🌐 键时”改为“无操作”。")
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开键盘设置") {
                    NSWorkspace.shared.open(SystemSettingsLink.keyboard)
                }
            }

            Section("写作") {
                Toggle("自动整理口述内容", isOn: $settings.cleanupEnabled)
                Text("默认开启。删除口头语和重复、执行明确改口、补标点；没有明确改口依据的数字、邮箱和链接变化会自动回退原文。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("语音")
    }
}

private struct ProviderSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var settings: SettingsStore
    @State private var speechKey = ""

    var body: some View {
        Form {
            Section("百炼模型") {
                LabeledContent("语音识别") {
                    Text("Fun-ASR Realtime")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("文字整理") {
                    Text("Qwen3.5 Flash")
                        .foregroundStyle(.secondary)
                }
                Picker("区域", selection: $settings.funRegion) {
                    ForEach(FunRegion.allCases) { region in
                        Text(region.title).tag(region)
                    }
                }
                TextField("Workspace ID", text: $settings.funWorkspaceID)
                Text("填写百炼工作空间 ID。语音识别和文字整理会自动使用同一 Workspace、区域和 API Key。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !settings.funWorkspaceID.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty {
                    if let workspaceID = BailianWorkspaceInput.normalizedID(
                        from: settings.funWorkspaceID
                    ) {
                        Label("已识别 Workspace：\(workspaceID)", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("无法识别这个 Workspace ID", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                SecureField("百炼 API Key", text: $speechKey)
                HStack {
                    connectionLabel
                    Spacer()
                    Button {
                        model.testSpeechConnection()
                    } label: {
                        if model.connectionTestState == .testing {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("测试中")
                            }
                        } else {
                            Text("测试两个模型")
                        }
                    }
                    .accessibilityIdentifier("fun-asr-connection-test")
                    .disabled(!canTestFunASRConnection)
                    Button("保存 API Key") {
                        Task {
                            let saved = await model.saveCredential(speechKey, for: .funASR)
                            if saved {
                                speechKey = ""
                            }
                        }
                    }
                    .disabled(speechKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                connectionTestStatus

                if let credentialSaveError = model.credentialSaveError {
                    Label("API Key 保存失败：\(credentialSaveError)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }

                if let lastServiceError = model.lastServiceError {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("最近一次听写错误")
                            .font(.caption.weight(.semibold))
                        Text(lastServiceError)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if !settings.cleanupEnabled {
                    Label("文字整理已在“语音”设置中关闭", systemImage: "pause.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("百炼")
        .onChange(of: settings.funRegion) { _ in
            model.invalidateConnectionTest()
        }
        .onChange(of: settings.funWorkspaceID) { _ in
            model.invalidateConnectionTest()
        }
        .onChange(of: speechKey) { newValue in
            if !newValue.isEmpty {
                model.invalidateConnectionTest()
            }
        }
    }

    private var providerConnected: Bool {
        model.funKeyConfigured
    }

    private var connectionLabel: some View {
        Label(
            providerConnected ? "Key 已安全保存" : "尚未配置",
            systemImage: providerConnected ? "checkmark.circle.fill" : "circle"
        )
        .foregroundStyle(.secondary)
    }

    private var canTestFunASRConnection: Bool {
        model.funKeyConfigured
            && model.phase == .idle
            && model.connectionTestState != .testing
            && speechKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && BailianWorkspaceInput.normalizedID(from: settings.funWorkspaceID) != nil
    }

    @ViewBuilder
    private var connectionTestStatus: some View {
        switch model.connectionTestState {
        case .idle:
            Text("测试会真实连接 Fun-ASR，并让 Qwen 整理“6 点改 8 点”的样例；不会启用麦克风。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("fun-asr-connection-test-status")
        case .testing:
            Label("正在验证 Fun-ASR 和 Qwen3.5 Flash…", systemImage: "network")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("fun-asr-connection-test-status")
        case .succeeded:
            Label("两个模型均连接成功 · 改口整理验证通过", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.green)
                .accessibilityIdentifier("fun-asr-connection-test-status")
        case let .failed(userMessage, diagnostic):
            VStack(alignment: .leading, spacing: 4) {
                Label(userMessage, systemImage: "xmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                Text(diagnostic)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("fun-asr-connection-test-status")
        }
    }
}

private struct PrivacySettingsView: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section("本机") {
                LabeledContent("转写历史", value: "不保存")
                LabeledContent("原始音频", value: "请求完成后释放")
                LabeledContent("API Key", value: "macOS Keychain")
            }
            Section("当前数据路径") {
                Text(providerDisclosure)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Sotto 不会把完整口述写入诊断日志。第三方服务商的数据处理仍受各自条款约束。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("隐私")
    }

    private var providerDisclosure: String {
        settings.cleanupEnabled
            ? "音频会实时发送到阿里云 Fun-ASR Realtime；转写文字随后发送到同一百炼 Workspace 的 Qwen3.5 Flash 做保守整理。"
            : "音频会实时发送到阿里云 Fun-ASR Realtime；文字整理当前已关闭。"
    }
}

private struct AboutSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .frame(width: 72, height: 72)
            Text("Sotto")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("A focused native voice-to-text tool for macOS.")
                .foregroundStyle(.secondary)
            Text("首版只做听写、保守整理和可靠写回。")
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
