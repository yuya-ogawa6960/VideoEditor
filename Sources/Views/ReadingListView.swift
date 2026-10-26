import SwiftUI

// =====================================================================
// 「読み方の登録」: 読み上げの声が読み間違える言葉と、その読み(追加・スワイプで削除)
// =====================================================================

struct ReadingListView: View {
    @State private var entries: [ReadingEntry] = ReadingDictionary.load()
    @State private var newWord = ""
    @State private var newReading = ""

    private var canAdd: Bool {
        let word = newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let reading = newReading.trimmingCharacters(in: .whitespacesAndNewlines)
        return !word.isEmpty && !reading.isEmpty && word != reading
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    TextField("家系ラーメン", text: $newWord)
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    TextField("いえけいラーメン", text: $newReading)
                }
                .autocorrectionDisabled()
                Button("追加") {
                    ReadingDictionary.add(word: newWord, reading: newReading)
                    entries = ReadingDictionary.load()
                    newWord = ""
                    newReading = ""
                }
                .disabled(!canAdd)
            } footer: {
                Text("読みはひらがなで入れると確実です。")
            }

            Section {
                if entries.isEmpty {
                    Text("登録した読み方はありません")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries) { entry in
                    HStack(spacing: 8) {
                        Text(verbatim: entry.word)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(verbatim: entry.reading)
                    }
                }
                .onDelete { offsets in
                    entries.remove(atOffsets: offsets)
                    ReadingDictionary.save(entries)
                }
            } footer: {
                Text("読み上げるときだけ置き換えます。画面の文章や字幕は変わりません。")
            }
        }
        .navigationTitle("読み方の登録")
        .navigationBarTitleDisplayMode(.inline)
    }
}
