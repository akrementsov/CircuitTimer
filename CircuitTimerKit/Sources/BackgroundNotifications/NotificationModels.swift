import Foundation

public struct NotificationAccess: Equatable, Sendable {
    public enum Authorization: Equatable, Sendable {
        case notDetermined
        case denied
        case authorized
        case provisional
        case ephemeral
    }

    public var authorization: Authorization
    public var showsAlerts: Bool
    public var playsSound: Bool

    public init(authorization: Authorization, showsAlerts: Bool, playsSound: Bool) {
        self.authorization = authorization
        self.showsAlerts = showsAlerts
        self.playsSound = playsSound
    }

    public var isDetermined: Bool { authorization != .notDetermined }
    public var canDeliver: Bool {
        showsAlerts && (authorization == .authorized || authorization == .provisional || authorization == .ephemeral)
    }

    public static let authorized = Self(authorization: .authorized, showsAlerts: true, playsSound: true)
}

public struct ScheduledNotification: Equatable, Sendable {
    public var key: String
    public var fireDate: Date
    public var title: String
    public var body: String
    public var isAudible: Bool

    public init(key: String, fireDate: Date, title: String, body: String, isAudible: Bool) {
        self.key = key
        self.fireDate = fireDate
        self.title = title
        self.body = body
        self.isAudible = isAudible
    }

    func matches(_ other: Self) -> Bool {
        key == other.key && abs(fireDate.timeIntervalSince(other.fireDate)) <= 0.001
            && title == other.title && body == other.body && isAudible == other.isAudible
    }
}

public struct NotificationSyncReport: Equatable, Sendable {
    public var superseded: Bool
    public var canDeliver: Bool
    public var access: NotificationAccess?
    public var confirmedFuture: Int
    public var expired: Int
    public var failed: Int
    public var missing: Int
    public var imminentUnconfirmed: Int
    public var isVerified: Bool

    public init(
        superseded: Bool = false,
        canDeliver: Bool = true,
        confirmedFuture: Int = 0,
        expired: Int = 0,
        failed: Int = 0,
        missing: Int = 0,
        imminentUnconfirmed: Int = 0,
        isVerified: Bool = true,
        access: NotificationAccess? = nil
    ) {
        self.superseded = superseded
        self.canDeliver = access?.canDeliver ?? canDeliver
        self.access = access
        self.confirmedFuture = confirmedFuture
        self.expired = expired
        self.failed = failed
        self.missing = missing
        self.imminentUnconfirmed = imminentUnconfirmed
        self.isVerified = isVerified
    }

    public var isClean: Bool {
        !superseded && canDeliver && failed == 0 && missing == 0 && imminentUnconfirmed == 0 && isVerified
    }
}

enum NotificationFailure: Error, Equatable, LocalizedError {
    case timedOut
    case system(String)

    var errorDescription: String? {
        switch self {
            case .timedOut: "iOS did not answer the notification request in time."
            case let .system(message): message
        }
    }
}
