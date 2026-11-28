#!/usr/bin/env bash
set -euo pipefail
umask 077

exec python3 - "$@" <<'PYEOF'
import argparse
import base64
import json
import os
import re
import secrets
import sqlite3
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path
from typing import Any

SERVER_DIR = Path(os.environ.get("MC_SERVER_DIR", "/opt/hakimi-mc-server"))
DATA_DIR = SERVER_DIR / "data"
PLUGINS_DIR = DATA_DIR / "plugins"
SR_DIR = PLUGINS_DIR / "SkinsRestorer"
SR_SKINS_DIR = SR_DIR / "skins"
SR_PLAYERS_DIR = SR_DIR / "players"
SR_CONFIG_PATH = SR_DIR / "config.yml"
SR_JAR_PATH = PLUGINS_DIR / "SkinsRestorer.jar"
WHITELIST_PATH = DATA_DIR / "whitelist.json"
USERCACHE_PATH = DATA_DIR / "usercache.json"
LIBRELOGIN_DB = PLUGINS_DIR / "LibreLogin" / "user-data.db"
MC_CMD = str(SERVER_DIR / "mc-cmd.sh")

MC_UID = 10001
MC_GID = 10001
MAX_PNG_BYTES = 1024 * 1024
ALLOWED_PNG_DIMS = {(64, 64), (64, 32)}
SKIN_NAME_RE = re.compile(r"\A[A-Za-z0-9_-]{1,32}\Z")
USERNAME_RE = re.compile(r"\A[A-Za-z0-9_]{3,16}\Z")
MINESKIN_QUEUE_URL = "https://api.mineskin.org/v2/queue"
MINESKIN_SKINS_URL = "https://api.mineskin.org/v2/skins"
USER_AGENT = "hakimi-mc-skin/1.0"


def die(msg: str, code: int = 1) -> int:
    print(f"Error: {msg}", file=sys.stderr)
    return code


def is_mc_running() -> bool:
    res = subprocess.run(
        [
            "docker",
            "ps",
            "--filter",
            "name=^/hakimi-mc-server$",
            "--filter",
            "status=running",
            "-q",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    return res.returncode == 0 and bool(res.stdout.strip())


def run_mc_cmd_best_effort(cmd: str) -> tuple[bool, str]:
    if not is_mc_running():
        return False, "server_stopped"
    res = subprocess.run(
        [MC_CMD, cmd],
        capture_output=True,
        text=True,
        check=False,
    )
    out = (res.stdout or res.stderr or "").strip()
    return res.returncode == 0, out


def atomic_write_text(path: Path, content: str, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if os.geteuid() == 0:
        try:
            os.chown(path.parent, MC_UID, MC_GID)
        except OSError:
            pass
    tmp_path: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=str(path.parent),
            prefix=f".{path.name}.tmp.",
            delete=False,
        ) as fp:
            tmp_path = fp.name
            fp.write(content)
            fp.flush()
            os.fsync(fp.fileno())
        os.chmod(tmp_path, mode)
        if os.geteuid() == 0:
            os.chown(tmp_path, MC_UID, MC_GID)
        os.replace(tmp_path, str(path))
        tmp_path = None
    finally:
        if tmp_path and os.path.exists(tmp_path):
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


def validate_skin_name(name: str) -> str:
    if not SKIN_NAME_RE.fullmatch(name):
        raise ValueError(
            f"无效皮肤名 '{name}'：仅允许 1-32 位字母、数字、下划线或短横线。"
        )
    return name.lower()


def validate_username(name: str) -> str:
    if not USERNAME_RE.fullmatch(name):
        raise ValueError(
            f"无效玩家名 '{name}'：必须匹配 ^[A-Za-z0-9_]{{3,16}}$（3-16位字母、数字或下划线）。"
        )
    return name


def validate_png(png_path: Path) -> tuple[bytes, int, int]:
    if not png_path.is_file():
        raise FileNotFoundError(f"找不到皮肤文件：{png_path}")
    data = png_path.read_bytes()
    if len(data) < 24 or len(data) > MAX_PNG_BYTES:
        raise ValueError(
            f"PNG 文件大小异常（{len(data)} bytes），要求在 24 bytes ~ 1 MiB 之间。"
        )
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError("文件不是合法的 PNG 图片（缺少 PNG/IHDR 头）。")
    width, height = struct.unpack(">II", data[16:24])
    if (width, height) not in ALLOWED_PNG_DIMS:
        raise ValueError(
            f"不支持的皮肤尺寸 {width}x{height}：原版/SkinsRestorer 仅支持 64x64 或 64x32。"
        )
    return data, width, height


def read_mineskin_api_key() -> str:
    env_key = os.environ.get("MINESKIN_API_KEY", "").strip()
    if env_key:
        return env_key
    if SR_CONFIG_PATH.is_file():
        try:
            text = SR_CONFIG_PATH.read_text(encoding="utf-8")
            m = re.search(r"(?m)^\s*mineskinAPIKey:\s*['\"]?([^'\"\n#]+)['\"]?", text)
            if m:
                val = m.group(1).strip()
                if val and val.lower() not in {"key", "replace_with_your_api_key", "none"}:
                    return val
        except OSError:
            pass
    return ""


def http_json(
    url: str,
    *,
    method: str = "GET",
    data: bytes | None = None,
    headers: dict[str, str] | None = None,
    timeout: int = 30,
) -> tuple[int, dict[str, Any]]:
    req_headers = {"User-Agent": USER_AGENT, "Accept": "application/json"}
    if headers:
        req_headers.update(headers)
    req = urllib.request.Request(url, data=data, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return resp.status, json.loads(raw) if raw.strip() else {}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(body) if body.strip() else {}
        except json.JSONDecodeError:
            parsed = {"raw": body[:400]}
        return exc.code, parsed
    except urllib.error.URLError as exc:
        raise RuntimeError(f"网络请求失败（{url}）：{exc.reason}") from exc


def extract_mineskin_texture(payload: dict[str, Any]) -> tuple[str, str, str] | None:
    skin = payload.get("skin")
    if not isinstance(skin, dict):
        return None
    texture = skin.get("texture")
    if isinstance(texture, dict):
        tex_data = texture.get("data")
        if isinstance(tex_data, dict):
            value = str(tex_data.get("value") or "").strip()
            signature = str(tex_data.get("signature") or "").strip()
            if value and signature:
                variant = str(skin.get("variant") or "").strip().lower()
                return value, signature, variant
    return None


def encode_multipart_form(
    fields: dict[str, str],
    file_field: str,
    filename: str,
    file_bytes: bytes,
    content_type: str = "image/png",
) -> tuple[bytes, str]:
    boundary = f"----HakimiSkin{secrets.token_hex(12)}"
    parts: list[bytes] = []
    for k, v in fields.items():
        parts.append(
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="{k}"\r\n\r\n'
            f"{v}\r\n".encode("utf-8")
        )
    parts.append(
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="{file_field}"; filename="{filename}"\r\n'
        f"Content-Type: {content_type}\r\n\r\n".encode("utf-8")
    )
    parts.append(file_bytes)
    parts.append(f"\r\n--{boundary}--\r\n".encode("utf-8"))
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def _format_mineskin_errors(payload: dict[str, Any]) -> str:
    errs = payload.get("errors")
    if isinstance(errs, list) and errs:
        parts = []
        for item in errs:
            if isinstance(item, dict):
                parts.append(
                    f"{item.get('code', 'error')}: {item.get('message', '')}".strip(": ")
                )
            else:
                parts.append(str(item))
        return "; ".join(parts)
    if payload.get("message"):
        return str(payload["message"])
    return str(payload.get("raw") or payload)[:300]


def sign_skin_via_mineskin(
    *,
    png_bytes: bytes | None = None,
    filename: str = "skin.png",
    source_url: str | None = None,
    variant: str = "classic",
    visibility: str = "unlisted",
    max_wait_seconds: int = 75,
) -> tuple[str, str, str]:
    api_key = read_mineskin_api_key()
    auth_headers: dict[str, str] = {}
    if api_key:
        auth_headers["Authorization"] = f"Bearer {api_key}"

    if png_bytes is not None:
        body, ctype = encode_multipart_form(
            fields={"variant": variant, "visibility": visibility},
            file_field="file",
            filename=filename,
            file_bytes=png_bytes,
        )
        headers = {**auth_headers, "Content-Type": ctype}
    elif source_url:
        body = json.dumps(
            {"url": source_url, "variant": variant, "visibility": visibility}
        ).encode("utf-8")
        headers = {**auth_headers, "Content-Type": "application/json"}
    else:
        raise ValueError("必须提供 PNG 文件或皮肤图片 URL。")

    status, payload = http_json(
        MINESKIN_QUEUE_URL, method="POST", data=body, headers=headers, timeout=45
    )
    if status >= 400:
        raise RuntimeError(
            f"MineSkin 签名提交失败（HTTP {status}）：{_format_mineskin_errors(payload)}"
        )

    direct = extract_mineskin_texture(payload)
    if direct is not None:
        return direct

    job = payload.get("job")
    job_id = str(job.get("id") or "").strip() if isinstance(job, dict) else ""
    if not job_id:
        raise RuntimeError(
            f"MineSkin 未返回皮肤纹理或排队任务 ID（HTTP {status}）：{str(payload)[:300]}"
        )

    deadline = time.monotonic() + max_wait_seconds
    poll_interval = 2.0
    rate_limit = payload.get("rateLimit")
    if isinstance(rate_limit, dict):
        nxt = rate_limit.get("next")
        if isinstance(nxt, dict) and isinstance(nxt.get("relative"), (int, float)):
            poll_interval = max(1.0, min(5.0, float(nxt["relative"]) / 1000.0))

    while time.monotonic() < deadline:
        time.sleep(poll_interval)
        p_status, p_payload = http_json(
            f"{MINESKIN_QUEUE_URL}/{urllib.parse.quote(job_id)}",
            method="GET",
            headers=auth_headers,
            timeout=30,
        )
        if p_status >= 400:
            raise RuntimeError(
                f"MineSkin 轮询失败（HTTP {p_status}）：{_format_mineskin_errors(p_payload)}"
            )
        tex = extract_mineskin_texture(p_payload)
        if tex is not None:
            return tex

        p_job = p_payload.get("job")
        if isinstance(p_job, dict):
            j_status = str(p_job.get("status") or "").lower()
            if j_status == "failed":
                raise RuntimeError(
                    f"MineSkin 生成任务失败：{_format_mineskin_errors(p_payload)}"
                )
            if j_status == "completed":
                skin_ref = p_job.get("result") or (
                    p_payload.get("skin", {}).get("uuid")
                    if isinstance(p_payload.get("skin"), dict)
                    else None
                )
                if skin_ref:
                    s_status, s_payload = http_json(
                        f"{MINESKIN_SKINS_URL}/{urllib.parse.quote(str(skin_ref))}",
                        method="GET",
                        headers=auth_headers,
                        timeout=30,
                    )
                    if s_status < 400:
                        tex2 = extract_mineskin_texture(s_payload)
                        if tex2 is not None:
                            return tex2
                raise RuntimeError(
                    f"MineSkin 任务已完成但缺少纹理签名：{str(p_payload)[:300]}"
                )
        poll_interval = min(4.0, poll_interval + 0.5)

    raise RuntimeError(f"等待 MineSkin 签名超时（>{max_wait_seconds}s，job={job_id}）。")


def lookup_mojang_uuid(username: str) -> tuple[str, str]:
    url = f"https://api.mojang.com/users/profiles/minecraft/{urllib.parse.quote(username)}"
    status, payload = http_json(url, method="GET", timeout=15)
    if status == 404 or status == 204 or not payload.get("id"):
        raise LookupError(f"未在 Mojang 找到正版玩家 '{username}'。")
    if status >= 400:
        raise RuntimeError(f"Mojang API 查询失败（HTTP {status}）：{payload}")
    canonical_uuid = str(uuid.UUID(str(payload["id"])))
    canonical_name = str(payload.get("name") or username)
    return canonical_uuid, canonical_name


def load_known_players() -> dict[str, tuple[str, str]]:
    """Return lowercase_name -> (uuid_str, canonical_name)."""
    mapping: dict[str, tuple[str, str]] = {}

    if USERCACHE_PATH.is_file():
        try:
            for item in json.loads(USERCACHE_PATH.read_text(encoding="utf-8") or "[]"):
                name = str(item.get("name") or "").strip()
                raw_uuid = str(item.get("uuid") or "").strip()
                if name and raw_uuid:
                    mapping[name.lower()] = (str(uuid.UUID(raw_uuid)), name)
        except Exception:
            pass

    if WHITELIST_PATH.is_file():
        try:
            for item in json.loads(WHITELIST_PATH.read_text(encoding="utf-8") or "[]"):
                name = str(item.get("name") or "").strip()
                raw_uuid = str(item.get("uuid") or "").strip()
                if name and raw_uuid:
                    mapping[name.lower()] = (str(uuid.UUID(raw_uuid)), name)
        except Exception:
            pass

    if LIBRELOGIN_DB.is_file():
        try:
            conn = sqlite3.connect(f"file:{LIBRELOGIN_DB}?mode=ro", uri=True)
            try:
                rows = conn.execute(
                    "SELECT uuid, last_nickname FROM librepremium_data "
                    "WHERE uuid IS NOT NULL AND last_nickname IS NOT NULL"
                ).fetchall()
                for raw_uuid, nick in rows:
                    name = str(nick).strip()
                    if name and raw_uuid:
                        mapping[name.lower()] = (str(uuid.UUID(str(raw_uuid))), name)
            finally:
                conn.close()
        except Exception:
            pass

    return mapping


def resolve_player(player_arg: str, explicit_uuid: str | None = None) -> tuple[str, str]:
    if explicit_uuid:
        return str(uuid.UUID(explicit_uuid.strip())), player_arg
    validate_username(player_arg)
    known = load_known_players()
    hit = known.get(player_arg.lower())
    if hit is not None:
        return hit
    raise LookupError(
        f"未在 LibreLogin / whitelist.json / usercache.json 中找到玩家 '{player_arg}'。"
        "请先用 mc-friend.sh 加入白名单，或通过 --uuid 指定精确 UUID。"
    )


def decode_texture_summary(value_b64: str) -> tuple[str, str]:
    try:
        decoded = json.loads(base64.b64decode(value_b64).decode("utf-8"))
        skin = decoded.get("textures", {}).get("SKIN", {})
        url = str(skin.get("url") or "?")
        model = str(skin.get("metadata", {}).get("model") or "classic")
        return url, model
    except Exception:
        return "?", "?"


def write_custom_skin(skin_name: str, value: str, signature: str) -> Path:
    normalized = validate_skin_name(skin_name)
    out_path = SR_SKINS_DIR / f"{normalized}.customskin"
    payload = {
        "skinName": normalized,
        "value": value,
        "signature": signature,
        "dataVersion": 1,
    }
    atomic_write_text(out_path, json.dumps(payload, separators=(",", ":")))
    return out_path


def write_player_skin(
    player_uuid: str,
    skin_identifier: dict[str, Any] | None,
) -> Path:
    out_path = SR_PLAYERS_DIR / f"{player_uuid}.player"
    existing: dict[str, Any] = {}
    if out_path.is_file():
        try:
            existing = json.loads(out_path.read_text(encoding="utf-8") or "{}")
        except Exception:
            existing = {}

    data: dict[str, Any] = {
        "uniqueId": player_uuid,
        "offlineModeWarningDismissed": bool(
            existing.get("offlineModeWarningDismissed", False)
        ),
        "history": existing.get("history")
        if isinstance(existing.get("history"), list)
        else [],
        "favourites": existing.get("favourites")
        if isinstance(existing.get("favourites"), list)
        else [],
        "dataVersion": 2,
    }
    if skin_identifier is not None:
        data["skinIdentifier"] = skin_identifier

    atomic_write_text(out_path, json.dumps(data, separators=(",", ":")))
    return out_path


def bind_player_skin(
    player_name: str,
    target: str,
    *,
    skin_type: str = "auto",
    variant: str = "classic",
    explicit_uuid: str | None = None,
) -> None:
    player_uuid, canonical_name = resolve_player(player_name, explicit_uuid=explicit_uuid)

    resolved_type = skin_type.lower()
    if resolved_type == "auto":
        if re.match(r"^https?://", target, re.IGNORECASE):
            resolved_type = "url"
        elif (SR_SKINS_DIR / f"{target.lower()}.customskin").is_file():
            resolved_type = "custom"
        else:
            resolved_type = "player"

    if resolved_type == "custom":
        cname = validate_skin_name(target)
        custom_path = SR_SKINS_DIR / f"{cname}.customskin"
        if not custom_path.is_file():
            raise FileNotFoundError(
                f"自定义皮肤 '{cname}' 不存在（{custom_path}）。"
                "请先用 upload 或 create-url 注册。"
            )
        ident: dict[str, Any] = {"identifier": cname, "type": "CUSTOM"}
        desc = f"CUSTOM:{cname}"
    elif resolved_type == "url":
        parsed = urllib.parse.urlparse(target)
        if parsed.scheme not in {"http", "https"} or not parsed.netloc:
            raise ValueError(f"无效皮肤 URL：{target}")
        sv = variant.upper()
        if sv not in {"CLASSIC", "SLIM"}:
            raise ValueError(f"无效模型变体：{variant}（仅支持 classic / slim）")
        ident = {"identifier": target, "skinVariant": sv, "type": "URL"}
        desc = f"URL:{target} ({sv.lower()})"
    elif resolved_type == "player":
        validate_username(target)
        mojang_uuid, mojang_name = lookup_mojang_uuid(target)
        ident = {"identifier": mojang_uuid, "type": "PLAYER"}
        desc = f"PLAYER:{mojang_name} ({mojang_uuid})"
    else:
        raise ValueError(f"不支持的皮肤类型：{skin_type}")

    out_path = write_player_skin(player_uuid, ident)
    applied_live, _ = run_mc_cmd_best_effort(f"sr applyskin {canonical_name}")
    live_note = (
        "已通知在线服刷新（若玩家当前在线即刻生效，离线则下次进服生效）"
        if applied_live
        else "服务端当前未启动，将在下次开服且玩家进服时自动生效"
    )
    print(f"已绑定玩家皮肤：{canonical_name} ({player_uuid}) -> {desc}")
    print(f"配置文件：{out_path}")
    print(f"生效状态：{live_note}")


def cmd_upload(args: argparse.Namespace) -> int:
    skin_name = validate_skin_name(args.name)
    png_path = Path(args.png).expanduser()
    png_bytes, width, height = validate_png(png_path)
    visibility = "public" if args.public else "unlisted"

    print(
        f"正在通过 MineSkin 签名皮肤 '{skin_name}' "
        f"({png_path.name}, {width}x{height}, variant={args.variant}, visibility={visibility})..."
    )
    value, signature, resolved_variant = sign_skin_via_mineskin(
        png_bytes=png_bytes,
        filename=f"{skin_name}.png",
        variant=args.variant,
        visibility=visibility,
    )
    out_path = write_custom_skin(skin_name, value, signature)
    tex_url, model = decode_texture_summary(value)
    print(f"已注册自定义皮肤：{skin_name} ({out_path})")
    print(f"模型变体：{resolved_variant or model} | 纹理：{tex_url}")

    if args.apply:
        bind_player_skin(
            args.apply,
            skin_name,
            skin_type="custom",
            explicit_uuid=args.uuid,
        )
    else:
        print(f"游戏内使用：/skin set {skin_name}（或管理员执行 mc-skin.sh set <玩家> {skin_name}）")
    return 0


def cmd_create_url(args: argparse.Namespace) -> int:
    skin_name = validate_skin_name(args.name)
    parsed = urllib.parse.urlparse(args.url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return die(f"无效图片 URL：{args.url}")
    visibility = "public" if args.public else "unlisted"

    print(
        f"正在通过 MineSkin 拉取并签名皮肤 '{skin_name}' "
        f"(variant={args.variant}, visibility={visibility})..."
    )
    value, signature, resolved_variant = sign_skin_via_mineskin(
        source_url=args.url,
        variant=args.variant,
        visibility=visibility,
    )
    out_path = write_custom_skin(skin_name, value, signature)
    tex_url, model = decode_texture_summary(value)
    print(f"已注册自定义皮肤：{skin_name} ({out_path})")
    print(f"模型变体：{resolved_variant or model} | 纹理：{tex_url}")

    if args.apply:
        bind_player_skin(
            args.apply,
            skin_name,
            skin_type="custom",
            explicit_uuid=args.uuid,
        )
    else:
        print(f"游戏内使用：/skin set {skin_name}（或管理员执行 mc-skin.sh set <玩家> {skin_name}）")
    return 0


def cmd_set(args: argparse.Namespace) -> int:
    bind_player_skin(
        args.player,
        args.skin,
        skin_type=args.type,
        variant=args.variant,
        explicit_uuid=args.uuid,
    )
    return 0


def cmd_clear(args: argparse.Namespace) -> int:
    player_uuid, canonical_name = resolve_player(args.player, explicit_uuid=args.uuid)
    out_path = SR_PLAYERS_DIR / f"{player_uuid}.player"
    if out_path.is_file():
        write_player_skin(player_uuid, None)
    applied_live, _ = run_mc_cmd_best_effort(f"skin clear {canonical_name}")
    live_note = (
        "已通知在线服清除"
        if applied_live
        else "服务端当前未启动，下次进服将恢复默认皮肤"
    )
    print(f"已清除玩家自定义绑定：{canonical_name} ({player_uuid}) — {live_note}")
    return 0


def cmd_delete(args: argparse.Namespace) -> int:
    skin_name = validate_skin_name(args.name)
    path = SR_SKINS_DIR / f"{skin_name}.customskin"
    if not path.is_file():
        return die(f"自定义皮肤 '{skin_name}' 不存在。")

    bound_players: list[str] = []
    uuid_to_name = {u: n for _, (u, n) in load_known_players().items()}
    if SR_PLAYERS_DIR.is_dir():
        for pfile in sorted(SR_PLAYERS_DIR.glob("*.player")):
            try:
                pdata = json.loads(pfile.read_text(encoding="utf-8") or "{}")
                ident = pdata.get("skinIdentifier")
                if (
                    isinstance(ident, dict)
                    and str(ident.get("type") or "").upper() == "CUSTOM"
                    and str(ident.get("identifier") or "").lower() == skin_name
                ):
                    uid = str(pdata.get("uniqueId") or pfile.stem)
                    bound_players.append(uuid_to_name.get(uid, uid))
            except Exception:
                continue

    path.unlink()
    run_mc_cmd_best_effort(f"sr drop skin {skin_name}")
    print(f"已删除自定义皮肤：{skin_name}")
    if bound_players:
        print(
            f"提示：以下玩家仍绑定着该皮肤名，建议同步 clear 或重设：{', '.join(bound_players)}"
        )
    return 0


def cmd_list(_args: argparse.Namespace) -> int:
    print("=== Custom Skins (SkinsRestorer/skins/*.customskin) ===")
    customs = sorted(SR_SKINS_DIR.glob("*.customskin")) if SR_SKINS_DIR.is_dir() else []
    if not customs:
        print("  (empty)")
    else:
        for path in customs:
            try:
                data = json.loads(path.read_text(encoding="utf-8") or "{}")
                sname = str(data.get("skinName") or path.stem)
                url, model = decode_texture_summary(str(data.get("value") or ""))
                print(f"  - {sname} [model={model}] {url}")
            except Exception as exc:
                print(f"  - {path.stem} (parse error: {exc})")

    print("=== Player Bindings (SkinsRestorer/players/*.player) ===")
    uuid_to_name = {u: n for _, (u, n) in load_known_players().items()}
    players = sorted(SR_PLAYERS_DIR.glob("*.player")) if SR_PLAYERS_DIR.is_dir() else []
    shown = 0
    for path in players:
        try:
            data = json.loads(path.read_text(encoding="utf-8") or "{}")
            uid = str(data.get("uniqueId") or path.stem)
            name = uuid_to_name.get(uid, "(unknown)")
            ident = data.get("skinIdentifier")
            if isinstance(ident, dict) and ident.get("identifier"):
                stype = ident.get("type", "?")
                sid = ident.get("identifier", "?")
                sv = ident.get("skinVariant")
                sv_part = f" variant={sv}" if sv else ""
                print(f"  - {name} ({uid}) -> {stype}:{sid}{sv_part}")
                shown += 1
        except Exception as exc:
            print(f"  - {path.stem} (parse error: {exc})")
            shown += 1
    if shown == 0:
        print("  (no explicit player skin bindings)")
    return 0


def cmd_status(_args: argparse.Namespace) -> int:
    print(f"SkinsRestorer JAR : {'installed' if SR_JAR_PATH.is_file() else 'MISSING'} ({SR_JAR_PATH})")
    print(f"Paper Container   : {'running' if is_mc_running() else 'stopped'}")
    custom_cnt = len(list(SR_SKINS_DIR.glob("*.customskin"))) if SR_SKINS_DIR.is_dir() else 0
    player_cnt = len(list(SR_PLAYERS_DIR.glob("*.player"))) if SR_PLAYERS_DIR.is_dir() else 0
    print(f"Stored Skins      : {custom_cnt} custom skins, {player_cnt} player files")
    print(f"MineSkin API Key  : {'configured' if read_mineskin_api_key() else 'anonymous (free)'}")
    if SR_CONFIG_PATH.is_file():
        text = SR_CONFIG_PATH.read_text(encoding="utf-8")
        for key in ("locale", "forceDefaultPermissions", "skinChangeCooldown", "mineskinSecretSkins"):
            m = re.search(rf"(?m)^\s*{key}:\s*(.+)$", text)
            if m:
                print(f"Config {key:23s}: {m.group(1).strip()}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="mc-skin",
        description="Manage SkinsRestorer custom PNG skins and player skin bindings for Hakimi MC server.",
    )
    sub = parser.add_subparsers(dest="command", metavar="<command>")

    p_up = sub.add_parser(
        "upload",
        help="Upload a local 64x64 (or 64x32) PNG skin via MineSkin and register as a custom skin",
    )
    p_up.add_argument("name", help="Custom skin name (1-32 chars: A-Za-z0-9_-)")
    p_up.add_argument("png", help="Path to local PNG skin file")
    p_up.add_argument(
        "--variant",
        choices=["classic", "slim"],
        default="slim",
        help="Skin arm model: slim (Alex 3px, default) or classic (Steve 4px)",
    )
    p_up.add_argument(
        "--public",
        action="store_true",
        help="List skin publicly on MineSkin gallery (default: unlisted)",
    )
    p_up.add_argument("--apply", metavar="PLAYER", help="Also bind this skin to a player immediately")
    p_up.add_argument("--uuid", help="Explicit player UUID when using --apply")

    p_url = sub.add_parser(
        "create-url",
        help="Fetch an image URL via MineSkin and register as a permanent custom skin",
    )
    p_url.add_argument("name", help="Custom skin name (1-32 chars: A-Za-z0-9_-)")
    p_url.add_argument("url", help="Direct HTTPS/HTTP PNG skin URL")
    p_url.add_argument(
        "--variant",
        choices=["classic", "slim"],
        default="slim",
        help="Skin arm model: slim (Alex 3px, default) or classic (Steve 4px)",
    )
    p_url.add_argument(
        "--public",
        action="store_true",
        help="List skin publicly on MineSkin gallery (default: unlisted)",
    )
    p_url.add_argument("--apply", metavar="PLAYER", help="Also bind this skin to a player immediately")
    p_url.add_argument("--uuid", help="Explicit player UUID when using --apply")

    p_set = sub.add_parser(
        "set",
        help="Bind a custom skin, Mojang username, or URL skin to a player (works online or offline)",
    )
    p_set.add_argument("player", help="Target player username on this server")
    p_set.add_argument("skin", help="Custom skin name, Mojang username, or direct image URL")
    p_set.add_argument(
        "--type",
        choices=["auto", "custom", "player", "url"],
        default="auto",
        help="Skin source type (default: auto-detect)",
    )
    p_set.add_argument(
        "--variant",
        choices=["classic", "slim"],
        default="slim",
        help="Variant when binding a URL skin (default: slim)",
    )
    p_set.add_argument("--uuid", help="Explicit target player UUID")

    p_clr = sub.add_parser("clear", help="Clear a player's explicit skin binding")
    p_clr.add_argument("player", help="Target player username")
    p_clr.add_argument("--uuid", help="Explicit target player UUID")

    p_del = sub.add_parser("delete", help="Delete a registered custom skin")
    p_del.add_argument("name", help="Custom skin name to remove")

    sub.add_parser("list", help="List registered custom skins and bound player skins")
    sub.add_parser("status", help="Show SkinsRestorer installation and configuration status")
    return parser


def main() -> int:
    parser = build_parser()
    if len(sys.argv) <= 1:
        parser.print_help(sys.stderr)
        return 1
    args = parser.parse_args()
    handlers = {
        "upload": cmd_upload,
        "create-url": cmd_create_url,
        "set": cmd_set,
        "clear": cmd_clear,
        "delete": cmd_delete,
        "list": cmd_list,
        "status": cmd_status,
    }
    fn = handlers.get(args.command)
    if fn is None:
        parser.print_help(sys.stderr)
        return 1
    return fn(args)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(0)
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)
PYEOF
