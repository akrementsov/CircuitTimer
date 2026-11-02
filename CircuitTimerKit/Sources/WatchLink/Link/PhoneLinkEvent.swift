/// What the watch hears from the iPhone, apart from the answers to its own requests. A context and a message stay
/// apart for the order rules. Only a reply confirms a running clock; a context or a message accepted after it carries
/// a confirmed clock on to the same run's newer content, but never opens or extends the confirmation.
public enum PhoneLinkEvent: Equatable, Sendable {
    case status(LinkStatus)
    case context(PhoneState)
    case message(PhoneState)
    /// A context or a message the watch cannot read; `nil` when it is not one of our envelopes at all.
    case undecodable(peerSchemaVersion: Int?)
}
