import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from media_shuttle import core


class CoreSafetyTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        root = Path(self.scratch.name)
        self.card_root = root / "card"
        self.card_root.mkdir()
        (self.card_root / "DCIM").mkdir()
        self.destination = root / "destination"
        self.destination.mkdir()
        self.store = core.Store(root / "state")
        self.card = core.card_at(self.card_root)
        self.picture = self.card_root / "DCIM" / "IMAGE.JPG"
        self.picture.write_bytes(b"camera original")

    def test_classification_and_unknown_file_blocks_erase(self):
        scan = core.scan_card(self.card)
        self.assertEqual(scan.counts["JPEG"], 1)
        (self.card_root / "DCIM" / "notes.txt").write_text("private data")
        scan = core.scan_card(self.card)
        self.assertEqual([path.name for path in scan.unknown], ["notes.txt"])

    def test_transfer_verifies_and_sorts(self):
        session, report = core.transfer(self.card, self.destination, self.store)
        target = self.destination / "Photos/JPEGs/IMAGE.JPG"
        self.assertEqual(target.read_bytes(), self.picture.read_bytes())
        self.assertEqual(session["copied"], 1)
        self.assertEqual(session["status"], "Verified")
        self.assertEqual(json.loads(report.read_text())["files"][0]["sha256"], core._hash(self.picture))

    def test_duplicate_is_reverified_and_collision_is_preserved(self):
        first, _ = core.transfer(self.card, self.destination, self.store)
        repeat, _ = core.transfer(self.card, self.destination, self.store)
        self.assertEqual(repeat["skipped"], 1)
        self.assertEqual(repeat["copied"], 0)
        target = self.destination / "Photos/JPEGs/IMAGE.JPG"
        target.write_bytes(b"different bytes")
        collision, _ = core.transfer(self.card, self.destination, self.store)
        self.assertEqual(target.read_bytes(), b"different bytes")
        self.assertEqual((target.parent / "IMAGE (2).JPG").read_bytes(), self.picture.read_bytes())
        self.assertEqual(collision["copied"], 1)

    def test_repeat_transfer_reuses_earlier_collision_copy(self):
        jpegs = self.destination / "Photos/JPEGs"
        jpegs.mkdir(parents=True)
        (jpegs / "IMAGE.JPG").write_bytes(b"other original")  # same size, different bytes
        first, _ = core.transfer(self.card, self.destination, self.store)
        self.assertEqual(first["copied"], 1)
        self.assertEqual((jpegs / "IMAGE (2).JPG").read_bytes(), self.picture.read_bytes())

        second, _ = core.transfer(self.card, self.destination, self.store)
        self.assertEqual(second["copied"], 0)
        self.assertEqual(second["skipped"], 1)
        self.assertFalse((jpegs / "IMAGE (3).JPG").exists())
        self.assertEqual(Path(second["files"][0]["destination"]).resolve(), (jpegs / "IMAGE (2).JPG").resolve())
        self.assertTrue(core.erase_eligible(self.card, second) or not self.card.allows_erase)

    def test_free_space_counts_only_files_still_to_copy(self):
        core.transfer(self.card, self.destination, self.store)
        tight = core.RESERVE + 1
        with patch("media_shuttle.core.shutil.disk_usage") as usage:
            usage.return_value = type("Usage", (), {"free": tight})()
            session, _ = core.transfer(self.card, self.destination, self.store)
            self.assertEqual(session["skipped"], 1)
            (self.card_root / "DCIM" / "NEW.JPG").write_bytes(b"x" * 64)
            with self.assertRaises(core.ShuttleError):
                core.transfer(self.card, self.destination, self.store)

    def test_destination_inside_card_rejected(self):
        with self.assertRaises(core.ShuttleError):
            core.transfer(self.card, self.card_root / "DCIM", self.store)

    def test_cancel_removes_partial_file(self):
        seen = []
        def on_progress(event):
            seen.append(event)
        with self.assertRaises(core.Cancelled):
            core.transfer(self.card, self.destination, self.store, progress=on_progress,
                          cancelled=lambda: any(event.get("phase") == "COPYING" for event in seen))
        self.assertFalse(list(self.destination.rglob("*.partial-*")))

    def test_selected_folder_cannot_erase(self):
        session, _ = core.transfer(self.card, self.destination, self.store)
        self.assertFalse(core.erase_eligible(self.card, session))
        with self.assertRaises(core.ShuttleError):
            core.wipe(self.card, session, self.store)
        self.assertTrue(self.picture.exists())

    def test_reverify_before_erase_and_protect_system_directory(self):
        # Simulate a removable mounted volume in the isolated test tree.
        mounted = core.Card(self.card.root, self.card.label, self.card.device, True, True,
                            self.card.volume_id, "Removable media")
        protected = self.card_root / "lost+found"
        protected.mkdir()
        (protected / "keep").write_text("protected")
        with patch.object(core, "_mounts", return_value={self.card_root: "/dev/test"}), \
             patch.object(core, "_safe_destination", return_value=self.destination):
            session, _ = core.transfer(mounted, self.destination, self.store)
            self.assertTrue(core.erase_eligible(mounted, session))
            target = Path(session["files"][0]["destination"])
            target.write_bytes(b"wrong, same size")
            with self.assertRaises(core.ShuttleError):
                core.wipe(mounted, session, self.store)
            self.assertTrue(self.picture.exists())
            target.write_bytes(self.picture.read_bytes())
            (self.card_root / "private.txt").write_text("do not delete")
            with self.assertRaises(core.ShuttleError):
                core.wipe(mounted, session, self.store)
            self.assertTrue(self.picture.exists())
            (self.card_root / "private.txt").unlink()
            self.assertEqual(core.wipe(mounted, session, self.store), 1)
            self.assertFalse(self.picture.exists())
            self.assertTrue((protected / "keep").exists())

    def test_symlink_on_card_blocks_erase(self):
        (self.card_root / "DCIM" / "link").symlink_to(self.picture)
        self.assertEqual([p.name for p in core.scan_card(self.card).unknown], ["link"])

    def test_new_file_during_erase_is_preserved(self):
        mounted = core.Card(self.card.root, self.card.label, self.card.device, True, True,
                            self.card.volume_id, "Removable media")
        new_file = self.card_root / "DCIM" / "private.txt"
        def progress(event):
            if event.get("phase") == "ERASING":
                new_file.write_text("keep me")
        with patch.object(core, "_mounts", return_value={self.card_root: "/dev/test"}), \
             patch.object(core, "_safe_destination", return_value=self.destination):
            session, _ = core.transfer(mounted, self.destination, self.store)
            with self.assertRaises(core.ShuttleError):
                core.wipe(mounted, session, self.store, progress)
        self.assertEqual(new_file.read_text(), "keep me")


if __name__ == "__main__":
    unittest.main()
