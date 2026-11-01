import Dependencies
import Foundation
import os
import StoreKit
import UIKit

extension StoreTransport {
    static func live() -> Self {
        let cachedProduct = LockIsolated<Product?>(nil)

        @Sendable func product() async throws -> Product {
            if let product = cachedProduct.value {
                return product
            }
            let products = try await Product.products(for: [FullVersion.productID])
            guard let product = products.first(where: { $0.id == FullVersion.productID && $0.type == .nonConsumable }) else {
                throw PurchaseClientError.productNotFound
            }
            cachedProduct.setValue(product)
            return product
        }

        return Self(
            offer: {
                FullVersionOffer(displayPrice: try await product().displayPrice)
            },
            purchase: {
                try await purchase(try await product())
            },
            sync: {
                do {
                    try await AppStore.sync()
                    return true
                } catch StoreKitError.userCancelled {
                    return false
                }
            },
            isEntitled: {
                // `currentEntitlements(for:)` needs iOS 18.4, and `currentEntitlement(for:)` is deprecated there.
                var isEntitled = false
                for await result in Transaction.currentEntitlements {
                    switch result {
                        case let .verified(transaction):
                            // Bought or shared through Family Sharing; a refund or revocation sets the date.
                            if transaction.productID == FullVersion.productID, transaction.revocationDate == nil {
                                isEntitled = true
                            }
                        case let .unverified(transaction, error):
                            Logger.purchases.error("Ignoring an unverified entitlement \(transaction.productID, privacy: .public): \(String(reflecting: error), privacy: .public)")
                    }
                }
                return isEntitled
            },
            listen: { handle in
                for await result in Transaction.updates {
                    switch result {
                        case let .verified(transaction):
                            await transaction.finish()
                        case let .unverified(transaction, error):
                            Logger.purchases.error("Ignoring an unverified transaction update \(transaction.productID, privacy: .public): \(String(reflecting: error), privacy: .public)")
                    }
                    await handle()
                }
            }
        )
    }

    @MainActor
    private static func purchase(_ product: Product) async throws -> PurchaseOutcome {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let scene else {
            throw PurchaseClientError.noActiveScene
        }

        let result: Product.PurchaseResult
        do {
            // The view-controller variant needs iOS 18.2; this one is there from iOS 17.
            result = try await product.purchase(confirmIn: scene)
        } catch StoreKitError.userCancelled {
            return .cancelled
        } catch Product.PurchaseError.purchaseNotAllowed {
            throw PurchaseClientError.notAllowed
        }

        switch result {
            case let .success(.verified(transaction)):
                await transaction.finish()
                return .purchased
            case let .success(.unverified(transaction, error)):
                Logger.purchases.error("The purchase of \(transaction.productID, privacy: .public) is unverified: \(String(reflecting: error), privacy: .public)")
                throw PurchaseClientError.unverified
            case .pending:
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                throw PurchaseClientError.unknownResult
        }
    }
}
