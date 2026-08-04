#!/usr/bin/env python3
import pathlib
import re
import sys


def code_part(line: str) -> str:
    quote = None
    escaped = False
    out: list[str] = []
    for char in line:
        if escaped:
            out.append(char)
            escaped = False
            continue
        if char == "\\" and quote is not None:
            out.append(char)
            escaped = True
            continue
        if quote is not None:
            out.append(char)
            if char == quote:
                quote = None
            continue
        if char in {'"', "'", "`"}:
            quote = char
            out.append(char)
            continue
        if char == "#":
            break
        out.append(char)
    return "".join(out).rstrip()


def structural_delta(line: str) -> int:
    code = code_part(line)
    opening = 1 if re.search(r"\{\s*$", code) else 0
    closing = 1 if re.match(r"^\s*}", code) else 0
    return opening - closing


def opening_header(line: str) -> str | None:
    code = code_part(line)
    if not re.search(r"\{\s*$", code):
        return None
    return code.rsplit("{", 1)[0].strip()


def header_tokens(header: str) -> list[str]:
    return [item for item in re.split(r"[\s,]+", header) if item]


def is_selfsteal_body(body: str) -> bool:
    return bool(
        re.search(r"(?m)^\s*bind\s+unix/", body)
        and re.search(r"(?m)^\s*file_server(?:\s|$)", body)
    )


def detect(path: pathlib.Path) -> str | None:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    depth = 0
    blocks: list[tuple[str, list[str], str]] = []

    for index, line in enumerate(lines):
        before = depth
        delta = structural_delta(line)
        header = opening_header(line)
        if before == 0 and delta > 0 and header:
            running = before + delta
            end_index = None
            for cursor in range(index + 1, len(lines)):
                running += structural_delta(lines[cursor])
                if running == 0:
                    end_index = cursor
                    break
            if end_index is not None:
                body = "".join(lines[index + 1:end_index])
                blocks.append((header, header_tokens(header), body))
        depth += delta

    exact: list[str] = []
    generic: list[str] = []
    for header, tokens, body in blocks:
        if not is_selfsteal_body(body):
            continue
        if any(token in {
            "https://{$SELF_STEAL_DOMAIN}",
            "{$SELF_STEAL_DOMAIN}",
        } for token in tokens):
            exact.append(header)
            continue
        if any(re.fullmatch(
            r"(?:https://)?\{\$[A-Za-z_][A-Za-z0-9_]*\}", token
        ) for token in tokens):
            generic.append(header)

    if len(exact) == 1:
        return exact[0]
    if not exact and len(generic) == 1:
        return generic[0]
    return None


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: detect-selfsteal-site.py CADDYFILE", file=sys.stderr)
        return 2
    path = pathlib.Path(sys.argv[1])
    if not path.is_file():
        print(f"Caddyfile not found: {path}", file=sys.stderr)
        return 2
    result = detect(path)
    if result:
        print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
