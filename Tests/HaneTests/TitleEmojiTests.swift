import Testing
@testable import Hane

/// 題名の頭の絵文字をアイコンの場所へ移す決まり。
@Suite struct TitleEmojiTests {
    @Test func takesALeadingEmojiFollowedByASpace() {
        let notion = TitleEmoji("🌅 Dev朝会ボード | Notion")
        #expect(notion?.emoji == "🌅")
        #expect(notion?.rest == "Dev朝会ボード | Notion")
        #expect(TitleEmoji("❤️ 好き")?.emoji == "❤️", "異体字セレクタ付きのものも絵文字として描かれる")
        #expect(TitleEmoji("👩‍💻 作業")?.emoji == "👩‍💻", "つないだ絵文字は一つとして扱う")
        #expect(TitleEmoji("🇯🇵 日本")?.emoji == "🇯🇵")
    }

    @Test func leavesOtherTitlesAlone() {
        #expect(TitleEmoji("Dev朝会ボード | Notion") == nil)
        #expect(TitleEmoji("🌅Dev朝会ボード") == nil, "空白が続かなければ題名の一部として残す")
        #expect(TitleEmoji("🌅 ") == nil, "絵文字のほかに何もなければ残す")
        #expect(TitleEmoji("1 件の通知") == nil, "数字は絵文字の性質を持つが、文字として描かれる")
        #expect(TitleEmoji("© 2026 something") == nil)
        #expect(TitleEmoji("(3) 🌅 受信箱") == nil)
    }
}

