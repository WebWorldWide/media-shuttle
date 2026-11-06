"""Camera ingest and erase rules shared by the GTK interface and safety tests."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import stat
import tempfile
import time
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Callable


KINDS = {
    "JPEG": set("jpg jpeg jpe".split()),
    "RAW": set("arw sr2 srf dng raw cr2 cr3 crw nef nrw raf orf rw2 rwl pef ptx srw x3f 3fr fff iiq cap eip mef mos mrw erf dcr kdc k25 gpr ari".split()),
    "OTHER": set("heif heic hif avif jxl tif tiff png bmp gif webp jp2 j2k psd".split()),
    "VIDEO": set("mp4 m4v mov mxf braw r3d mts m2ts m2t ts mod tod avi mkv webm wmv asf mpg mpeg m2v vob 3gp 3g2 insv lrv dv".split()),
}
FOLDERS = {"JPEG": "Photos/JPEGs", "RAW": "Photos/RAWs", "OTHER": "Photos/Other", "VIDEO": "Videos"}
DISPOSABLE = set("thm ctg cpi mpl bdm bdmv clpi mpls inp ind int tdt tid modd moff bnp pmp xml xmp sec info mdt osd mtd pck fpr set sav idx map tmp bup ifo".split())
DISPOSABLE_NAMES = {".ds_store", "thumbs.db", "desktop.ini", "icon\r", "autorun.inf"}
PROTECTED_ROOTS = {".fseventsd", ".spotlight-v100", ".trashes", ".temporaryitems", ".documentrevisions-v100", "$recycle.bin", "system volume information", ".trash-1000", "lost+found"}
CAMERA_DIRS = {"DCIM", "M4ROOT", "PRIVATE"}
CHUNK = 1024 * 1024
RESERVE = 1024 * 1024 * 1024


class ShuttleError(Exception):
    pass


class Cancelled(ShuttleError):
    pass


@dataclass(frozen=True)
class Card:
    root: Path
    label: str
    device: int
    mount_root: bool
    removable: bool
    volume_id: str
    drive_type: str

    @property
    def allows_erase(self) -> bool:
        return self.mount_root and self.removable and any((self.root / name).is_dir() for name in CAMERA_DIRS)


@dataclass(frozen=True)
class Media:
    path: Path
    kind: str
    size: int
    mtime_ns: int


@dataclass
class Scan:
    media: list[Media] = field(default_factory=list)
    unknown: list[Path] = field(default_factory=list)

    @property
    def counts(self) -> dict[str, int]:
        return {kind: sum(item.kind == kind for item in self.media) for kind in KINDS}


def _mounts() -> dict[Path, str]:
    result = {}
    try:
        for line in Path("/proc/self/mountinfo").read_text().splitlines():
            before, after = line.split(" - ", 1)
            root = before.split()[4]
            root = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), root)
            result[Path(root)] = after.split()[1]
    except (OSError, ValueError, IndexError):
        pass
    return result


def _removable(device: int) -> bool:
    major, minor = os.major(device), os.minor(device)
    sys_path = Path(f"/sys/dev/block/{major}:{minor}")
    try:
        current = sys_path.resolve(strict=True)
        for directory in (current, *current.parents):
            marker = directory / "removable"
            if marker.is_file():
                return marker.read_text().strip() == "1"
    except OSError:
        pass
    return False


def card_at(path: Path) -> Card:
    root = Path(path).expanduser().resolve(strict=True)
    if root == Path("/") or not root.is_dir():
        raise ShuttleError("Choose a camera card or folder, not the filesystem root.")
    st = root.stat()
    mount = root in _mounts()
    removable = _removable(st.st_dev) if mount else False
    drive_type = "Removable media" if removable else "Selected volume" if mount else "Selected folder"
    return Card(root, root.name, st.st_dev, mount, removable, f"{st.st_dev}:{root}", drive_type)


def candidates(destination: Path) -> list[Card]:
    found = []
    for mount in _mounts():
        if mount == Path("/") or not any((mount / name).is_dir() for name in CAMERA_DIRS):
            continue
        try:
            card = card_at(mount)
            if not _inside(destination, card.root):
                found.append(card)
        except (OSError, ShuttleError):
            continue
    return sorted(found, key=lambda card: card.label.casefold())


def classify(path: Path) -> str | None:
    if path.name.startswith("._"):
        return None
    extension = path.suffix.lower().lstrip(".")
    return next((kind for kind, extensions in KINDS.items() if extension in extensions), None)


def disposable(path: Path) -> bool:
    return (path.name.startswith("._") or path.name.casefold() in DISPOSABLE_NAMES or
            path.suffix.lower().lstrip(".") in DISPOSABLE)


def _inside(child: Path, parent: Path) -> bool:
    return child == parent or parent in child.parents


def scan_card(card: Card) -> Scan:
    result = Scan()
    root = card.root
    root_stat = root.lstat()
    if not stat.S_ISDIR(root_stat.st_mode) or root_stat.st_dev != card.device:
        raise ShuttleError("Card changed or was disconnected. Scan again.")
    if card.mount_root and root not in _mounts():
        raise ShuttleError("Card volume was unmounted. Scan again.")

    def walk(folder: Path) -> None:
        with os.scandir(folder) as entries:
            for entry in entries:
                path = Path(entry.path)
                if folder == root and entry.name.casefold() in PROTECTED_ROOTS:
                    continue
                st = entry.stat(follow_symlinks=False)
                if st.st_dev != card.device:
                    result.unknown.append(path)
                elif stat.S_ISLNK(st.st_mode):
                    result.unknown.append(path)
                elif stat.S_ISDIR(st.st_mode):
                    walk(path)
                elif stat.S_ISREG(st.st_mode):
                    kind = classify(path)
                    if kind:
                        result.media.append(Media(path, kind, st.st_size, st.st_mtime_ns))
                    elif not disposable(path):
                        result.unknown.append(path)
                else:
                    result.unknown.append(path)

    walk(root)
    result.media.sort(key=lambda item: str(item.path).casefold())
    result.unknown.sort(key=lambda path: str(path).casefold())
    return result


def _hash(path: Path, cancelled: Callable[[], bool] = lambda: False) -> str:
    digest = hashlib.sha256()
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        os.close(descriptor)
        raise ShuttleError(f"{path.name} is no longer a regular file.")
    with os.fdopen(descriptor, "rb") as handle:
        while chunk := handle.read(CHUNK):
            if cancelled():
                raise Cancelled("Transfer cancelled.")
            digest.update(chunk)
    return digest.hexdigest().upper()


def _check_source(item: Media, card: Card) -> None:
    st = item.path.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_dev != card.device or st.st_size != item.size or st.st_mtime_ns != item.mtime_ns:
        raise ShuttleError(f"{item.path.name} changed during transfer. Scan the card again.")


def _open_source(item: Media, card: Card):
    descriptor = os.open(item.path, os.O_RDONLY | os.O_NOFOLLOW)
    st = os.fstat(descriptor)
    if not stat.S_ISREG(st.st_mode) or st.st_dev != card.device or st.st_size != item.size or st.st_mtime_ns != item.mtime_ns:
        os.close(descriptor)
        raise ShuttleError(f"{item.path.name} changed during transfer. Scan the card again.")
    return os.fdopen(descriptor, "rb")


def _safe_destination(root: Path, card: Card) -> Path:
    if not root.is_dir():
        raise ShuttleError("Destination folder is missing or unavailable.")
    resolved = root.resolve(strict=True)
    if _inside(resolved, card.root) or _inside(card.root, resolved):
        raise ShuttleError("Destination and card must be separate folders.")
    if resolved.stat().st_dev == card.device and card.mount_root:
        raise ShuttleError("Destination is on the camera card.")
    return resolved


def _emit(progress: Callable[[dict], None] | None, **values: object) -> None:
    if progress:
        progress(values)


def _write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(prefix=".media-shuttle-", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, indent=2, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, path)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


class Store:
    def __init__(self, root: Path | None = None):
        self.root = root or Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "media-shuttle"
        self.root.mkdir(parents=True, exist_ok=True)

    def settings(self) -> dict:
        defaults = {"destination": str(Path.home() / "Desktop/Camera"), "auto_transfer": False,
                    "group_by_date": False, "notifications": True, "activity": True, "appearance": "Dark"}
        try:
            defaults.update(json.loads((self.root / "settings.json").read_text()))
        except (OSError, ValueError):
            pass
        return defaults

    def save_settings(self, data: dict) -> None:
        _write_json(self.root / "settings.json", data)

    def save_session(self, session: dict) -> Path:
        path = self.root / "sessions" / f"{session['started_at']}-{session['id'][:6]}.json"
        _write_json(path, session)
        return path

    def latest(self, card: Card) -> dict | None:
        paths = list((self.root / "sessions").glob("*.json"))
        for path in sorted(paths, key=lambda file: file.stat().st_mtime_ns, reverse=True):
            try:
                session = json.loads(path.read_text())
            except (OSError, ValueError):
                continue
            if session.get("source") == str(card.root) and session.get("volume_id") == card.volume_id:
                return session if session.get("status") == "Verified" else None
        return None


def _folder_for(root: Path, item: Media, group_by_date: bool) -> Path:
    folder = root / FOLDERS[item.kind]
    if group_by_date:
        folder /= datetime.fromtimestamp(item.mtime_ns / 1e9).strftime("%Y-%m-%d")
    return folder


def _existing_size(path: Path) -> int:
    try:
        if path.is_symlink() or not path.is_file():
            return -1
        return path.stat().st_size
    except OSError:
        return -1


def _numbered(folder: Path, name: str, number: int) -> Path:
    stem, suffix = Path(name).stem, Path(name).suffix
    return folder / f"{stem} ({number}){suffix}"


def _first_free_number(folder: Path, name: str) -> int:
    number = 2
    while True:
        candidate = _numbered(folder, name, number)
        if not (candidate.exists() or candidate.is_symlink()):
            return number
        number += 1


def _existing_numbered_copy(folder: Path, item: Media, card: Card, cancelled: Callable[[], bool],
                            source_hash: str | None) -> tuple[Path, str] | None:
    number = 2
    candidates = []
    while True:
        candidate = _numbered(folder, item.path.name, number)
        if not (candidate.exists() or candidate.is_symlink()):
            break
        if _existing_size(candidate) == item.size:
            candidates.append(candidate)
        number += 1
    if not candidates:
        return None
    if source_hash is None:
        source_hash = _hash(item.path, cancelled)
        _check_source(item, card)
    for candidate in candidates:
        if _hash(candidate, cancelled) == source_hash:
            return candidate, source_hash
    return None


def transfer(card: Card, destination: Path, store: Store, group_by_date: bool = False,
             progress: Callable[[dict], None] | None = None, cancelled: Callable[[], bool] = lambda: False) -> tuple[dict, Path]:
    root = _safe_destination(destination, card)
    _emit(progress, phase="SCANNING", current="Scanning card", fraction=0)
    scan = scan_card(card)
    if not scan.media:
        raise ShuttleError("No supported photos or videos were found on this card.")
    total = sum(item.size for item in scan.media)
    # Count only what may have to be written. A same-size file already under its own name is almost
    # always the copy an earlier run made, so counting it made "Transfer again" on a full card demand
    # the whole card's size in free space a second time with nothing left to copy.
    needed = sum(item.size for item in scan.media
                 if _existing_size(_folder_for(root, item, group_by_date) / item.path.name) != item.size)
    if shutil.disk_usage(root).free < needed + RESERVE:
        raise ShuttleError("Not enough free space at the destination. Free up room for the new files "
                           "plus 1 GB, or choose another destination.")
    session = {"id": uuid.uuid4().hex, "started_at": int(time.time()), "source": str(card.root),
               "volume_id": card.volume_id, "destination": str(root), "total_files": len(scan.media),
               "total_bytes": total, "copied": 0, "skipped": 0, "status": "In progress", "files": []}
    processed = 0
    started = time.monotonic()
    for index, item in enumerate(scan.media):
        if cancelled():
            raise Cancelled("Transfer cancelled.")
        _check_source(item, card)
        folder = _folder_for(root, item, group_by_date)
        folder.mkdir(parents=True, exist_ok=True)
        if not _inside(folder.resolve(strict=True), root):
            raise ShuttleError("A destination folder points outside the selected destination.")
        target = folder / item.path.name
        source_hash = None
        skipped = False
        if target.exists() or target.is_symlink():
            if target.is_file() and not target.is_symlink() and target.stat().st_size == item.size:
                _emit(progress, phase="CHECKING", current=item.path.name, fraction=processed / max(total, 1))
                source_hash = _hash(item.path, cancelled)
                _check_source(item, card)
                skipped = source_hash == _hash(target, cancelled)
            if not skipped:
                # An earlier name collision was kept as "NAME (2).EXT". Look for this file among those
                # before picking a new name; otherwise every repeat transfer wrote another copy.
                existing = _existing_numbered_copy(folder, item, card, cancelled, source_hash)
                if existing is not None:
                    target, source_hash = existing
                    skipped = True
                else:
                    target = _numbered(folder, item.path.name, _first_free_number(folder, item.path.name))
        if skipped:
            session["skipped"] += 1
            verified_hash = source_hash
            processed += item.size
        else:
            temp = folder / f"{target.name}.partial-{uuid.uuid4().hex}"
            try:
                digest = hashlib.sha256()
                copied = 0
                with _open_source(item, card) as source, temp.open("xb") as output:
                    while chunk := source.read(CHUNK):
                        if cancelled():
                            raise Cancelled("Transfer cancelled.")
                        digest.update(chunk)
                        output.write(chunk)
                        copied += len(chunk)
                        _emit(progress, phase="COPYING", current=item.path.name,
                              fraction=(processed + copied) / max(total, 1), copied=session["copied"],
                              skipped=session["skipped"], processed=processed + copied, total=total,
                              elapsed=time.monotonic() - started)
                    output.flush()
                    os.fsync(output.fileno())
                _check_source(item, card)
                if copied != item.size:
                    raise ShuttleError(f"{item.path.name} changed during transfer.")
                _emit(progress, phase="VERIFYING", current=item.path.name, fraction=(processed + copied) / max(total, 1))
                verified_hash = digest.hexdigest().upper()
                if _hash(temp, cancelled) != verified_hash:
                    raise ShuttleError(f"SHA-256 verification failed for {item.path.name}.")
                os.utime(temp, ns=(item.mtime_ns, item.mtime_ns))
                if target.exists() or target.is_symlink():
                    raise ShuttleError(f"Destination changed before publishing {item.path.name}.")
                os.rename(temp, target)
                session["copied"] += 1
                processed += item.size
            finally:
                temp.unlink(missing_ok=True)
        session["files"].append({"source": str(item.path), "destination": str(target),
                                 "sha256": verified_hash, "size": item.size, "kind": item.kind})
        _emit(progress, phase="VERIFYING", current=item.path.name, fraction=(index + 1) / len(scan.media),
              copied=session["copied"], skipped=session["skipped"], processed=processed,
              total=total, elapsed=time.monotonic() - started)
    session["status"] = "Verified"
    session["completed_at"] = int(time.time())
    report = store.save_session(session)
    _emit(progress, phase="VERIFIED", current="Transfer verified", fraction=1, copied=session["copied"],
          skipped=session["skipped"], processed=total, total=total, elapsed=time.monotonic() - started)
    return session, report


def erase_eligible(card: Card, session: dict | None, scan: Scan | None = None) -> bool:
    if not card.allows_erase or not session or session.get("status") != "Verified" or session.get("source") != str(card.root) or session.get("volume_id") != card.volume_id:
        return False
    scan = scan or scan_card(card)
    if scan.unknown or not scan.media or len(scan.media) != len(session.get("files", [])):
        return False
    records = {row["source"]: row for row in session["files"]}
    if len(records) != len(scan.media):
        return False
    for item in scan.media:
        record = records.get(str(item.path))
        if not record or record["size"] != item.size:
            return False
        target = Path(record["destination"])
        if _inside(target.resolve(), card.root) or target.is_symlink() or not target.is_file() or target.stat().st_size != item.size:
            return False
    return True


def wipe(card: Card, session: dict, store: Store, progress: Callable[[dict], None] | None = None) -> int:
    if not card.allows_erase:
        raise ShuttleError("Erase is only available for removable camera-card volume roots.")
    scan = scan_card(card)
    if not erase_eligible(card, session, scan):
        raise ShuttleError("Erase is locked: card contents or destination copies changed. Transfer again first.")
    records = {row["source"]: row for row in session["files"]}
    for index, item in enumerate(scan.media):
        row = records[str(item.path)]
        _emit(progress, phase="RE-VERIFYING", current=item.path.name, fraction=index / len(scan.media))
        if _hash(item.path) != row["sha256"] or _hash(Path(row["destination"])) != row["sha256"]:
            raise ShuttleError(f"Erase blocked: {item.path.name} no longer matches its verified copy. Transfer again.")
    # A second scan catches new or replaced card content before deletion begins.
    if not erase_eligible(card, session, scan_card(card)):
        raise ShuttleError("Card contents changed during re-verification. Transfer again.")
    verified_paths = {item.path for item in scan.media}
    def remove_entry(path: Path) -> int:
        st = path.lstat()
        if st.st_dev != card.device or stat.S_ISLNK(st.st_mode):
            raise ShuttleError("Card contents changed during erase.")
        if stat.S_ISDIR(st.st_mode):
            count = 0
            for child in path.iterdir():
                count += remove_entry(child)
            path.rmdir()  # Fails if a new entry appeared after the child list.
            return count
        if not stat.S_ISREG(st.st_mode):
            raise ShuttleError("Card contents changed during erase.")
        if path in verified_paths:
            row = records[str(path)]
            if _hash(path) != row["sha256"] or _hash(Path(row["destination"])) != row["sha256"]:
                raise ShuttleError(f"Erase blocked: {path.name} changed after re-verification.")
        elif not disposable(path):
            raise ShuttleError(f"Erase blocked: a new unrecognised file appeared: {path.name}.")
        path.unlink()
        return 1

    removed = 0
    entries = [path for path in card.root.iterdir() if path.name.casefold() not in PROTECTED_ROOTS]
    for index, entry in enumerate(entries):
        _emit(progress, phase="ERASING", current=entry.name, fraction=index / max(len(entries), 1))
        removed += remove_entry(entry)
    if any(path.name.casefold() not in PROTECTED_ROOTS for path in card.root.iterdir()):
        raise ShuttleError("Some card content could not be removed.")
    session = {**session, "status": "Erased", "erased_at": int(time.time()), "erased_files": removed}
    store.save_session(session)
    _emit(progress, phase="VERIFIED", current="Card contents erased", fraction=1)
    return removed
