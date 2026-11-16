import Foundation

/// 普通のタブの組。窓（プロファイル）ごとに持ち、バーには選んでいる組のタブだけを出す。
///
/// どの組にも入っていないタブも一つの組のように扱い、`TabStore` では組のIDを `nil` として持つ。
struct TabGroup: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    /// 名前をバーに並べて、一押しで移れるようにするか。並べないものはバーのボタンの一覧から選ぶ。
    var showsInBar: Bool
}

/// 組の名前を打ってもらう頼み。タブ管理が出し、画面が名前の入力欄を出して受ける。
enum GroupNaming: Equatable {
    /// 新しい組を作って移る。タブを渡せば、そのタブを連れて移る。
    case create(moving: Tab.ID?)
    case rename(UUID)
}
