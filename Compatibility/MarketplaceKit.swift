// Build as module MarketplaceKit with library evolution so compiled clients can
// use the public AppDistributor ABI on hosts where Apple omits the framework.
public enum AppDistributor {
    case appStore
    case testFlight
    case marketplace(String)
    case web
    case other

    public static var current: AppDistributor {
        get async throws { .other }
    }
}
