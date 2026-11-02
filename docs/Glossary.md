# 用語集 / Glossary (ja → en / es / pt-BR)

`Sources/Resources/Localizable.xcstrings` の翻訳で使う訳語の基準。同じ概念には必ず同じ語を使う。
新しい文字列を足すとき・機械翻訳を直すときはこの表に合わせる。

## 表記ルール

- 引用符は 3 言語とも curly の “ ”(es の « » や straight の " は使わない)。en のアポストロフィは straight の `'`。
- ボタン操作は en「Tap」/ es「toca」/ pt-BR「toque」(Press / Click / pulsa は使わない)。
- es は tú 体、pt-BR は você 体。en は米国綴り(color, canceled)。
- 「追加」の es は **agregar**(añadir は使わない)。
- ツールバーのボタン名は en で Title Case、**14 文字前後まで**。`EditorToolSearch.swift` の別名辞書のキーになるため、同じ言語内で 2 つのツール名が同じ訳になってはいけない(クラッシュする)。
- `%lld` `%@` `%1$@` などのプレースホルダー、先頭・末尾の空白、`…`、改行(実改行。`\n` の 2 文字ではない)はキーと同じにする。

## 用語

| ja | en | es | pt-BR | メモ |
|---|---|---|---|---|
| キャプション / 字幕 | captions (caption) | subtítulos (subtítulo) | legendas (legenda) | 文字起こしの字幕。両方同じ訳 |
| テロップ(一般) | title | rótulo | letreiro | 画面上の文字。captions と区別する |
| 名前テロップ(ローワーサード) | lower third | rótulo de nombre | tarja de nome | pt-BR で legenda は使わない |
| 黒帯テロップ | black bar title | rótulo con barra negra | letreiro com tarja preta | |
| クリップ | clip | clip | clipe | |
| 書き出し / 書き出す | export | exportación / exportar | exportação / exportar | 「保存」ではない |
| 書き出した動画 | exported videos | videos exportados | vídeos exportados | |
| 写真に保存 | Save to Photos | Guardar en Fotos | Salvar em Fotos | |
| 取り込む | import | importar | importar | |
| ポイント(アプリ内) | points | puntos | pontos | |
| アカウントとポイント | Account & Points | Cuenta y puntos | Conta e pontos | 設定画面名 |
| 端末 | device | dispositivo | aparelho | |
| 素材 | media | material | mídia | footage / items は使わない |
| 重ねた素材(オーバーレイ) | overlay | superposición | sobreposição | |
| プロジェクト | project | proyecto | projeto | |
| タイムライン | timeline | línea de tiempo | linha do tempo | |
| 再生位置 | playhead | posición de reproducción | posição de reprodução | |
| トランジション | transition | transición | transição | |
| キーフレーム | keyframes | fotogramas clave | quadros-chave | |
| フレーム保持 | freeze frame | congelar fotograma | congelar quadro | hold frame は使わない |
| 速度 / デュレーション | speed / duration | velocidad / duración | velocidade / duração | |
| 比率(画面比率) | aspect ratio | proporción | proporção | |
| BGM | music | música | música | |
| 曲 | song | canción | música | |
| 効果音 | sound effects | efectos de sonido | efeitos sonoros | |
| 音声 | audio | audio | áudio | |
| ナレーション | narration | narración | narração | voice-over と混ぜない |
| ボイスオーバー(録音) | voice-over | voz en off | narração | |
| AI読み上げ | AI Voice | Voz con IA | Voz com IA | |
| 吹き替え | dubbing | doblaje | dublagem | |
| 文字起こし | transcription (transcribe) | transcripción | transcrição | |
| 文字起こしとAI仕上げ | Transcription & AI Cleanup | Transcripción y acabado con IA | Transcrição e acabamento com IA | 設定画面名 |
| AI仕上げ | AI cleanup | acabado con IA | acabamento com IA | |
| 見どころ | highlights | momentos destacados | destaques | |
| 言いよどみ | filler words | muletillas | hesitações | |
| 無音 | silence | silencio | silêncio | |
| サムネ | thumbnail | miniatura | miniatura | |
| おまかせ | auto | automático | automático | |
| モザイク | pixelate / pixelation | pixelar / pixelado | pixelizar / pixelização | mosaic は使わない |
| 冒頭フック | opening hook | gancho inicial | gancho inicial | cold open ではない |
| エンドスクリーン | end screen | pantalla final | tela final | |
| 空き容量 | free space | espacio libre | espaço livre | |
| 元に戻す / やり直す | Undo / Redo | Deshacer / Rehacer | Desfazer / Refazer | |
| 調整(カラーの調整セット) | look | ajustes | ajustes | 「調整をコピー」= Copy Look |

## ツールバーのボタン名(en 14 文字前後)

| ja | en | es | pt-BR |
|---|---|---|---|
| キャプションを作成 | Auto Captions | Crear subtítulos | Criar legendas |
| キャプションを一覧で直す | Caption List | Lista de subtítulos | Lista de legendas |
| キャプションを翻訳 | Translate | Traducir | Traduzir |
| 調整をコピー / 調整を貼り付け | Copy Look / Paste Look | Copiar ajustes / Pegar ajustes | Copiar ajustes / Colar ajustes |
| 調整を全クリップに適用 | Apply to All | Aplicar a todos | Aplicar a todos |
| 顔に自動モザイク | Face Pixelate | Pixelar rostros | Pixelizar rostos |
| 背景を消す | Remove BG | Quitar fondo | Remover fundo |
| 文字起こしで編集 | Edit by Text | Editar por texto | Editar por texto |
| 位置・サイズ | Position/Size | Posición/tamaño | Posição/tamanho |
| ラウドネスを自動一致 | Match Loudness | Igualar volumen | Igualar volume |
| ビデオトランジション | Transition | Transición | Transição |
| 表示ガイド | Safe Zones | Zonas seguras | Zonas seguras |
| 画質補正 | Quality Boost | Mejorar calidad | Melhorar qualidade |
| 動画・写真を追加 | Add Media | Agregar video/foto | Adicionar mídia |
| 動画の置き場所 | Video Storage | Ubicación de videos | Local dos vídeos |
| 前回と比較 | Compare | Comparar | Comparar |
| 分割を戻す | Undo Split | Deshacer división | Desfazer divisão |
| 全体の仕上げ | Final Polish | Acabado final | Acabamento final |
| 中だるみ・編集チェック | Pacing Check | Revisión de ritmo | Checagem de ritmo |
| ロゴ・透かし | Logo/Watermark | Logo/marca de agua | Logo/marca d'água |
| ボイスオーバー録音 | Voice-over | Grabar voz en off | Gravar narração |
| フレーム保持 | Freeze Frame | Congelar fotograma | Congelar quadro |
| カラー補正 | Color Correct | Corrección de color | Correção de cor |
| カラーの画面 | Color Clip | Clip de color | Clipe de cor |
| カメラで撮る | Camera | Cámara | Câmera |
| エンドスクリーンの余白 | End Screen | Pantalla final | Tela final |
| このプロジェクトを空にする | Empty Project | Vaciar proyecto | Esvaziar projeto |
| 前へ / 後ろへ(複数選択の移動) | Earlier / Later | Antes / Después | Antes / Depois |
