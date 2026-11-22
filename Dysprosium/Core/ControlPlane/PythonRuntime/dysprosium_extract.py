"""Dysprosium Control Plane Extractor (Library-Mode yt-dlp).

Executes purely in metadata/manifest resolution mode (`download=False`) without
mutating global process state (`sys.argv` or `os.chdir`), emitting a JSON
contract for Dysprosium's native Swift HTTP Range & HLS Data Plane.
"""

import json
import os
import urllib.parse


def _select_best_tracks(info):
    requested = info.get("requested_formats")
    if isinstance(requested, list) and len(requested) >= 2:
        tracks = []
        for stream in requested:
            url = str(stream.get("url") or "").strip()
            if not url:
                continue
            vcodec = str(stream.get("vcodec") or "none")
            acodec = str(stream.get("acodec") or "none")
            protocol = str(stream.get("protocol") or "").lower()
            role = "videoOnly" if vcodec != "none" and acodec == "none" else "audioOnly"
            tracks.append({
                "id": str(stream.get("format_id") or role),
                "role": role,
                "remoteURL": url,
                "headers": dict(stream.get("http_headers") or info.get("http_headers") or {}),
                "expectedBytes": stream.get("filesize") or stream.get("filesize_approx"),
                "supportsByteRanges": "m3u8" not in protocol and "dash_frag" not in protocol,
                "isHLSManifest": "m3u8" in protocol,
                "fileExtension": str(stream.get("ext") or ("mp4" if role == "videoOnly" else "m4a")),
            })
        if tracks:
            return tracks, len(tracks) > 1

    direct_url = str(info.get("url") or "").strip()
    protocol = str(info.get("protocol") or "").lower()
    ext = str(info.get("ext") or "mp4")
    if direct_url:
        return [{
            "id": str(info.get("format_id") or "primary"),
            "role": "primary",
            "remoteURL": direct_url,
            "headers": dict(info.get("http_headers") or {}),
            "expectedBytes": info.get("filesize") or info.get("filesize_approx"),
            "supportsByteRanges": "m3u8" not in protocol,
            "isHLSManifest": "m3u8" in protocol or direct_url.lower().endswith(".m3u8"),
            "fileExtension": ext,
        }], False
    return [], False


def resolve_url(url_text, cookie_file_path=""):
    try:
        import yt_dlp
    except Exception as exc:
        return json.dumps({
            "ok": False,
            "error": f"yt-dlp package unavailable in embedded runtime: {exc}",
        })

    cache_dir = os.environ.get("DYSPROSIUM_CACHE_DIR", "").strip()
    opts = {
        "quiet": True,
        "no_warnings": True,
        "skip_download": True,
        "noplaylist": True,
        "nocheckcertificate": True,
        "format": "bv*[ext=mp4]+ba[ext=m4a]/bv*+ba/b",
        "format_sort": ["vcodec:h264", "acodec:aac", "res", "fps"],
    }
    if cache_dir:
        opts["cachedir"] = cache_dir
    if cookie_file_path and os.path.isfile(cookie_file_path):
        opts["cookiefile"] = cookie_file_path

    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(str(url_text).strip(), download=False) or {}
            tracks, requires_mux = _select_best_tracks(info)
            if not tracks:
                return json.dumps({"ok": False, "error": "Extractor returned no playable media streams."})

            title = str(info.get("title") or "Media").strip()
            safe_stem = "".join(ch if ch not in '/\\:*?"<>|' else "_" for ch in title)[:140].strip() or "media"
            parsed_host = (urllib.parse.urlparse(url_text).hostname or "media").removeprefix("www.")
            out_ext = "mp4" if requires_mux else tracks[0]["fileExtension"]

            return json.dumps({
                "ok": True,
                "plan": {
                    "sourceURL": url_text,
                    "title": title,
                    "siteDomain": parsed_host,
                    "kind": "HLS Stream" if tracks[0]["isHLSManifest"] else "yt-dlp Media",
                    "tracks": tracks,
                    "outputFilename": f"{safe_stem}.{out_ext}",
                    "requiresMuxing": requires_mux,
                    "etag": None,
                    "lastModified": None,
                },
            })
    except Exception as exc:
        return json.dumps({"ok": False, "error": str(exc)})
