import Foundation
import HiveCore
import Testing
@testable import HiveKit

/// Arreglos que aparecieron al juntar los paquetes.
@Suite("Integración")
struct IntegracionTests {
    @Test("Los commits recientes se vuelven a leer cuando cambia HEAD, aunque no haya upstream")
    func recentCommitsRefreshKeyUsesHeadOid() {
        var status = GitStatus(branch: "main", headOid: "aaa111")
        let before = RecentCommits.refreshKey(status)
        status.headOid = "bbb222"
        #expect(RecentCommits.refreshKey(status) != before)
        // Sin oid (repo sin commits) se sigue usando la clave anterior.
        status.headOid = nil
        #expect(RecentCommits.refreshKey(status) == "main|0|0|0")
        #expect(RecentCommits.refreshKey(nil) == "-")
    }
}
