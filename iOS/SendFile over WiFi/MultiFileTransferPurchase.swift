import Foundation
import StoreKit
import Combine

/// App Store entitlement for the iOS-only multi-file transfer capability.
@MainActor
final class MultiFileTransferPurchase: ObservableObject {
    static let productID = "com.ao.sendfileoverwifi.multifiletransfer"

    @Published private(set) var product: Product?
    @Published private(set) var isUnlocked = false
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?

    init() {
        Task { await refresh() }
    }

    func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            product = try await Product.products(for: [Self.productID]).first
            await refreshEntitlement()
            message = product == nil ? AppLocalization.text("purchaseUnavailable") : nil
        } catch {
            message = AppLocalization.text("purchaseLoadFailed")
        }
    }

    func purchase() async {
        if product == nil { await refresh() }
        guard let product else { return }

        isLoading = true
        defer { isLoading = false }
        do {
            switch try await product.purchase() {
            case .success(let verification):
                let transaction = try verified(verification)
                await transaction.finish()
                await refreshEntitlement()
                message = isUnlocked ? nil : AppLocalization.text("purchaseNotConfirmed")
            case .pending:
                message = AppLocalization.text("purchasePending")
            case .userCancelled:
                message = nil
            @unknown default:
                message = AppLocalization.text("purchaseFinishFailed")
            }
        } catch {
            message = AppLocalization.text("purchaseFailed")
        }
    }

    func restore() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await AppStore.sync()
            await refreshEntitlement()
            message = isUnlocked ? nil : AppLocalization.text("noPurchases")
        } catch {
            message = AppLocalization.text("restoreFailed")
        }
    }

    private func refreshEntitlement() async {
        isUnlocked = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? verified(result),
                  transaction.productID == Self.productID,
                  transaction.revocationDate == nil else { continue }
            isUnlocked = true
            return
        }
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): value
        case .unverified: throw PurchaseVerificationError.failed
        }
    }

    private enum PurchaseVerificationError: Error { case failed }
}
