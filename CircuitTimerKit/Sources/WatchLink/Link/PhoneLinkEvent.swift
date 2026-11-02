/// What the watch hears from the iPhone, apart from the answers to its own requests. A context and a message stay
/// apart: CT-9-3 lets only a message or a reply confirm a running clock.
public enum PhoneLinkEvent: Equatable, Sendable {
    case status(LinkStatus)
    case context(PhoneState)
    case message(PhoneState)
    /// A context or a message the watch cannot read; `nil` when it is not one of our envelopes at all.
    case undecodable(peerSchemaVersion: Int?)
}
