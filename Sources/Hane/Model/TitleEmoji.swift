/// 題名の頭に置かれた絵文字一つ。
///
/// ページがアイコン代わりに題名の頭へ絵文字を置くことがある（Notion は Safari を名乗るブラウザにだけそうする。
/// ほかのブラウザにはアイコンを後から差し替えて見せる）。そのまま出すとサイトのアイコンと並んで二つに見えるので、
/// サイトを問わず、絵文字一つと空白で始まる題名は、その絵文字をアイコンの場所に出して題名から外す。
struct TitleEmoji: Equatable {
    var emoji: String
    var rest: String

    init?(_ title: String) {
        guard let first = title.first, Self.isEmoji(first) else { return nil }
        let after = title.dropFirst()
        guard after.first == " " else { return nil }
        let rest = after.drop(while: { $0 == " " })
        guard !rest.isEmpty else { return nil }
        emoji = String(first)
        self.rest = String(rest)
    }

    /// 絵文字として描かれる文字か。数字や「©」のように、異体字セレクタがなければ文字として描かれるものは外す。
    private static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard let head = scalars.first, head.properties.isEmoji else { return false }
        return head.properties.isEmojiPresentation || scalars.contains("\u{FE0F}")
    }
}
