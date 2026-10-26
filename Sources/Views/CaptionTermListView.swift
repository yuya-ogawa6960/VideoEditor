import SwiftUI

// =====================================================================
// 設定の「用語の登録」: 文字起こしのあとに自動で置き換える言葉の一覧(追加・スワイプで削除)
// =====================================================================

struct CaptionTermListView: View {
    @State private var terms: [CaptionTerm] = CaptionTermDictionary.load()
    @State private var newFrom = ""
    @State private var newTo = ""

    private var canAdd: Bool {
        let from = newFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        return !from.isEmpty && from != newTo.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("変える前", text: $newFrom)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField("変えた後", text: $newTo)
                }
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                Button("追加") {
                    CaptionTermDictionary.add(from: newFrom, to: newTo)
                    terms = CaptionTermDictionary.load()
                    newFrom = ""
                    newTo = ""
                }
                .disabled(!canAdd)
            }

            Section {
                if terms.isEmpty {
                    Text("登録した用語はありません")
                        .foregroundStyle(.secondary)
                }
                ForEach(terms) { term in
                    HStack(spacing: 8) {
                        Text(verbatim: term.from)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if term.to.isEmpty {
                            Text("削除")
                                .foregroundStyle(.secondary)
                        } else {
                            Text(verbatim: term.to)
                        }
                    }
                }
                .onDelete { offsets in
                    terms.remove(atOffsets: offsets)
                    CaptionTermDictionary.save(terms)
                }
            } footer: {
                Text("文字起こしのあとに自動で置き換えます。")
            }
        }
        .navigationTitle("用語の登録")
        .navigationBarTitleDisplayMode(.inline)
    }
}
