public enum ClipboardRecoveryCopy {
    public static let pasteShortcut = "⌘V"

    public static func message(reason: String) -> String {
        "\(reason)，已复制，请按 \(pasteShortcut) 粘贴"
    }

    public static let uncertainDeliveryMessage =
        "已复制；若未写入，请按 \(pasteShortcut) 粘贴"
}
