import SwiftUI

/// ブックマークとタブの間に置く、組の切り替え。
///
/// バーに出す組は名前を並べて一押しで移れるようにし、ほかの組はボタンの一覧から選ぶ。
/// 一つも並べなければボタンだけ、すべて並べれば名前の列になる。
struct GroupSwitcher: View {
    let store: TabStore

    @State private var isShowingList = false
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(store.groups.filter(\.showsInBar)) { group in
                GroupChip(name: group.name, isCurrent: store.currentGroupID == group.id) {
                    store.showGroup(group.id)
                }
                .contextMenu { GroupActions(store: store, group: group) }
            }
            Button { isShowingList.toggle() } label: {
                HStack(spacing: 6) {
                    label
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .frame(minHeight: 26)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .barItemBackground(isShowingList ? .selected : .idle, isHovered: isHovered)
            .onHover { isHovered = $0 }
            .help("グループを切り替える")
            .accessibilityLabel("グループ")
            .popover(isPresented: $isShowingList, arrowEdge: .bottom) {
                GroupList(store: store) { isShowingList = false }
            }
        }
        .padding(.trailing, 4)
        .modifier(GroupNamingAlert(store: store))
    }

    /// 並べていない組を出しているときは、ボタンにその名前を出す。並べた組を出しているときと、組に入っていないタブのときはアイコンだけ。
    @ViewBuilder private var label: some View {
        if let group = store.currentGroup, !group.showsInBar {
            Label(group.name, systemImage: "rectangle.stack")
                .labelStyle(.titleAndIcon)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
        } else {
            Image(systemName: store.currentGroupID == nil ? "square.grid.2x2" : "rectangle.stack")
        }
    }
}

/// バーに並べた組の名前。
private struct GroupChip: View {
    let name: String
    let isCurrent: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.callout.weight(isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(minHeight: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isCurrent ? .primary : .secondary)
        .barItemBackground(isCurrent ? .selected : .idle, isHovered: isHovered)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// ボタンから出す一覧。組に入っていないタブ、組の並び、作る操作、今の組への操作。
private struct GroupList: View {
    let store: TabStore
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            groupRow(nil, name: "グループなし", systemImage: "square.grid.2x2")
            if !store.groups.isEmpty {
                Divider().padding(.vertical, 4)
                Text("グループ")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 2)
                ForEach(store.groups) { group in
                    groupRow(group.id, name: group.name, systemImage: "rectangle.stack")
                }
            }
            Divider().padding(.vertical, 4)
            ListRow(title: "今のタブで新しいグループを作る…", systemImage: "plus.rectangle.on.rectangle") {
                dismiss()
                store.requestGroupName(.create(moving: selectedPlainTab))
            }
            .disabled(selectedPlainTab == nil)
            ListRow(title: "空のグループを作る…", systemImage: "plus.square") {
                dismiss()
                store.requestGroupName(.create(moving: nil))
            }
            if let group = store.currentGroup {
                Divider().padding(.vertical, 4)
                ListRow(title: group.showsInBar ? "「\(group.name)」をバーから外す" : "「\(group.name)」をバーに出す",
                        systemImage: group.showsInBar ? "pin.slash" : "pin") {
                    store.setShowsInBar(group.id, !group.showsInBar)
                }
                ListRow(title: "名前を変える…", systemImage: "pencil") {
                    dismiss()
                    store.requestGroupName(.rename(group.id))
                }
                ListRow(title: "グループを解く（タブはグループなしへ）", systemImage: "rectangle.stack.badge.minus") {
                    dismiss()
                    store.removeGroup(group.id)
                }
            }
        }
        .padding(6)
        .frame(width: 280)
    }

    private func groupRow(_ id: UUID?, name: String, systemImage: String) -> some View {
        ListRow(title: name, systemImage: systemImage, isChecked: store.currentGroupID == id,
                detail: "\(store.tabs(in: id).count)") {
            dismiss()
            store.showGroup(id)
        }
    }

    /// 選んでいるのが普通のタブなら、そのID。ブックマークのページは組に入れない。
    private var selectedPlainTab: Tab.ID? {
        store.selectedID.flatMap { store.groupKey(of: $0) != nil ? $0 : nil }
    }
}

/// 一覧の一行。左に印とアイコン、右に添え書き。
private struct ListRow: View {
    let title: String
    let systemImage: String
    var isChecked: Bool? = nil
    var detail: String? = nil
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tint)
                    .opacity(isChecked == true ? 1 : 0)
                    .frame(width: 12)
                    .accessibilityHidden(true)
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .fontWeight(isChecked == true ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .background(Color.primary.opacity(isHovered && isEnabled ? 0.08 : 0), in: .rect(cornerRadius: 6))
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isChecked == true ? .isSelected : [])
    }
}

/// 一つの組への操作。並べた名前の右クリックと、一覧の今の組の項に出す。
private struct GroupActions: View {
    let store: TabStore
    let group: TabGroup

    var body: some View {
        Button(group.showsInBar ? "バーから外す" : "バーに出す") {
            store.setShowsInBar(group.id, !group.showsInBar)
        }
        Button("名前を変える…") { store.requestGroupName(.rename(group.id)) }
        Divider()
        Button("グループを解く（タブはグループなしへ）") { store.removeGroup(group.id) }
    }
}

/// 普通のタブの右クリックに出す「グループへ移す」。
struct MoveToGroupMenu: View {
    let store: TabStore
    let tab: Tab

    var body: some View {
        Menu("グループへ移す") {
            if store.currentGroupID != nil {
                Button("グループから外す") { store.move(tab.id, to: nil) }
                Divider()
            }
            ForEach(store.groups.filter { $0.id != store.currentGroupID }) { group in
                Button(group.name) { store.move(tab.id, to: group.id) }
            }
            if store.groups.contains(where: { $0.id != store.currentGroupID }) {
                Divider()
            }
            Button("新しいグループへ移す…") { store.requestGroupName(.create(moving: tab.id)) }
        }
    }
}

/// 組の名前を打つ欄。タブ管理の `groupNaming` が立っている間だけ出す。
private struct GroupNamingAlert: ViewModifier {
    let store: TabStore

    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: Binding(
                get: { store.groupNaming != nil },
                set: { if !$0 { store.finishGroupNaming(nil) } }
            )) {
                TextField("名前", text: $name)
                Button(isRenaming ? "変える" : "作る") { store.finishGroupNaming(name) }
                Button("キャンセル", role: .cancel) { store.finishGroupNaming(nil) }
            } message: {
                Text(message)
            }
            .onChange(of: store.groupNaming, initial: true) { _, naming in
                if case .rename(let id) = naming {
                    name = store.group(withID: id)?.name ?? ""
                } else {
                    name = ""
                }
            }
    }

    private var isRenaming: Bool {
        if case .rename = store.groupNaming { return true }
        return false
    }

    private var title: String {
        isRenaming ? "グループの名前を変える" : "新しいグループ"
    }

    private var message: String {
        guard case .create(let tabID?) = store.groupNaming,
              let tab = store.tabs.first(where: { $0.id == tabID })
        else { return isRenaming ? "" : "作ったグループへ移ります。" }
        return "「\(tab.title)」を連れて、作ったグループへ移ります。"
    }
}
