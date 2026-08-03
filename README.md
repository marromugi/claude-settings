# claude-settings

`~/.claude` 配下の個人設定。CLAUDE.md、hooks、settings.json、ステータスライン。

```
CLAUDE.md                  全プロジェクト共通の指示 (ast-grep / Read / yq)
settings.json              モデル、権限、プラグイン、hooks の配線
statusline-command.sh      settings.json の statusLine から参照される
hooks/
  outliner.py      大きいファイルの全文読みを止め、構造を先に取らせる
```

## 導入

```sh
git clone <this repo> ~/Lab/claude-settings
cd ~/Lab/claude-settings
mkdir -p ~/.claude/hooks
cp CLAUDE.md settings.json statusline-command.sh ~/.claude/
cp hooks/outliner.py ~/.claude/hooks/
chmod +x ~/.claude/hooks/outliner.py ~/.claude/statusline-command.sh
```

依存: `ast-grep`、`yq` (v4)、`jq`、`python3`。

`~/.claude` が正なので、あちらを直したらこちらへコピーし直すこと。

`settings.json` からはマシン固有の項目を外してある。必要なら各自で足す。

- `env` — 環境変数
- `permissions` — allow / deny ルール
- `enabledPlugins` — LSP などのプラグイン

## outliner

`PreToolUse` / matcher `Read`。`offset` も `limit` もない Read が 8KB 超のテキスト
ファイルに向いたときだけ差し込み、構造を先に取るよう促して deny する。

| 対象 | 案内 |
| --- | --- |
| コード (.py/.ts/.swift/.rs/…) | `ast-grep outline <path>` |
| 文書 (.md/.txt/.rst/…) | `grep -n '^#' <path>` |
| 構造化データ (.yaml/.json/.toml/.xml/.properties) | `yq -o=props` + 配列添字の畳み込み |
| その他 | `grep -n` / `wc -l` |

**逃げ道は `offset` か `limit` を付けること。** 範囲指定のある Read は無条件で通る。
判定を持たず、意図の宣言をそのまま信用する設計。

除外: 画像・データ系 (.jsonl/.csv/.lock/.pdf…)、`.d.ts`、`.min.*`、`.generated.*`、
各種 lock ファイル、`node_modules`/`dist`/`.venv`/`vendor` 配下、バイナリ、閾値未満。

### 環境変数

| 変数 | 既定 | 意味 |
| --- | --- | --- |
| `CLAUDE_OUTLINER_MODE` | `deny` | `deny` / `warn` (通すが助言) / `off` |
| `CLAUDE_OUTLINER_BYTES` | `8000` | 発動する閾値バイト数 (≒ 2,000 tok) |
| `CLAUDE_OUTLINER_LOG` | `~/.claude/hooks/outliner.log` | ログ出力先 |

### なぜ deny なのか

警告のみ (`additionalContext`) では、その読み込み自体は実行されてしまい、狙った
トークンは節約できない。次回への助言にしかならないため deny + 逃げ道にしてある。

### 効果の測り方

ログは TSV で `decision / bytes / lines / path / range`。

- `deny` 行 = 止めた全文読み
- `pass` 行 = 大きいファイルへの範囲読み。`limit=5000` のような行が並ぶなら
  逃げ道が実質的な全文読みに使われている

## 根拠にした実測

自分の 207〜288 セッション分のトランスクリプトを集計した結果。

| 項目 | 値 |
| --- | --- |
| Read が消費するトークン | 11,123 tok/session |
| うち全体読み | 79% |
| うち根拠のある範囲読み | 16% |
| うち当てずっぽうの範囲読み | 5% |
| Bash/Grep の出力 | 7,201 tok/session (1 件あたり中央値 98 tok) |

全文読みの後に編集が続いた 148 件で編集位置を特定したところ、書き換えた行はファイルの
中央値 5% しかない一方、その位置は全体の 43% に散らばっていた。「どこにあるか」と
「中身」を分離できる outline が効くのはこのため。

構造マップの圧縮率 (実測):

| | 元 | マップ | 比率 |
| --- | ---: | ---: | ---: |
| ContentView.swift (2,116 行) | 22,577 tok | 430 tok | 1.9% |
| eye_timeline.json (8,738 行) | 50,262 tok | ~880 tok | 1.7% |
| kubectl-get-deploy.yaml (3,237 行) | 32,895 tok | ~1,060 tok | 3.2% |

`sed -n 'A,Bp'` は当初 CLAUDE.md で禁止していたが、実使用 29 件のうち Read で代替
すべきものは 7 件だけだった (残りはパイプのページャ、locate との同一コマンド融合、
複数範囲・複数ファイル同時)。禁止は単独 1 範囲の読みに限定してある。
