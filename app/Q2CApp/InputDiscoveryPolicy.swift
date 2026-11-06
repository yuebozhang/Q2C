import ApplicationServices

/// Missing optional children on known leaf roles cannot hide a second editor.
/// Containers and actual AX failures must leave the scan unconfirmed.
enum InputDiscoveryPolicy {
    static func canTreatAsLeaf(role: String, error: Int32) -> Bool {
        guard error == AXError.attributeUnsupported.rawValue || error == AXError.noValue.rawValue else { return false }
        return [kAXButtonRole, kAXStaticTextRole, kAXImageRole, kAXTextAreaRole,
                kAXCheckBoxRole, kAXRadioButtonRole, kAXMenuItemRole, kAXMenuBarItemRole,
                kAXSplitterRole, "AXHeading", "AXLink"].contains(role)
    }
}
