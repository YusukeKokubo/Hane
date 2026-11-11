/// 命令の一覧と書式。アプリとコマンドの両方がこれを仕様の正本として使う。
public enum ControlHelp {
    public static let text = """
    browserctl — 起動中の Browser を外から操作する。アプリが起動していなければ自動で起動する。

    使い方: browserctl [--tab <番号>] <命令> [引数…]
      --tab を省くと、選択中のタブ（一覧で * の付いたタブ）が対象になる。

    タブ
      tabs                   タブの一覧
      new [URL|検索語]        新しいタブを開いて選択する
      select <番号>           タブを選択する
      close [番号]            タブを閉じる（最後の1枚は閉じられない）

    ブックマーク（タブバーの左側に並ぶ。フォルダは一段だけ）
      bookmarks              番号つきの一覧。番号はフォルダも含めた上からの通し番号
                             ページを開いているものには (open: tab N)、選択中には * が付く
      bookmark-add [URL|検索語] [--name 名前] [--folder フォルダ名]
                             URLを省くと、今のタブをページごとブックマークへ移す
                             フォルダがなければ作る
      bookmark-open <番号>    ブックマークをその場で開く（ページがあれば切り替えるだけ）
      bookmark-remove <番号>  ブックマークかフォルダを消す。開いていたページはタブとして残る

    移動（どれも読み込みが終わるまで待ってから返る）
      open <URL|検索語>       ページを開く。URLでなければ検索する
      back / forward / reload
      wait                   読み込みが終わるのを待つ

    ページを読む
      snapshot [--limit N]   操作できる要素を番号つきで一覧する。見出しも併せて出る
      text [--limit N]       本文のテキスト
      screenshot [保存先]     見えている範囲をPNGで保存し、パスを返す（選択中のタブのみ）
                             --full を付けるとページ全体を撮る
      eval <JavaScript>      式の値、または return した値をJSONで返す

    ページを操作する（番号は直前の snapshot のもの）
      click <番号>            クリックする
      fill <番号> <文字列>     入力欄に文字列を入れる。select要素なら選択肢を選ぶ
      press <キー> [番号]      キーを送る（Enter, Escape, Tab, ArrowDown など）。Enter はフォームを送信する

    開発と調査
      ui                     ウインドウの枠まわりの状態（アドレスバー、ボタン、ブックマークとタブの並び）
                             フォルダの一覧が出ていれば folder list に行が並び、選択中の行に > が付く
      key <キー>              ページの外（メニューやバー）へキーを送り、ui の結果を返す
                             キーは 1〜9, up, down, return, escape。cmd+ ctrl+ opt+ shift+ を前に付けられる
                             例: key ctrl+1（1番目のフォルダの一覧を開く）。アプリが裏にいても届き、前には出ない
      logs [--limit N] [--clear]
                             console出力、未処理の例外、読み込み失敗の記録（新しい順ではなく時系列）
      stats                  アプリと補助プロセスのメモリ・CPU
      quit                   アプリを終了する

    環境変数
      BROWSER_PROFILE=<名前>  普段使いとは別の実体を相手にする。ソケットが別になり、
                             Cookieなどは保存されない。開発や検証では dev を使うこと。

    典型的な流れ
      browserctl open example.com
      browserctl snapshot          # → [3] textbox "検索" などが並ぶ
      browserctl fill 3 "swift"
      browserctl press Enter 3
      browserctl text

    注意
      ・ページが変わったら番号は無効になる。操作の前に snapshot を取り直すこと。
      ・iframe の中の要素は snapshot に出ない。
      ・失敗したときは終了コード1で、理由を標準エラーに出す。
    """
}
