import Foundation
import SQLite3

@main enum ConversationCheck {
    static func main() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("airam-title-" + UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let profile = home.appendingPathComponent("profiles/bot-one")
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        let dbFile = profile.appendingPathComponent("state.db")
        var db: OpaquePointer?
        precondition(sqlite3_open(dbFile.path, &db) == SQLITE_OK)
        let sql = """
            CREATE TABLE sessions (id TEXT PRIMARY KEY, parent_session_id TEXT, title TEXT, profile_name TEXT, end_reason TEXT);
            INSERT INTO sessions VALUES
              ('origin', NULL, ' 긴 대화방   제목 시작 부분 👩🏽‍💻 이어서 가나다라마바사아자차카타파하 길이가 긴 한글 테스트 잘라야 합니다 ', 'bot-one', 'compression'),
              ('child', 'origin', NULL, 'bot-one', NULL),
              ('manual', 'origin', '파일 정리 요청', 'bot-one', NULL),
              ('branch', 'manual', NULL, 'bot-one', NULL),
              ('wrong-owner', NULL, '다른 프로필', 'somebody-else', NULL),
              ('canonical', NULL, 'Bot Chat', 'bot-one', NULL),
              ('empty', NULL, '  ', NULL, NULL);
        """
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        try "display_name: 예전 이름\nui_meta:\n  hermes-bots:\n    title: 화면의 봇 이름\n".write(to: profile.appendingPathComponent("profile.yaml"), atomically: true, encoding: .utf8)
        precondition(HermesConversation.profileName("bot-one", home: home) == "화면의 봇 이름")
        let office = home.appendingPathComponent("office-runtime/profiles/bot-one")
        try fm.createDirectory(at: office, withIntermediateDirectories: true)
        var officeDB: OpaquePointer?
        precondition(sqlite3_open(office.appendingPathComponent("state.db").path, &officeDB) == SQLITE_OK)
        precondition(sqlite3_exec(officeDB, "CREATE TABLE sessions (id TEXT PRIMARY KEY, parent_session_id TEXT, title TEXT, profile_name TEXT, end_reason TEXT); INSERT INTO sessions VALUES ('manual',NULL,'회사 봇의 별도 대화방','custom',NULL);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(officeDB)
        precondition(HermesConversation.preview(profile: "bot-one", session: "manual", scope: "office", home: home) == "회사 봇의 별도 대화방")
        precondition(HermesConversation.preview(profile: "bot-one", session: "manual", scope: "custom", home: home) == nil)
        let unknown = Providers().splashJob(["id": "test", "slot": 1, "client": "로컬 요청", "model": "model"], label: "봇 1", port: 8002)
        precondition(unknown.title.contains("앱 미확인") && unknown.attributionNote != nil)
        let known = Providers().splashJob(["id": "known", "slot": 1, "profile": "default", "session": "test", "client": "Hermes"], label: "봇 1", port: 8002)
        precondition(known.title.contains("Hermes") && !known.title.contains("로컬 요청"))
        let finished = Providers().splashJob(["id": "recent", "profile": "default", "session": "test", "client": "Hermes", "state": "finished"], label: "", port: 8002)
        precondition(finished.control == nil && finished.activity == .idle)
        let before = try Data(contentsOf: dbFile)
        let title = HermesConversation.preview(profile: "bot-one", session: "child", home: home)
        precondition(title?.hasPrefix("긴 대화방 제목 시작 부분 👩🏽‍💻") == true, "title=\(String(describing: title))")
        precondition(title?.count == 43 && title?.hasSuffix("…") == true)
        precondition(HermesConversation.preview(profile: "bot-one", session: "manual", home: home) == "파일 정리 요청")
        precondition(HermesConversation.preview(profile: "bot-one", session: "branch", home: home) == nil)
        precondition(HermesConversation.preview(profile: "bot-one", session: "wrong-owner", home: home) == nil)
        precondition(HermesConversation.preview(profile: "bot-one", session: "canonical", home: home) == "봇 대화")
        precondition(HermesConversation.preview(profile: "bot-one", session: "empty", home: home) == nil)
        precondition(HermesConversation.preview(profile: "../bot-one", session: "origin", home: home) == nil)
        precondition(HermesConversation.preview(profile: "bot-one", session: "origin' OR 1=1", home: home) == nil)
        let after = try Data(contentsOf: dbFile)
        precondition(before == after)
        if CommandLine.arguments.count == 4 {
            let args = CommandLine.arguments
            guard let actual = HermesConversation.preview(profile: args[1], session: args[2]),
                  actual == args[3] else { fatalError("실제 Hermes 제목 불일치") }
            print("Hermes 기존 세션 제목 앞부분 일치")
        }
        print("긴 한글 제목과 이모지, 압축 후속 세션, 이름 충돌, 제목 없는 세션, 읽기 전용 검증 통과")
    }
}
