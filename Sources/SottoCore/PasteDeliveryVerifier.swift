public enum PasteDeliveryVerifier {
    public static func didInsert(
        text: String,
        valueBefore: String?,
        valueAfter: String?
    ) -> Bool {
        guard let valueBefore, let valueAfter, valueBefore != valueAfter else {
            return false
        }
        return valueAfter.contains(text)
    }
}
