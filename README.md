# Sotto

Sotto 是一个专注于 macOS 的原生语音输入 App：单击 `fn` 开始说话，再次单击 `fn`，把识别并整理后的文本写回原来的输入框。

当前 Apple Silicon 测试版可从 [GitHub Releases](https://github.com/Howell5/sotto/releases/tag/v0.2.0) 下载。

首版只保留这条核心闭环：

- 标准 Dock App，同时在菜单栏常驻
- `fn` toggle 开始／结束听写，`Esc` 取消
- 阿里百炼 Fun-ASR Realtime 实时识别
- 同一 Workspace 与 API Key 调用 Qwen3.5 Flash 做保守整理
- 优先写回原输入框；无法安全写入时保留到剪贴板
- API Key 存在 macOS Keychain，不保存录音和转写历史

翻译、聊天、云端历史和模板系统不在当前范围内。

## 安装 GitHub 预览版

当前发布包面向 Apple Silicon，支持 macOS 13 及以上版本。项目目前选择零成本分发，因此 GitHub 预览版使用 ad-hoc 签名，未经过 Apple Developer ID 签名和公证。

1. 只从 [Sotto GitHub Release](https://github.com/Howell5/sotto/releases/tag/v0.2.0) 下载 DMG；同页的 `SHA256SUMS.txt` 可用于校验文件。
2. 打开 DMG，把 Sotto 拖入 **Applications**。
3. 首次打开如果被 macOS 阻止，先尝试右键 Sotto 并选择 **打开**。
4. 如果仍被阻止，先触发一次打开，再进入“系统设置 → 隐私与安全性”，只对 Sotto 点击 **仍要打开**，验证本机密码后确认打开。
5. 按下文开启麦克风和辅助功能权限，并配置自己的百炼 Workspace ID 与 API Key。

不要全局关闭 Gatekeeper，也不要运行来源不明的“解除签名限制”命令。公司或学校管理的 Mac 可能禁止“仍要打开”，这种设备需要管理员允许。

API Key 保存在 macOS Keychain。首次保存或首次运行一个新发布包时，系统可能询问 Sotto 是否可访问对应项目；仅当安装包来自上述官方仓库时选择 **始终允许**。由于公开预览包没有稳定的 Developer ID，升级后 macOS 仍有可能再次询问。

## 系统要求

- macOS 13 Ventura 或更高版本
- Swift 6.0 或更高版本的命令行工具链
- 麦克风和辅助功能权限
- 百炼 Workspace ID 和对应区域的 API Key

项目是纯 Swift Package，不包含也不依赖 `.xcodeproj`。构建和打包都通过 `swift build` 完成，不需要打开 Xcode。`package-app.sh` 默认只构建当前 Mac 架构；需要同时分发 Apple Silicon 和 Intel 时，应分别构建后再合并或分别发布。

## 构建与运行

编译源码：

```bash
swift build
```

不要直接运行 `swift run Sotto` 或 `.build/.../Sotto`。裸 SwiftPM 可执行文件没有应用的 `Info.plist` 和音频输入 entitlement；macOS 在它请求麦克风时可能直接终止进程。需要运行应用时，始终先执行下面的打包脚本，再打开生成的 `.app`。

运行核心测试工具：

```bash
swift run SottoCoreTestHarness
```

打包 release 应用：

```bash
./scripts/package-app.sh
open outputs/Sotto.app
```

脚本会：

1. 执行 `swift build -c release --product Sotto`；
2. 生成 `outputs/Sotto.app`；
3. 复制 `Info.plist`；
4. 使用 `Packaging/Sotto.entitlements` 做 hardened runtime 的 ad-hoc 签名；
5. 验证 app bundle 和签名。

默认签名身份是 `-`。将来有 Developer ID 时，可以指定证书：

```bash
SOTTO_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
  ./scripts/package-app.sh
```

这只会签名，不会自动提交 notarization。

### 本地开发：固定签名，避免反复弹 Keychain

`package-app.sh` 默认使用 ad-hoc 签名，每次重新编译后代码哈希都会改变。Keychain 因此可能把新构建视为另一个 App，并重新询问是否允许读取 API Key。这是 macOS 的安全校验，不是 API 服务的问题。

本机开发可以免费创建一个只供自己使用的稳定代码签名证书：

1. 打开“钥匙串访问”；
2. 选择“钥匙串访问 → 证书助理 → 创建证书”；
3. 名称填写 `Sotto Local Development`；
4. “身份类型”选择 **自签名根证书**，“证书类型”选择 **代码签名**；
5. 勾选“让我覆盖默认设置”，其余项目保留默认值并完成创建。

确认签名身份存在：

```bash
security find-identity -v -p codesigning
```

之后开发时使用：

```bash
./scripts/package-dev-app.sh
open outputs/Sotto.app
```

脚本会固定使用 `Sotto Local Development`，并为本机自签名禁用无意义的在线时间戳请求。第一次让 `/usr/bin/codesign` 使用证书私钥时，Keychain 仍可能询问一次；确认是系统的 `codesign` 后选择 **始终允许**。从旧 ad-hoc 构建切换过来时，Sotto 读取现有 API Key 也可能再询问一次；固定签名后的后续重建不应继续反复弹窗。

这个自签名证书只解决本机开发身份稳定性，不能替代 Apple 公证，也不要用它制作给朋友下载的发布包。若证书使用其他名称，可以这样指定：

```bash
SOTTO_DEVELOPMENT_CODESIGN_IDENTITY="Your Local Code Signing" \
  ./scripts/package-dev-app.sh
```

## 首次设置与权限

首次启动会打开设置窗口。请完成两项权限：

1. **麦克风**：只在用户主动开始听写后采集语音。
2. **辅助功能**：读取原输入焦点、写回识别结果，并在其他应用处于前台时识别独立的 `fn` 按键。

如果系统权限面板已经打开但 Sotto 仍显示未允许：

1. 在“系统设置 → 隐私与安全性”确认 Sotto 已启用；
2. 完全退出并重新打开 Sotto；
3. ad-hoc 版本重建后如果签名身份发生变化，可能需要移除旧条目再重新授权。

Sotto 不会自动写入密码等安全输入框。输入焦点已经变化或目标不支持安全写入时，结果会复制到剪贴板。

## 配置语音服务

从 Dock、Spotlight、Launchpad 或菜单栏打开 Sotto，然后进入 **百炼**。

Fun-ASR 在录音时持续发送 PCM 音频并接收实时结果；Qwen3.5 Flash 在转写完成后处理口头语、重复和明确改口。两次调用共用一套百炼配置。

1. 选择与阿里云 Model Studio 账号一致的区域：
   - 中国大陆（北京）
   - 国际（新加坡）
2. 填写百炼 **Workspace ID**；
3. 填入对应区域的 API Key；
4. 点击 **保存 API Key**；
5. 点击 **测试两个模型**，同时验证 Fun-ASR 和“6 点改 8 点”的整理流程。

不同区域的 API Key 和 endpoint 不能混用。如果返回未授权错误，先检查区域，再检查 Key。

整理默认开启，可在 **语音 → 自动整理口述内容** 中关闭。API Key 保存在 macOS Keychain；Workspace ID 和区域等非机密设置保存在 UserDefaults。

## 使用 Fn toggle

1. 把光标留在目标输入框中；
2. 单击一次 `fn`，底部胶囊出现 **Listening…**；
3. 自然说话；
4. 再单击一次 `fn`，进入 **Writing…**；
5. 完成后文本写回原输入框，并短暂显示 **Inserted**。

听写时按 `Esc` 会取消本次录音。Sotto 对 `fn` 有约 120ms 的防误触判断；`fn` 与 F 功能键、方向键或其他组合键一起使用时不会触发听写。也可以从菜单栏选择 **Start Listening / Stop Listening**。

如果单击 `fn` 完全没有反应，优先检查辅助功能权限，并确认 macOS 没有把单独的 `fn` 配置为系统听写、输入法切换或表情面板。

如果按 `fn` 时同时打开表情面板，请进入“系统设置 → 键盘”，把“按下 fn／🌐 键时”改为“无操作”。macOS 的系统动作和 Sotto 的全局快捷键是两个独立监听，必须先清除这一快捷键冲突。

## 数据与隐私

- 音频发送到所选区域的阿里云 Fun-ASR Realtime。
- 启用整理时，转写文本会发送到同一百炼 Workspace 的 Qwen3.5 Flash。
- Sotto 当前不保存录音或转写历史，也不会把完整口述写入诊断日志。
- 第三方服务的数据保留与训练政策由各自条款决定。

## 分发状态

打开 `outputs/Sotto-0.2.0-macOS-arm64.dmg`，将 Sotto 拖入 **Applications**。之后可以从 Dock、Spotlight、Launchpad、Finder 或菜单栏打开；再次点击 Dock 图标会恢复设置窗口。

当前项目选择零成本预览分发，产物默认使用 ad-hoc 签名，**尚未 notarize**。它可以分享给朋友测试，但 Gatekeeper 会提示未验证的开发者；版本更新后，麦克风、辅助功能或 Keychain 授权也可能需要重新确认。

本机直接构建通常可以正常打开。如果 app 经浏览器或聊天工具下载，Gatekeeper 可能阻止首次启动。请先尝试右键 app 选择 **打开**；如仍被阻止，到“系统设置 → 隐私与安全性”对这一个 app 选择 **仍要打开**。不要全局关闭 Gatekeeper。

如果将来需要让普通用户双击即开、并让跨版本身份稳定，仍需 Apple Developer Program 账号，并完成：

- Developer ID Application 签名
- Hardened Runtime
- Apple notarization 和 stapling
- 在干净 Mac 上验证首次权限流程及更新后的权限保留

完整版依赖 Accessibility 读取并写回其他 App 的输入框，而 Mac App Store 强制启用 App Sandbox；因此当前推荐渠道是 Developer ID 签名并公证的独立 DMG，而不是 Mac App Store。若将来一定要上架，需要另做只复制到剪贴板的沙盒版。

## 常见问题

**菜单栏没有出现 Sotto**

从 Dock 或 Spotlight 再次打开 Sotto；正常情况下会恢复设置窗口，同时菜单栏图标也会重新出现。若两处都没有，请通过活动监视器确认进程是否仍在运行。

**识别成功但没有自动写入**

检查辅助功能权限和原输入焦点。安全输入框、焦点已经变化或不支持辅助功能写入的控件会改为复制到剪贴板。

**Fun-ASR 返回未授权**

确认账号区域、设置中的区域和 API Key 属于同一个 Model Studio endpoint。

**重建后权限失效**

ad-hoc 签名随可执行文件变化，macOS 可能把重建产物视为新的授权对象。本机开发请按“本地开发：固定签名”创建一次自签名证书，并改用 `./scripts/package-dev-app.sh`；公开预览版只有使用 Developer ID 才能从根本上稳定跨机器、跨版本身份。

**为什么 Keychain 每次都询问是否允许读取 API Key**

旧开发包的身份是随构建变化的 ad-hoc 代码哈希，而 Keychain 会按代码签名身份保护凭据。当前代码已把 API Key 收敛为启动时读取一次、进程内复用；再配合本机固定签名，正常情况下只会在首次建立信任或从旧签名迁移时确认一次。不要为了消除弹窗而允许所有 App 访问该项目。
