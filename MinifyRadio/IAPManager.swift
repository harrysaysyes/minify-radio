import StoreKit

@MainActor
class IAPManager: ObservableObject {

    // Product IDs — must match App Store Connect configuration
    static let productIDs = [
        "app.minify.support.1",
        "app.minify.support.3",
        "app.minify.support.5",
        "app.minify.support.10",
        "app.minify.support.25",
        "app.minify.support.50",
        "app.minify.support.100",
    ]

    @Published var products:     [Product] = []
    @Published var isPurchasing  = false
    @Published var thankYouShown = false

    func loadProducts() async {
        do {
            let loaded = try await Product.products(for: IAPManager.productIDs)
            products = loaded.sorted { $0.price < $1.price }
        } catch {
            print("IAPManager: product load failed: \(error)")
        }
    }

    func purchase(_ product: Product) async {
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                thankYouShown = true
            case .userCancelled, .pending:
                break
            @unknown default:
                break
            }
        } catch {
            print("IAPManager: purchase failed: \(error)")
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw StoreError.failedVerification
        case .verified(let value):
            return value
        }
    }

    enum StoreError: Error {
        case failedVerification
    }
}
