# Tools

## ast-grep outline

Before reading unfamiliar code, run `ast-grep outline <file|dir>` to see its
structure, then Read only the lines that matter.

- Use the default text output. Do not pass `--json`.
- Skip it for a handful of files — just Read them.

## ast-grep search

- A zero-match result means the query is wrong, not that the code is clean.
- Cross-check counts against Grep before trusting a result.
- Pass `--json=stream` to collapse output to `file:line`.

## Read

Locate a range before reading it. Guessing line numbers and widening the
range after a miss costs more than one honest full read.

- Anchor first with `ast-grep outline` or `grep -no <symbol>`, then read the
  range it reports. Never guess a range and retry a wider one.
- Searching: locate first, then read. `grep -no` (line numbers and matched
  text only) or `grep -c` shows which lines hit without pulling their
  contents; Read those lines in full. Never truncate hits with `-o` alone or
  `cut` — on long lines the match often sits past the cut point.
- Narrow the pattern before widening it. A seven-way alternation over a spec
  file returns dozens of long lines; two or three terms return a handful.
- For a standalone read of one range, use `offset`/`limit` — re-reads of the
  same file are tracked. `sed -n 'A,Bp'` is fine when it rides along with the
  locator in one command, covers several ranges or files at once, or pages a
  pipe; those save a round trip Read cannot.
- Under ~8KB (roughly 200 lines), read the whole file instead of slicing it.
  Past that, map it first — `ast-grep outline` for code, `grep -n '^#'` for
  prose, `yq` for structured data — then read only the ranges that matter.
  A hook enforces this boundary; pass an explicit `limit` to override it.
- Never slice `.jsonl` by line range; one line can be enormous. Pull the
  fields you need with `jq` or python.

## yq

Query the path you need instead of reading a whole YAML file.
Also reads JSON, TOML, XML, and .properties — set `-p` / `-o` to convert.

- See the shape before querying it:
  `yq -o=props '.' <file> | cut -d= -f1 | sed 's/\.[0-9][0-9]*/[]/g' | sort -u`
  lists every path with array indices collapsed — 2-3% of the file's size.
- Input format is inferred for `.json`/`.yaml`/`.toml`; `.xml` and
  `.properties` need `-p xml` / `-p props`.
- Edit YAML with `yq -i '<expr>' <file>`, not Read plus Edit. It keeps
  comments and indentation that hand-editing breaks.
- Expressions apply to every document in a multi-document file. Narrow with
  `select(...)` when only one is meant to change.
- Re-read the changed region after an in-place edit.
