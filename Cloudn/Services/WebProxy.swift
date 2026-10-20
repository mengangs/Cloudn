// Cloudn · SPDX-License-Identifier: AGPL-3.0-or-later
import CloudnKit
import Network
import WebKit

extension WKWebsiteDataStore {
    /// 内嵌网页也走应用内代理（设置页「网络代理」）；没设置时跟随系统
    @MainActor
    func useAppProxy() {
        proxyConfigurations = NetworkProxy.current?.proxyConfiguration.map { [$0] } ?? []
    }
}
