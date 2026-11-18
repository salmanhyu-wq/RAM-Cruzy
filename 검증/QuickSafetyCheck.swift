import Foundation

@main enum QuickSafetyCheck {
    static func main() async throws {
        let idlePort = Int(CommandLine.arguments[1])!
        let busyPort = Int(CommandLine.arguments[2])!
        let providers = Providers()
        let key = "port." + Provider.mlxServe.rawValue
        let old = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(old, forKey: key) }

        UserDefaults.standard.set(idlePort, forKey: key)
        let idle = Control.release(.mlxServe, "fixture-model", idlePort)
        do {
            _ = try await providers.perform(idle, bulk: true, maySubmit: { false })
            fatalError("자동을 끈 뒤에도 회수 요청")
        } catch LocalError.changed {}

        UserDefaults.standard.set(busyPort, forKey: key)
        do {
            _ = try await providers.perform(.release(.mlxServe, "fixture-model", busyPort), bulk: true)
            fatalError("작업 중인데 자동 회수 요청")
        } catch LocalError.changed {}

        UserDefaults.standard.set(idlePort, forKey: key)
        let result = try await providers.perform(idle, bulk: true)
        precondition(result == "모델을 내렸어요.")
        print("요청 직전 자동 끔, 작업 중 대상 제외, 유휴 모델 회수 및 상태 갱신 검증 통과")
    }
}
