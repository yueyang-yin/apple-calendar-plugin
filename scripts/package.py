#!/usr/bin/env python3
"""Build reproducible standalone-plugin and local-marketplace release archives."""

import hashlib
import json
from pathlib import Path
import stat
import zipfile


ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / "plugins/apple-calendar"
DIST = ROOT / "dist"
TIMESTAMP = (2026, 1, 1, 0, 0, 0)


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def files_under(directory):
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise ValueError(f"Symlinks are not supported: {path}")
        if path.is_file() and path.name != ".DS_Store" and "__pycache__" not in path.parts:
            yield path


def write_archive(destination, entries):
    with zipfile.ZipFile(destination, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for path, name in sorted(entries, key=lambda entry: entry[1]):
            info = zipfile.ZipInfo(name, TIMESTAMP)
            info.create_system = 3
            mode = 0o755 if path.stat().st_mode & 0o111 else 0o644
            info.external_attr = (stat.S_IFREG | mode) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, path.read_bytes(), compresslevel=9)
    with zipfile.ZipFile(destination) as archive:
        if archive.testzip() is not None:
            raise ValueError(f"Corrupt archive: {destination}")


def main():
    manifest = read_json(PLUGIN / "plugin.json")
    compatibility = read_json(PLUGIN / ".codex-plugin/plugin.json")
    for field in ("name", "version", "description", "author"):
        if manifest[field] != compatibility[field]:
            raise ValueError(f"Plugin manifests disagree on {field}")
    if manifest["extensions"]["com.openai"]["interface"] != compatibility["interface"]:
        raise ValueError("Plugin interface metadata differs between manifests")
    portable_mcp = read_json(PLUGIN / "mcp.json")["mcpServers"]
    legacy_mcp = read_json(PLUGIN / ".mcp.json")["mcpServers"]
    if {name: {key: value for key, value in server.items() if key != "type"}
            for name, server in portable_mcp.items()} != legacy_mcp:
        raise ValueError("MCP launch configurations differ between formats")
    marketplace = read_json(ROOT / ".agents/plugins/marketplace.json")
    if len(marketplace["plugins"]) != 1:
        raise ValueError("Expected exactly one marketplace plugin")
    entry = marketplace["plugins"][0]
    if entry["name"] != manifest["name"] or entry["source"] != {
        "source": "local", "path": "./plugins/apple-calendar"
    }:
        raise ValueError("Marketplace does not point to the packaged plugin")

    DIST.mkdir(exist_ok=True)
    version = manifest["version"]
    plugin_files = list(files_under(PLUGIN))
    standalone = DIST / f"Apple-Calendar-{version}.zip"
    write_archive(standalone, [(path, f"apple-calendar/{path.relative_to(PLUGIN).as_posix()}")
                               for path in plugin_files])
    marketplace_files = plugin_files + list(files_under(ROOT / ".agents")) + [
        ROOT / "README.md", ROOT / ".gitignore", Path(__file__).resolve(),
        ROOT / f"docs/releases/{version}.md",
    ]
    bundled = DIST / f"Apple-Calendar-Marketplace-{version}.zip"
    write_archive(bundled, [(path, f"apple-calendar-marketplace/{path.relative_to(ROOT).as_posix()}")
                            for path in marketplace_files])
    checksums = []
    for path in (standalone, bundled):
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        checksums.append(f"{digest}  {path.name}\n")
        print(f"{path.name}: {path.stat().st_size} bytes, SHA-256 {digest}")
    (DIST / "SHA256SUMS.txt").write_text("".join(checksums), encoding="utf-8")


if __name__ == "__main__":
    main()
