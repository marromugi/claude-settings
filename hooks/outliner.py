#!/usr/bin/env python3
"""PreToolUse(Read) guard: 大きいファイルの全文読みの前に構造を取らせる。

offset/limit のない Read = 「全体が必要」という宣言。それが大きいファイルに
向いたときだけ差し込み、コードなら ast-grep outline、文書なら見出し一覧を促す。
offset か limit が付いていれば常に素通しなので、これがそのまま逃げ道になる。

環境変数:
  CLAUDE_OUTLINER_MODE   deny(既定) | warn | off
  CLAUDE_OUTLINER_BYTES  発動する閾値バイト数 (既定 8000 ≒ 2,000 tok)
  CLAUDE_OUTLINER_LOG    ログ出力先 (既定 ~/.claude/hooks/outliner.log)
"""
import json
import os
import re
import sys

MODE = os.environ.get("CLAUDE_OUTLINER_MODE", "deny")
THRESH = int(os.environ.get("CLAUDE_OUTLINER_BYTES", "8000"))
LOG = os.environ.get(
    "CLAUDE_OUTLINER_LOG",
    os.path.expanduser("~/.claude/hooks/outliner.log"),
)

# 画像・データ・巨大生成物。outline も見出しも効かないので対象外。
SKIP_EXT = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".ico", ".pdf", ".svg",
    ".jsonl", ".csv", ".tsv", ".parquet", ".sqlite", ".db", ".map", ".lock",
    ".ipynb", ".zip", ".tar", ".gz", ".woff", ".woff2", ".ttf",
}

# 型定義・生成物・ベンダ。中身がほぼ全部シンボルで outline が圧縮されない。
SKIP_PATH = re.compile(
    r"""(?ix)
    \.d\.ts$
  | \.min\.(js|css)$
  | \.generated\.
  | (^|/)(package-lock\.json|pnpm-lock\.yaml|yarn\.lock|Cargo\.lock
        |poetry\.lock|go\.sum|composer\.lock)$
  | /(node_modules|\.venv|venv|dist|build|target|\.next|vendor|__pycache__)/
    """
)

DOC_EXT = {".md", ".mdx", ".markdown", ".txt", ".rst", ".adoc", ".org"}

# yq が読める構造化データ。全文を読まずスキーマとパスで扱う。
STRUCT_EXT = {".yaml", ".yml", ".json", ".toml", ".xml", ".properties"}
# yq が拡張子から入力形式を判定できないものだけ -p を足す。
STRUCT_INPUT = {".xml": "xml", ".properties": "props"}
CODE_EXT = {
    ".py", ".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".swift", ".rs", ".go",
    ".rb", ".java", ".kt", ".kts", ".c", ".cc", ".cpp", ".h", ".hpp", ".cs",
    ".php", ".scala", ".lua", ".sh", ".bash", ".zsh", ".vue", ".svelte",
}


def log(line):
    try:
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except Exception:
        pass


def emit(reason, path, size, lines, decision):
    log(f"{decision}\t{size}\t{lines}\t{path}")
    if decision == "allow":
        return
    if MODE == "warn":
        out = {
            "systemMessage": f"large read: {os.path.basename(path)} ({lines:,} lines)",
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "additionalContext": reason,
            },
        }
    else:
        out = {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        }
    json.dump(out, sys.stdout)


def main():
    if MODE == "off":
        return
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    if data.get("tool_name") not in (None, "Read"):
        return

    ti = data.get("tool_input") or {}
    path = ti.get("file_path")
    if not path:
        return

    ranged = bool(ti.get("offset") or ti.get("limit"))

    if os.path.splitext(path)[1].lower() in SKIP_EXT or SKIP_PATH.search(path):
        return

    try:
        size = os.path.getsize(path)
    except OSError:
        return
    if size < THRESH:
        return

    # 範囲指定は「探索している」という宣言。常に通す = 逃げ道。
    # ただし大きいファイルへの範囲読みは記録する — 逃げ道が
    # 実質的な全文読み (limit=5000 等) に使われていないか後で測るため。
    if ranged:
        log(f"pass\t{size}\t-\t{path}\toffset={ti.get('offset')},limit={ti.get('limit')}")
        return

    try:
        with open(path, "rb") as fh:
            head = fh.read(4096)
            if b"\0" in head:  # バイナリ
                return
        with open(path, encoding="utf-8", errors="replace") as fh:
            lines = sum(1 for _ in fh)
    except OSError:
        return

    ext = os.path.splitext(path)[1].lower()
    tok = size // 4
    quoted = path.replace("'", "'\\''")

    if ext in CODE_EXT:
        how = (
            f"Map it first — `ast-grep outline '{quoted}'` typically costs 2-5% of a "
            f"full read and gives you every symbol with its line number. Then Read only "
            f"the ranges you need with offset/limit."
        )
    elif ext in DOC_EXT:
        how = (
            f"Map it first — `grep -n '^#' '{quoted}'` gives the heading outline for a "
            f"few dozen tokens. Then Read only the sections you need with offset/limit."
        )
    elif ext in STRUCT_EXT:
        p = STRUCT_INPUT.get(ext)
        pflag = f"-p {p} " if p else ""
        schema = (
            f"yq {pflag}-o=props '.' '{quoted}' | cut -d= -f1 | "
            r"sed 's/\.[0-9][0-9]*/[]/g' | sort -u"
        )
        how = (
            f"Don't read structured data as text. `{schema}` prints the schema with "
            f"array indices collapsed, typically 2-3% of a full read. Then pull only the "
            f"paths you need with `yq {pflag}'<path>' '{quoted}'`. Use yq to read, not to "
            f"write — `yq -i` reformats lines it never touched, so edit with Edit."
        )
    else:
        how = (
            f"Locate first — `grep -n <pattern> '{quoted}'` or `wc -l '{quoted}'` — then "
            f"Read the range you need with offset/limit."
        )

    reason = (
        f"{os.path.basename(path)} is {lines:,} lines (~{tok:,} tokens). "
        f"Reading it whole would put all of that in context for the rest of the session. "
        f"{how} "
        f"If you do need the entire file, re-issue this Read with an explicit limit "
        f"(e.g. limit={min(lines + 1, 2000)}) — any Read carrying offset or limit is "
        f"passed straight through."
    )
    emit(reason, path, size, lines, "deny" if MODE == "deny" else "warn")


if __name__ == "__main__":
    main()
