# 用語集 / Glossary (ja → en / es / pt-BR)

`Sources/Resources/Localizable.xcstrings` の翻訳で使う訳語の基準。同じ概念には必ず同じ語を使う。
新しい文字列を足すとき・機械翻訳を直すときはこの表に合わせる。

## 表記ルール

- 引用符は 3 言語とも curly の “ ”(es の « » や straight の " は使わない)。en のアポストロフィは straight の `'`。
- ボタン操作は en「Tap」/ es「toca」/ pt-BR「toque」(Press / Click / pulsa は使わない)。
- es は tú 体、pt-BR は você 体。en は米国綴り(color, canceled)。
- 「追加」の es は **agregar**(añadir は使わない)。
- `%lld` `%@` `%1$@` などのプレースホルダー、先頭・末尾の空白、`…`、改行(実改行。`\n` の 2 文字ではない)はキーと同じにする。
- 画面に出る名前(ボタン・項目・見出し・選択肢)は先頭を大文字にする。検索の別名として小文字で作った訳を画面の名前にも使うときは、先頭を大文字に直す(ぼかし → Blur、形 → Shape、声 → Voice)。検索は大文字・小文字を区別しないので、別名としても困らない。
- 文の途中につなげて使う訳は小文字のまま:「%lld 件のキャプションを」+「追加しました / 読み込みました」(added / loaded。es・pt-BR は字幕の性・数に合わせて agregados / adicionadas)、書き出しが止まった理由の「〜ため」(because …)、比較の「少し・かなり」「大きい」、見どころの理由の文に入る景色の言葉(海・山・夜景 など)、読み上げの声の説明(「Nova(female, energetic)」のように名前のあとに続く)。
- 文の中でボタン名に触れるとき(キーでは「」に入っている)は、そのボタンのいまの訳と同じ字(大文字・小文字も)にして “ ” で囲む。ボタンの名前を変えたら、その名前を「」で書いているキーの訳も直す。
- 1 つのキーを、使い方の違う場所で兼ねない。兼ねていると、どちらかで大文字・小文字や訳語が合わなくなる(いまは「明るさ」「色味」がスライダーの名前と文の中、「夜景」が BGM の名前と場面の言葉、「チェック」がステッカーの名前(チェックマーク)と編集チェックの検索の別名(確認)を兼ねている。直すにはコード側でキーを分ける)。

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
| ボイスオーバー(録音) | voice-over | voz en off | narração | 検索の別名に残っているだけ。画面の名前は「ナレーション」 |
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
| モザイク | pixelate / pixelation | pixelar / pixelado | pixelizar / pixelização | mosaic は使わない。ツール・種類の名前は Pixelate / Pixelado(名詞)/ Pixelizar |
| ぼかし | blur | desenfoque | desfoque | モザイク(pixelate)とは別の種類 |
| 描画モード(ブレンド) | blend mode | modo de fusión | modo de mesclagem | 「乗算」= Multiply、「スクリーン」= Screen |
| 反転(マスク) | invert | invertir | inverter | マスクの内側と外側を入れ替える。左右の反転(flip)ではない |
| 冒頭フック | opening hook | gancho inicial | gancho inicial | cold open ではない |
| エンドスクリーン / 終了画面 | end screen | pantalla final | tela final | ツールバーは「終了画面」= End Screen |
| 空き容量 | free space | espacio libre | espaço livre | |
| 元に戻す / やり直す | Undo / Redo | Deshacer / Rehacer | Desfazer / Refazer | |
| カラー(色の調整一式) | color | color | cor | 「カラーをコピー / カラーを貼り付け」= Copy Color / Paste Color。前の「調整をコピー」(Copy Look)は検索の別名だけ |

## ツールバー・メニューの名前

- en は Title Case(Split, Auto Captions, Apply to All, Record with Camera)。es・pt-BR は先頭だけ大文字(Subtítulos automáticos、Legendas automáticas)。
- 長さは文字数ではなく折り返し方で考える。ツールバーのセルの名前(`EditorToolbar.swift` の `EditorToolLabel.wrapped`)は:
  - 6 文字以下はそのまま 1 行。
  - 7 文字以上は、**最初の空白か「・」のところで 1 回だけ** 折って 2 行にする(Translate Captions →「Translate / Captions」、Position & Size →「Position / & Size」)。
  - 空白も「・」もない名前は折らない(真ん中で折るのは日本語で表示しているときだけ)。下のツールバーのセルは `.fixedSize()` なので、折れない長い名前はそのぶんセルが横に広がる。右の列(縦)では、列の幅に入らない名前は 0.8 倍まで縮む。
  - だから空白のない「A/B」(Position/Size)にはしないで、「A & B」(en)・「A y B」(es)・「A e B」(pt-BR)にする。後ろに空白がある名前(Logo/marca de agua)は折れるのでそのままでよい。短くしても、いちばん長い行の幅が変わらなければ意味がない(Reenquadramento automático は「Reenquadramento / automático」になり、Reenquadramento だけにしても幅は同じ)。
  - 2 行目のほうが長くなりすぎないよう、最初の空白の位置にも気をつける(Move tools back to bottom は「Move / tools back to bottom」になる)。
  - 日本語の名前の折る位置は `EditorToolLabel.breaks` で決めている。この辞書のキーは訳さない日本語の文字列なので、訳が重なっても関係ない。
- 同じ言語の中で、2 つのツールを同じ訳にしない。`EditorToolSearch.swift` の別名辞書 `EditorToolSearchIndex.synonyms` は `String(localized: "…")` をキーにした辞書リテラルなので、**2 つのキーの訳が同じになると、起動したときにアプリが落ちる**。名前を変えたら、この辞書のキーどうし(タップで開くメニューの項目「ファイル」「カメラで撮る」「方眼紙の背景」も入っている)と、同じ列に並ぶ名前どうしが、en・es・pt-BR のどれでも重ならないことを確かめる。辞書の値(別名)は重なってもよい。
- 前の名前(1.12.78 で名前を変える前の「キャプションを作成」「調整をコピー」など)は、もうツールバーには出ない。別名辞書の値として残っているだけで、前の言葉で探しても見つかるようにするためのもの(下の表)。訳は検索に使うだけなので小文字でもよく、ほかのツールの名前と同じ訳になってもかまわない。

### いまの名前

場所は、何も選んでいないときの最上段とそのグループ(テキスト・オーディオ・エフェクト・全体・AI・その他・設定)、何かを選んだときの列(クリップ・オーバーレイ など)。同じ名前がほかの列にも出るときは、最初に出る場所だけ書く(音量・削除・複製・モーション・キーフレーム など)。正は `ContentView.swift` の `EditorToolItem(...)` / `EditorToolMenuEntry(...)`。名前を変えたらこの表も直す。

| 場所 | ja | en | es | pt-BR |
|---|---|---|---|---|
| 最上段 › 追加(メニュー) | 動画を選ぶ | Choose Videos | Elegir videos | Escolher vídeos |
| 最上段 › 追加(メニュー) | 写真を選ぶ(キーは「写真を選ぶ(複数)」。ja の表示はカタログの ja の値。表紙の 1 枚選択の「写真を選ぶ」= Choose photo とは別のキー) | Choose Photos | Elegir fotos | Escolher fotos |
| 最上段 › 追加(メニュー) | 方眼紙の背景 | Grid Paper Background | Fondo cuadriculado | Fundo quadriculado |
| 最上段 › 追加(メニュー) | ファイル | Files | Archivos | Arquivos |
| 最上段 › 追加(メニュー) | カメラで撮る | Record with Camera | Grabar con la cámara | Gravar com a câmera |
| 最上段 › 追加(メニュー) | Osmo Pocket で撮る(実験) | Shoot with Osmo Pocket (Experimental) | Grabar con Osmo Pocket (experimental) | Gravar com Osmo Pocket (experimental) |
| 最上段 › 追加(メニュー) | カラーの画面 | Color Clip | Clip de color | Clipe de cor |
| 最上段 › 追加(メニュー) | Google フォト | Google Photos | Google Fotos | Google Fotos |
| 最上段 | 追加 | Add | Agregar | Adicionar |
| 最上段 | 分割 | Split | Dividir | Dividir |
| 最上段 | テキスト | Text | Texto | Texto |
| 最上段 | オーディオ | Audio | Audio | Áudio |
| 最上段 | エフェクト | Effects | Efectos | Efeitos |
| 最上段 | オーバーレイ | Overlay | Superposición | Sobreposição |
| 最上段 | AI | AI | AI | AI |
| 最上段 | 全体 | Whole Video | Todo el video | Vídeo inteiro |
| 最上段 | その他 | More | Más | Mais |
| 最上段 | 設定 | Settings | Ajustes | Ajustes |
| テキスト | 字幕 | Captions | Subtítulos | Legendas |
| テキスト | 自動字幕 | Auto Captions | Subtítulos automáticos | Legendas automáticas |
| テキスト | 字幕一覧 | Caption List | Lista de subtítulos | Lista de legendas |
| テキスト | 名前テロップ | Lower Third | Rótulo de nombre | Tarja de nome |
| テキスト | 章タイトル | Title Card | Tarjeta de título | Cartão de título |
| テキスト › 章タイトル(メニュー) | テロップで章タイトルを入れる | Add chapter title as text | Agregar título de capítulo como texto | Adicionar título de capítulo como texto |
| テキスト › 章タイトル(メニュー) | 以前の章タイトル(黒い画面)を編集 | Edit older chapter titles (black card) | Editar títulos de capítulo anteriores (tarjeta negra) | Editar títulos de capítulo anteriores (cartão preto) |
| テキスト | ステッカー | Sticker | Sticker | Adesivo |
| オーディオ | BGM | BGM | BGM | BGM |
| オーディオ | ナレーション | Narration | Narración | Narração |
| オーディオ | 効果音 | Sound Effects | Efectos de sonido | Efeitos sonoros |
| オーディオ | AI読み上げ | AI Voice | Voz con IA | Voz com IA |
| オーディオ | 音声抽出 | Extract Audio | Extraer audio | Extrair áudio |
| エフェクト | 映像エフェクト | Video Effects | Efectos de video | Efeitos de vídeo |
| エフェクト | モザイク | Pixelate | Pixelado | Pixelizar |
| エフェクト | 顔モザイク | Face Pixelate | Pixelar rostros | Pixelizar rostos |
| エフェクト | 手書き | Draw | Dibujar | Desenhar |
| 全体 | 全体の仕上げ | Final Polish | Acabado final | Acabamento final |
| 全体 | ロゴ・透かし | Logo & Watermark | Logo/marca de agua | Logo/marca d'água |
| 全体 | 音量そろえ | Match Loudness | Igualar volumen | Igualar volume |
| AI | おまかせ編集 | Auto Edit | Edición automática | Edição automática |
| AI | 無音カット | Cut Silence | Cortar silencios | Cortar silêncios |
| AI | 言いよどみカット | Remove Fillers | Cortar muletillas | Cortar hesitações |
| AI | 文字起こし編集 | Edit by Text | Editar transcripción | Editar transcrição |
| AI | 冒頭フック | Opening Hook | Gancho inicial | Gancho inicial |
| AI | オートパンチイン | Auto Punch-in | Punch-in automático | Punch-in automático |
| AI | 編集チェック | Edit Check | Revisión de edición | Verificação da edição |
| AI | スピーチを強調 | Enhance Speech | Realzar voz | Realçar fala |
| AI | オートリフレーム | Auto Reframe | Reencuadre automático | Reenquadramento automático |
| AI | 字幕を翻訳 | Translate Captions | Traducir subtítulos | Traduzir legendas |
| AI | 吹き替え | Dubbing | Doblaje | Dublagem |
| AI | おまかせテンプレ | Auto Templates | Plantillas automáticas | Modelos automáticos |
| AI | AI台本 | AI Script | Guion con IA | Roteiro com IA |
| AI | 終了画面 | End Screen | Pantalla final | Tela final |
| AI | スライドショー | Slideshow | Presentación | Apresentação de fotos |
| その他 | マーカー | Marker | Marcador | Marcador |
| その他 | パーツ | Parts | Partes | Partes |
| その他 | サムネ | Thumbnail | Miniatura | Miniatura |
| その他 | 前回と比較 | Compare | Comparar | Comparar |
| 設定 | 比率 | Aspect Ratio | Proporción | Proporção |
| 設定 | 動画の置き場所 | Video Storage | Ubicación de videos | Local dos vídeos |
| 設定 | 表示ガイド | Safe Zones | Zonas seguras | Zonas seguras |
| 設定 | ツールを下に戻す | Move tools back to bottom | Volver a poner las herramientas abajo | Voltar as ferramentas para baixo |
| 設定 | ツールを右に置く | Put tools on the right | Poner las herramientas a la derecha | Colocar as ferramentas à direita |
| 設定 | このプロジェクトを空にする | Empty Project | Vaciar proyecto | Esvaziar projeto |
| クリップ | 音量 | Volume | Volumen | Volume |
| クリップ | 速度 | Speed | Velocidad | Velocidade |
| クリップ › 速度 | タイムリマップ | Time Remap | Remapeo de tiempo | Remapear tempo |
| クリップ › 速度 | 逆再生を解除 | Undo Reverse | Deshacer inversión | Desfazer reversão |
| クリップ › 速度 | 逆再生 | Reverse | Invertir | Reverter |
| クリップ › 速度 | フレーム保持 | Freeze Frame | Congelar fotograma | Congelar quadro |
| クリップ | カラー | Color | Color | Cor |
| クリップ | モーション | Motion | Movimiento | Movimento |
| クリップ | トランジション | Transition | Transición | Transição |
| クリップ | 削除 | Delete | Eliminar | Excluir |
| クリップ › その他 | 分割を戻す | Undo Split | Deshacer división | Desfazer divisão |
| クリップ › その他 | 置き換え | Replace | Reemplazar | Substituir |
| クリップ › AI | 画質補正 | Quality Boost | Mejorar calidad | Melhorar qualidade |
| クリップ › AI | レタッチ | Retouch | Retoque | Retoque |
| クリップ › モーション | 位置・クロップ | Position & Crop | Posición y recorte | Posição e corte |
| クリップ › モーション | アニメーション | Animation | Animación | Animação |
| クリップ › モーション | キーフレーム | Keyframes | Fotogramas clave | Quadros-chave |
| クリップ › モーション | スタビライザー | Stabilizer | Estabilizador | Estabilizador |
| クリップ › モーション | マスク | Mask | Máscara | Máscara |
| クリップ › モーション | 背景を消す | Remove BG | Quitar fondo | Remover fundo |
| クリップ › モーション | クロマキー | Chroma Key | Croma | Chroma key |
| クリップ › モーション | 被写体フラッシュ | Subject Flash | Destello del sujeto | Flash no assunto |
| クリップ › モーション | 3Dズーム | 3D Zoom | Zoom 3D | Zoom 3D |
| クリップ › オーディオ | 音声効果 | Audio Effects | Efectos de audio | Efeitos de áudio |
| クリップ › オーディオ | J/Lカット | J/L Cut | Corte J/L | Corte J/L |
| クリップ › オーディオ | ビート合わせ | Beat Sync | Sincronizar con el ritmo | Sincronizar com a batida |
| クリップ › カラー | カラープリセット | Color Presets | Preajustes de color | Predefinições de cor |
| クリップ › カラー | 自動補正 | Auto Enhance | Mejora automática | Melhoria automática |
| クリップ › カラー | カラー補正 | Color Correct | Corrección de color | Correção de cor |
| クリップ › カラー | カラーをコピー | Copy Color | Copiar color | Copiar cor |
| クリップ › カラー | カラーを貼り付け | Paste Color | Pegar color | Colar cor |
| クリップ › カラー | 全体に適用 | Apply to All | Aplicar a todo | Aplicar a todos |
| クリップ › カラー | HSL セカンダリ | HSL Secondary | HSL secundario | HSL secundário |
| クリップ › カラー | カラーマッチ | Color Match | Igualar color | Igualar cor |
| クリップ › カラー | LUT | LUT | LUT | LUT |
| クリップ › カラー | カラースコープ | Color Scopes | Ámbitos de color | Escopos de cor |
| クリップ › その他 | 複製 | Duplicate | Duplicar | Duplicar |
| クリップ › その他 | 複数選択 | Multi-Select | Selección múltiple | Seleção múltipla |
| クリップ › その他 | 前へ移動 | Move Earlier | Mover antes | Mover para antes |
| クリップ › その他 | 後ろへ移動 | Move Later | Mover después | Mover para depois |
| クリップ › その他 | スリップ | Slip | Deslizar | Deslizar |
| クリップ › その他 | トリミングを解除 | Reset Trim | Restablecer recorte | Redefinir corte |
| クリップ › その他 | マルチカメラ | Multicam | Multicámara | Multicâmera |
| クリップ › その他 | パーツとして保存 | Save as Part | Guardar como parte | Salvar como parte |
| オーバーレイ | 位置・サイズ | Position & Size | Posición y tamaño | Posição e tamanho |
| オーバーレイ | 不透明度 | Opacity | Opacidad | Opacidade |
| オーバーレイ › モーション | トラッキング | Tracking | Seguimiento | Rastreamento |
| オーバーレイ › モーション | ズーム・パン | Zoom & Pan | Zoom y paneo | Zoom e pan |
| オーバーレイ › カラー | 描画モード | Blend Mode | Modo de fusión | Modo de mesclagem |
| 字幕 | 文字を直す | Edit Text | Editar texto | Editar texto |
| 字幕 | 字幕デザイン | Caption Style | Diseño de subtítulos | Design da legenda |
| BGM | BGMを置き換え | Replace Music | Reemplazar música | Substituir música |
| テキスト(選択) | 文字・スタイル | Text & Style | Texto y estilo | Texto e estilo |
| 手書き(選択) | 色・太さ | Color & Width | Color y grosor | Cor e espessura |
| 手書き(選択) | 表示する時間 | Display Time | Tiempo en pantalla | Tempo de exibição |
| マーカー(選択) | 名前 | Name | Nombre | Nome |
| マーカー(選択) | 色・種類 | Color & Type | Color y tipo | Cor e tipo |
| 映像エフェクト(選択) | 種類・強さ | Type & Strength | Tipo e intensidad | Tipo e intensidade |
| 複数選択 | 完了 | Done | Listo | Concluído |
| 複数選択 | 選択を解除 | Deselect | Quitar selección | Desmarcar |
| 複数選択 | すべて選択 | Select All | Seleccionar todo | Selecionar tudo |
| 複数選択 | 前へ | Earlier | Antes | Antes |
| 複数選択 | 後ろへ | Later | Después | Depois |
| 複数選択 | 削除(%lld) | Delete (%lld) | Eliminar (%lld) | Excluir (%lld) |

### 前の名前(検索の別名だけ)

| 前の名前 | いまの名前 |
|---|---|
| スプリット | 分割 |
| リップル削除 | 削除 |
| ビデオトランジション | トランジション |
| 速度・デュレーション | 速度 |
| ボリューム | 音量 |
| オーディオエフェクト | 音声効果 |
| モーション・クロップ | 位置・クロップ |
| フッテージを置き換え | 置き換え |
| キャプション | 字幕 |
| キャプションを作成 | 自動字幕 |
| キャプションを一覧で直す / 一覧で直す | 字幕一覧 |
| 文字起こしで編集 | 文字起こし編集 |
| キャプションのデザイン / キャプションのスタイル | 字幕デザイン |
| ボイスオーバー録音 / ボイスオーバー | ナレーション |
| ラウドネスを自動一致 | 音量そろえ |
| 無音部分を削除 | 無音カット |
| 曲を変更 | BGMを置き換え |
| 顔に自動モザイク | 顔モザイク |
| キャプションを翻訳 | 字幕を翻訳 |
| エンドスクリーンの余白 | 終了画面 |
| 調整をコピー | カラーをコピー |
| 調整を貼り付け / 調整をペースト | カラーを貼り付け |
| 調整を全クリップに適用 | 全体に適用 |
| ビートに合わせる | ビート合わせ |
| 中だるみ・編集チェック | 編集チェック |
| 動画・写真を追加 | 追加(タイムラインの「+」には今もこの名前で出る。空の画面は「動画を追加」に変わった) |
