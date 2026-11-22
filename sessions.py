#!/usr/bin/env python3
"""读取 OMP 会话头部，生成侧边栏所需的本地索引。"""

import json
import os
from pathlib import Path
import sys


def last_appended_title(stream, current):
    """在同一已打开句柄上回读文件尾部，取最后一条 title 记录（omp 改名会追加带 previousTitle 的行）。"""
    try:
        stream.seek(0, os.SEEK_END)
        size = stream.tell()
        window = min(size, 64 * 1024)
        stream.seek(size - window)
        chunk = stream.read(window)
    except OSError:
        return current
    lines = chunk.split(b"\n")
    # 窗口不是从文件头开始时，第一段必然是被截断的行，丢掉。
    if window < size:
        lines = lines[1:]
    found = current
    for raw in lines:
        if b'"title"' not in raw:
            continue
        try:
            entry = json.loads(raw)
        except ValueError:
            continue
        if entry.get("type") == "title":
            found = entry.get("title") or found
    return found


def main():
    """扫描会话文件并输出标题、工作目录和最后修改时间。"""
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except (AttributeError, OSError):
        pass
    agent_dir = Path(os.environ.get("PI_CODING_AGENT_DIR", Path.home() / ".omp" / "agent"))
    sessions_dir = agent_dir / "sessions"
    if not sessions_dir.is_dir():
        raise FileNotFoundError(f"会话目录不存在: {sessions_dir}")

    rows = []
    for path in sessions_dir.glob("*/*.jsonl"):
        try:
            title = ""
            cwd = ""
            session_id = ""
            with path.open("rb") as stream:
                # title 通常在第 1 行，但 omp 改名时也可能追加一条带
                # previousTitle 的记录。这里扫到 session 头为止，取最后一条 title。
                for _ in range(12):
                    line = stream.readline(1024 * 1024)
                    if not line:
                        break
                    if not line.endswith(b"\n"):
                        if len(line) >= 1024 * 1024:
                            # 这一行超过 1MB，位置停在行中间。先把它剩余部分读完
                            # （跳过不解析），再继续找 session 头；
                            # 否则整个会话会因为一个读不全的行而消失。
                            while True:
                                rest = stream.readline(1024 * 1024)
                                if not rest or rest.endswith(b"\n"):
                                    break
                            continue
                        break
                    try:
                        entry = json.loads(line)
                    except ValueError:
                        continue
                    kind = entry.get("type")
                    if kind == "title":
                        title = entry.get("title") or title
                    elif kind == "session":
                        cwd = entry.get("cwd") or ""
                        session_id = entry.get("id") or ""
                        break
                # 首行不是 title 且追加记录在文件尾时，在同一句柄上回读最后 64KB 找最新 title。
                if session_id:
                    title = last_appended_title(stream, title)
            if not session_id:
                continue
            rows.append({"id": session_id, "title": title or "未命名会话", "cwd": cwd,
                         "path": str(path), "updated": path.stat().st_mtime})
        except (OSError, ValueError, TypeError, AttributeError, KeyError):
            continue
    rows.sort(key=lambda row: row["updated"], reverse=True)
    json.dump(rows, sys.stdout, ensure_ascii=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
