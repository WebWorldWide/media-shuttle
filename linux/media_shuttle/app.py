"""GTK 3 desktop interface for Media Shuttle."""

from __future__ import annotations

import os
import sys
import threading
from datetime import datetime
from pathlib import Path

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk  # noqa: E402

from . import core


def size(value: int | float) -> str:
    if value < 1024:
        return f"{value} B"
    for unit in ("KB", "MB", "GB", "TB"):
        value /= 1024
        if value < 1024:
            return f"{value:.1f} {unit}"
    return f"{value:.1f} PB"


def label(text: str = "", css: str = "", xalign: float = 0, wrap: bool = False) -> Gtk.Label:
    widget = Gtk.Label(label=text, xalign=xalign)
    widget.set_yalign(0.5)
    widget.set_line_wrap(wrap)
    if css:
        widget.get_style_context().add_class(css)
    return widget


def button(text: str, callback, css: str = "secondary") -> Gtk.Button:
    widget = Gtk.Button(label=text)
    widget.get_style_context().add_class(css)
    widget.connect("clicked", callback)
    return widget


def box(vertical: bool = True, spacing: int = 0) -> Gtk.Box:
    return Gtk.Box(orientation=Gtk.Orientation.VERTICAL if vertical else Gtk.Orientation.HORIZONTAL, spacing=spacing)


def rule() -> Gtk.Separator:
    return Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)


def framed(widget: Gtk.Widget, css: str = "panel") -> Gtk.EventBox:
    frame = Gtk.EventBox()
    frame.get_style_context().add_class(css)
    frame.add(widget)
    return frame


def css_for(theme: str) -> str:
    gtk_settings = Gtk.Settings.get_default()
    desktop_dark = (gtk_settings.get_property("gtk-application-prefer-dark-theme") or
                    "dark" in gtk_settings.get_property("gtk-theme-name").lower())
    light = theme == "Light" or (theme == "System" and not desktop_dark)
    c = ({"chrome": "#e8e8ea", "content": "#ffffff", "sidebar": "#f7f7f8", "panel": "#fbfbfc", "footer": "#f4f4f6",
          "primary": "#1b1b1e", "bright": "#2a2c30", "secondary": "#4a4e54", "muted": "#6d7279", "line": "#d7d8da",
          "soft": "#e8e9eb", "accent": "#d32f26", "verified": "#2f9e5f", "banner": "#eaf6ee", "button": "#e9eaec"}
         if light else
         {"chrome": "#101012", "content": "#161618", "sidebar": "#121214", "panel": "#1a1a1d", "footer": "#17171a",
          "primary": "#f0f1f2", "bright": "#d6dade", "secondary": "#b9bec4", "muted": "#8b9198", "line": "#343437",
          "soft": "#27272a", "accent": "#ff6a5e", "verified": "#5fd08a", "banner": "#1a2420", "button": "#242427"})
    return f"""
    * {{ font-family: 'DejaVu Sans Mono', 'Liberation Mono', monospace; color: {c['primary']}; text-shadow: none; }}
    window, .content {{ background-color: {c['content']}; }}
    .chrome {{ background-color: {c['chrome']}; border-bottom: 1px solid {c['line']}; }}
    .sidebar {{ background-color: {c['sidebar']}; border-right: 1px solid {c['line']}; }}
    .panel {{ background-color: {c['panel']}; border: 1px solid {c['line']}; }}
    .footer {{ background-color: {c['footer']}; border-top: 1px solid {c['line']}; }}
    .section {{ font-size: 10px; font-weight: bold; letter-spacing: 1.3px; color: {c['muted']}; }}
    .app-name {{ font-size: 11px; font-weight: bold; letter-spacing: 1px; }}
    .body {{ font-size: 11px; color: {c['secondary']}; }}
    .muted {{ font-size: 10px; color: {c['muted']}; }}
    .source-name {{ font-family: sans-serif; font-size: 16px; font-weight: 600; }}
    .metric-value {{ font-size: 16px; font-weight: bold; }}
    .status {{ background: {c['panel']}; border: 1px solid {c['line']}; padding: 3px 7px; font-size: 10px; color: {c['secondary']}; letter-spacing: .6px; }}
    .verified {{ color: {c['verified']}; }}
    .accent {{ color: {c['accent']}; }}
    .banner {{ background: {c['banner']}; border: 1px solid {c['verified']}; border-left: 3px solid {c['verified']}; }}
    .banner-error {{ background: {c['panel']}; border: 1px solid {c['accent']}; border-left: 3px solid {c['accent']}; }}
    .banner-title {{ font-family: sans-serif; font-size: 12px; font-weight: 600; }}
    button {{ min-height: 30px; border-radius: 0; box-shadow: none; background: {c['button']}; border: 1px solid {c['line']}; padding: 2px 11px; font-size: 11px; }}
    button:hover {{ background: {c['soft']}; }}
    button:disabled {{ opacity: .4; }}
    button.primary {{ background: {c['bright']}; color: {c['content']}; border: 1px solid {c['bright']}; font-weight: bold; }}
    button.primary label {{ color: {c['content']}; }}
    button.destructive {{ background: {c['panel']}; color: {c['accent']}; border-color: {c['accent']}; font-weight: bold; }}
    button.destructive label {{ color: {c['accent']}; }}
    button.chrome-button {{ min-width: 26px; min-height: 26px; border: 0; background: transparent; padding: 0; font-size: 16px; color: {c['muted']}; }}
    button.chrome-button:hover {{ background: {c['button']}; }}
    separator {{ background: {c['line']}; min-height: 1px; }}
    .soft-rule {{ background: {c['soft']}; min-height: 1px; }}
    .metric {{ border-right: 1px solid {c['line']}; }}
    .activity-row {{ border-bottom: 1px solid {c['soft']}; }}
    .badge {{ border: 1px solid {c['line']}; padding: 1px 4px; font-size: 9px; color: {c['muted']}; letter-spacing: 1px; }}
    .badge-unlocked {{ border-color: {c['accent']}; color: {c['accent']}; }}
    .popover {{ background-color: {c['panel']}; border: 1px solid {c['line']}; }}
    .popover label {{ color: {c['primary']}; }}
    popover.shuttle-popover, popover.shuttle-popover > contents, popover.shuttle-popover > arrow {{
        background-color: {c['panel']}; border-color: {c['line']}; border-radius: 0; box-shadow: none;
    }}
    checkbutton check {{ border-radius: 0; background: {c['button']}; border: 1px solid {c['line']}; }}
    checkbutton check:checked {{ background: {c['accent']}; border-color: {c['accent']}; }}
    switch {{ border-radius: 0; background: {c['soft']}; }}
    switch:checked {{ background: {c['accent']}; }}
    switch slider {{ border-radius: 0; }}
    entry {{ border-radius: 0; background: {c['content']}; color: {c['primary']}; border: 1px solid {c['line']}; }}
    """


class MediaBar(Gtk.DrawingArea):
    def __init__(self, progress: bool = False):
        super().__init__()
        self.progress = progress
        self.fraction = 0.0
        self.counts = {kind: 0 for kind in core.KINDS}
        self.set_size_request(-1, 6 if not progress else 4)
        self.connect("draw", self.draw_bar)

    def draw_bar(self, widget, cr):
        width = widget.get_allocated_width()
        height = widget.get_allocated_height()
        cr.set_source_rgb(.20, .20, .22)
        cr.rectangle(0, 0, width, height)
        cr.fill()
        if self.progress:
            filled = round(self.fraction * 32)
            for index in range(32):
                if index >= filled:
                    continue
                cr.set_source_rgb(.37, .82, .54)
                x = round(index * width / 32)
                next_x = round((index + 1) * width / 32)
                cr.rectangle(x, 0, max(1, next_x - x - 1), height)
                cr.fill()
        else:
            total = sum(self.counts.values())
            start = 0
            colors = [(0.84, 0.86, 0.87), (.55, .58, .60), (.38, .40, .42), (.26, .28, .30)]
            for kind, color in zip(core.KINDS, colors):
                count = self.counts[kind]
                if count and total:
                    extent = round(width * count / total)
                    cr.set_source_rgb(*color)
                    cr.rectangle(start, 0, extent, height)
                    cr.fill()
                    start += extent
        return False


class ShuttleWindow(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title="Media Shuttle")
        self.set_default_size(1120, 700)
        self.set_size_request(1020, 620)
        self.set_decorated(True)
        self.store = core.Store()
        self.settings = self.store.settings()
        self.card = None
        self.manual_root = None
        self.scan = core.Scan()
        self.session = None
        self.report = None
        self.busy = False
        self.stop_transfer = False
        self.banner_visible = False
        self.activity_items = []
        self.last_candidate = None
        self.baseline = False
        self.pending_auto = False
        self.scan_inflight = False
        self.set_icon_from_file(str(Path(__file__).resolve().parents[1] / "assets/mark.png"))
        self.provider = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), self.provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.apply_theme()
        self.build()
        self.show_all()
        self.banner.hide()
        self.auto_button.hide()
        self.cancel_button.hide()
        self.update_view()
        GLib.timeout_add_seconds(3, self.poll_card)
        GLib.idle_add(self.poll_card)

    def apply_theme(self):
        self.provider.load_from_data(css_for(self.settings["appearance"]).encode())

    def build(self):
        root = box()
        root.get_style_context().add_class("content")
        self.add(root)
        header = box(False, 10)
        header.get_style_context().add_class("chrome")
        header.set_size_request(-1, 40)
        header.set_border_width(6)
        root.pack_start(header, False, False, 0)
        assets = Path(__file__).resolve().parents[1] / "assets"
        mark = Gtk.Image.new_from_pixbuf(GdkPixbuf.Pixbuf.new_from_file_at_scale(str(assets / "mark.png"), 16, 16, True))
        mark.set_margin_start(9)
        header.pack_start(mark, False, False, 0)
        header.pack_start(label("MEDIA SHUTTLE", "app-name"), False, False, 0)
        self.top_status = label("■ WAITING FOR MEDIA", "status")
        self.top_status.set_margin_start(2)
        header.pack_start(self.top_status, False, False, 0)
        header.pack_start(box(False), True, True, 0)
        settings_button = button("⚙", self.open_settings, "chrome-button")
        settings_button.set_tooltip_text("Settings")
        header.pack_end(settings_button, False, False, 0)
        self.settings_button = settings_button

        main = box(False)
        root.pack_start(main, True, True, 0)
        source_scroller = Gtk.ScrolledWindow()
        source_scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        source_scroller.set_size_request(280, -1)
        source_scroller.get_style_context().add_class("sidebar")
        main.pack_start(source_scroller, False, False, 0)
        source = box(spacing=0)
        source.set_border_width(18)
        source_scroller.add(source)
        source.pack_start(label("SOURCE", "section"), False, False, 0)
        summary = box(False, 12)
        summary.set_margin_top(14)
        source.pack_start(summary, False, False, 0)
        self.card_icon = Gtk.Image.new_from_pixbuf(GdkPixbuf.Pixbuf.new_from_file_at_scale(str(assets / "card.png"), 48, 64, True))
        self.card_icon.set_size_request(48, 64)
        summary.pack_start(self.card_icon, False, False, 0)
        summary_text = box(spacing=3)
        summary.pack_start(summary_text, True, True, 0)
        self.source_name = label("No source", "source-name")
        self.source_detail = label("Choose a source or insert a camera card.", "muted", wrap=True)
        self.source_stats = label("", "muted")
        for widget in (self.source_name, self.source_detail, self.source_stats):
            summary_text.pack_start(widget, False, False, 0)
        self.source_button = button("Open card folder…", self.choose_source, "primary")
        self.source_button.set_margin_top(16)
        source.pack_start(self.source_button, False, False, 0)
        self.auto_button = button("Use auto-detect", self.use_auto)
        self.auto_button.set_margin_top(8)
        source.pack_start(self.auto_button, False, False, 0)
        divider = rule()
        divider.set_margin_top(16)
        divider.set_margin_bottom(16)
        source.pack_start(divider, False, False, 0)
        source.pack_start(label("CARD CONTENTS", "section"), False, False, 0)
        self.contents_bar = MediaBar()
        self.contents_bar.set_margin_top(12)
        self.contents_bar.set_margin_bottom(9)
        source.pack_start(self.contents_bar, False, False, 0)
        self.count_labels = {}
        for kind, symbol in zip(core.KINDS, ("■", "■", "■", "■")):
            line = box(False, 6)
            line.set_margin_top(3)
            line.set_margin_bottom(3)
            swatch = label(symbol, "muted")
            line.pack_start(swatch, False, False, 0)
            line.pack_start(label(kind, "body"), True, True, 0)
            count = label("0", "body", xalign=1)
            line.pack_end(count, False, False, 0)
            source.pack_start(line, False, False, 0)
            self.count_labels[kind] = count
        divider2 = rule()
        divider2.set_margin_top(16)
        divider2.set_margin_bottom(16)
        source.pack_start(divider2, False, False, 0)
        source.pack_start(label("DESTINATION", "section"), False, False, 0)
        self.destination_label = label("", "body", wrap=True)
        self.destination_label.set_margin_top(12)
        source.pack_start(self.destination_label, False, False, 0)
        self.destination_warning = label("Destination folder is missing or unavailable.", "accent", wrap=True)
        self.destination_warning.set_margin_top(7)
        source.pack_start(self.destination_warning, False, False, 0)
        destination_buttons = box(False, 5)
        destination_buttons.set_homogeneous(True)
        destination_buttons.set_margin_top(8)
        source.pack_start(destination_buttons, False, False, 0)
        self.change_button = button("Change", self.choose_destination)
        self.open_button = button("Open", self.open_destination)
        destination_buttons.pack_start(self.change_button, True, True, 0)
        destination_buttons.pack_start(self.open_button, True, True, 0)
        folder_layout = label("Photos/JPEGs\nPhotos/RAWs\nPhotos/Other\nVideos", "muted")
        folder_layout.set_margin_top(10)
        source.pack_start(folder_layout, False, False, 0)

        operations_scroller = Gtk.ScrolledWindow()
        operations_scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        main.pack_start(operations_scroller, True, True, 0)
        operations = box(spacing=14)
        operations.set_margin_start(20)
        operations.set_margin_end(20)
        operations.set_margin_top(18)
        operations.set_margin_bottom(18)
        operations_scroller.add(operations)
        self.banner = self.build_banner()
        operations.pack_start(self.banner, False, False, 0)
        operations.pack_start(self.build_session(), False, False, 0)
        self.activity_section = self.build_activity()
        operations.pack_start(self.activity_section, False, False, 0)
        operations.pack_start(box(), True, True, 0)
        operations.pack_end(self.build_erase(), False, False, 0)

    def build_banner(self):
        line = box(False, 9)
        line.set_border_width(9)
        self.banner_icon = label("✓", "verified")
        line.pack_start(self.banner_icon, False, False, 0)
        texts = box(spacing=2)
        line.pack_start(texts, True, True, 0)
        self.banner_title = label("", "banner-title", wrap=True)
        self.banner_detail = label("", "body", wrap=True)
        texts.pack_start(self.banner_title, False, False, 0)
        texts.pack_start(self.banner_detail, False, False, 0)
        line.pack_end(button("×", lambda *_: self.banner.hide(), "chrome-button"), False, False, 0)
        return framed(line, "banner")

    def build_session(self):
        panel = box()
        top = box(False, 8)
        top.set_border_width(9)
        panel.pack_start(top, False, False, 0)
        top.pack_start(label("THIS SESSION", "section"), True, True, 0)
        self.phase_label = label("STANDBY", "section", xalign=1)
        self.percent_label = label("0%", "section", xalign=1)
        top.pack_end(self.percent_label, False, False, 0)
        top.pack_end(self.phase_label, False, False, 0)
        self.progress_bar = MediaBar(progress=True)
        self.progress_bar.set_margin_start(9)
        self.progress_bar.set_margin_end(9)
        self.progress_bar.set_margin_bottom(8)
        panel.pack_start(self.progress_bar, False, False, 0)
        panel.pack_start(rule(), False, False, 0)
        metrics = box(False)
        metrics.set_homogeneous(True)
        panel.pack_start(metrics, False, False, 0)
        self.metrics = {}
        for name, caption in (("COPIED", "files"), ("ALREADY SAFE", "re-verified"),
                              ("PROCESSED", "idle"), ("THROUGHPUT", "idle"), ("ELAPSED", "min:sec")):
            cell = box(spacing=3)
            cell.set_border_width(9)
            cell.get_style_context().add_class("metric")
            cell.pack_start(label(name, "section"), False, False, 0)
            value = label("—" if name != "ELAPSED" else "0:00", "metric-value")
            detail = label(caption, "muted")
            cell.pack_start(value, False, False, 0)
            cell.pack_start(detail, False, False, 0)
            metrics.pack_start(cell, True, True, 0)
            self.metrics[name] = (value, detail)
        panel.pack_start(rule(), False, False, 0)
        footer = box(False, 6)
        footer.set_border_width(9)
        footer.get_style_context().add_class("footer")
        panel.pack_start(footer, False, False, 0)
        self.current_file = label("Waiting for camera media", "muted")
        self.current_file.set_ellipsize(3)
        footer.pack_start(self.current_file, True, True, 0)
        self.report_button = button("Report", self.open_report)
        self.cancel_button = button("Cancel", self.cancel_transfer)
        self.transfer_button = button("Scan for media", self.primary_action, "primary")
        for widget in (self.report_button, self.cancel_button, self.transfer_button):
            footer.pack_start(widget, False, False, 0)
        return framed(panel)

    def build_activity(self):
        section = box(spacing=7)
        heading = box(False, 8)
        heading.pack_start(label("ACTIVITY", "section"), False, False, 0)
        heading_rule = rule()
        heading_rule.set_valign(Gtk.Align.CENTER)
        heading.pack_start(heading_rule, True, True, 0)
        section.pack_start(heading, False, False, 0)
        self.activity_box = box()
        section.pack_start(self.activity_box, False, False, 0)
        return section

    def build_erase(self):
        line = box(False, 10)
        line.set_border_width(9)
        texts = box(spacing=3)
        line.pack_start(texts, True, True, 0)
        title = box(False, 6)
        texts.pack_start(title, False, False, 0)
        title.pack_start(label("Erase card", "source-name"), False, False, 0)
        self.erase_badge = label("LOCKED", "badge")
        title.pack_start(self.erase_badge, False, False, 0)
        self.erase_detail = label("Locked until every remaining camera file has a verified destination copy.", "muted", wrap=True)
        texts.pack_start(self.erase_detail, False, False, 0)
        self.erase_button = button("Erase everything on card", self.confirm_erase, "destructive")
        line.pack_end(self.erase_button, False, False, 0)
        return framed(line)

    def banner_message(self, title: str, detail: str, error: bool = False):
        self.banner.get_style_context().remove_class("banner" if error else "banner-error")
        self.banner.get_style_context().add_class("banner-error" if error else "banner")
        self.banner_title.set_text(title)
        self.banner_detail.set_text(detail)
        self.banner_icon.set_text("!" if error else "✓")
        self.banner.show_all()

    def activity(self, message: str):
        self.activity_items.insert(0, f"{datetime.now().strftime('%I:%M:%S %p')}  {message}")
        self.activity_items = self.activity_items[:100]
        for child in self.activity_box.get_children():
            self.activity_box.remove(child)
        for entry in self.activity_items:
            row = label(entry, "body", wrap=True)
            row.set_margin_top(4)
            row.set_margin_bottom(4)
            row.get_style_context().add_class("activity-row")
            self.activity_box.pack_start(row, False, False, 0)
        self.activity_box.show_all()

    def update_view(self):
        card = self.card
        media = self.scan.media
        total = sum(item.size for item in media)
        destination = Path(self.settings["destination"]).expanduser()
        available = destination.is_dir()
        self.top_status.set_text(f"■ {card.label.upper()} · {'TRANSFER VERIFIED' if self.session and self.session.get('status') == 'Verified' else 'READY' if card else 'WAITING FOR MEDIA'}" if card else "■ WAITING FOR MEDIA")
        self.source_name.set_text(card.label if card else "No source")
        self.source_detail.set_text(f"{card.root} · {card.drive_type}" if card else "Choose a source or insert a camera card.")
        self.source_stats.set_text(f"{len(media)} assets · {size(total)}" if card else "")
        self.contents_bar.counts = self.scan.counts
        self.contents_bar.queue_draw()
        for kind, count in self.scan.counts.items():
            self.count_labels[kind].set_text(str(count))
        self.destination_label.set_text(str(destination).replace(str(Path.home()), "~", 1))
        self.destination_warning.set_visible(not available)
        self.change_button.set_label("Change" if available else "Choose folder")
        self.open_button.set_sensitive(available)
        self.auto_button.set_visible(self.manual_root is not None)
        self.source_button.set_sensitive(not self.busy)
        self.auto_button.set_sensitive(not self.busy)
        self.change_button.set_sensitive(not self.busy)
        self.report_button.set_sensitive(self.report is not None)
        self.cancel_button.set_visible(self.busy and self.phase_label.get_text() not in ("RE-VERIFYING", "ERASING"))
        self.transfer_button.set_label("Choose destination" if not available else "Transfer again" if self.session else "Transfer and verify" if card else "Scan for media")
        self.transfer_button.set_sensitive(not self.busy and (not available or not card or bool(media)))
        self.activity_section.set_visible(self.settings["activity"])
        eligible = False
        try:
            eligible = core.erase_eligible(card, self.session, self.scan) if card else False
        except OSError:
            pass
        self.erase_button.set_sensitive(eligible and not self.busy)
        self.erase_badge.set_text("UNLOCKED" if eligible else "LOCKED")
        badge_style = self.erase_badge.get_style_context()
        (badge_style.add_class if eligible else badge_style.remove_class)("badge-unlocked")
        if not card or not card.allows_erase:
            detail = "Erase is available only for removable camera-card volumes. Selected folders support transfer and verification."
        elif self.scan.unknown:
            detail = f"Locked — {len(self.scan.unknown)} unrecognised file(s) on this card have no verified copy."
        elif eligible:
            detail = f"Every remaining file on {card.root} has a verified copy · typed confirmation required"
        else:
            detail = "Locked until every remaining camera file has a verified destination copy."
        self.erase_detail.set_text(detail)

    def set_card(self, card):
        if card and self.card and card.root == self.card.root and card.volume_id == self.card.volume_id:
            return
        self.card = card
        self.scan = core.Scan()
        self.scan_inflight = False
        self.session = self.store.latest(card) if card else None
        self.report = None
        self.update_view()
        if card:
            self.rescan()

    def rescan(self):
        card = self.card
        if not card or self.busy or self.scan_inflight:
            return
        self.scan_inflight = True
        def worker():
            try:
                result = core.scan_card(card)
                GLib.idle_add(self.scan_ready, card, result)
            except (OSError, core.ShuttleError) as error:
                GLib.idle_add(self.scan_failed, card, str(error))
        threading.Thread(target=worker, daemon=True).start()

    def scan_ready(self, card, result):
        if self.card == card:
            self.scan_inflight = False
        if self.card == card and not self.busy:
            self.scan = result
            self.update_view()
            if self.pending_auto:
                self.pending_auto = False
                self.start_transfer()
        return False

    def scan_failed(self, card, message):
        if self.card == card:
            self.scan_inflight = False
            self.banner_message("Source unavailable", message, True)
        return False

    def poll_card(self):
        if self.busy:
            return True
        try:
            desired = core.card_at(self.manual_root) if self.manual_root else next(iter(core.candidates(Path(self.settings["destination"]))), None)
        except (OSError, core.ShuttleError):
            desired = None
        previous = self.card
        arrived = self.baseline and desired and (not previous or previous.root != desired.root)
        if arrived:
            self.pending_auto = bool(self.settings["auto_transfer"])
        elif desired is None:
            self.pending_auto = False
        self.set_card(desired)
        if desired and previous and desired.root == previous.root:
            self.rescan()
        if not self.baseline:
            self.baseline = True
        elif arrived:
            self.activity(f"Card connected: {desired.label}")
        return True

    def choose_folder(self, title, callback):
        dialog = Gtk.FileChooserNative.new(title, self, Gtk.FileChooserAction.SELECT_FOLDER, "Choose", "Cancel")
        dialog.connect("response", lambda chooser, response: (callback(Path(chooser.get_filename())) if response == Gtk.ResponseType.ACCEPT else None, chooser.destroy()))
        dialog.show()

    def choose_source(self, *_):
        def selected(path):
            try:
                card = core.card_at(path)
            except (OSError, core.ShuttleError) as error:
                self.banner_message("Cannot open source", str(error), True)
                return
            self.manual_root = card.root
            self.set_card(card)
            self.activity(f"Selected source: {card.root}")
        self.choose_folder("Open camera card folder", selected)

    def use_auto(self, *_):
        self.manual_root = None
        self.pending_auto = False
        self.set_card(None)
        self.poll_card()

    def choose_destination(self, *_):
        def selected(path):
            self.settings["destination"] = str(path)
            self.store.save_settings(self.settings)
            self.session = None
            self.report = None
            self.update_view()
        self.choose_folder("Choose destination folder", selected)

    def open_destination(self, *_):
        try:
            Gio.AppInfo.launch_default_for_uri(Path(self.settings["destination"]).expanduser().as_uri(), None)
        except GLib.Error as error:
            self.banner_message("Cannot open destination", str(error), True)

    def open_report(self, *_):
        if self.report:
            try:
                Gio.AppInfo.launch_default_for_uri(self.report.as_uri(), None)
            except GLib.Error as error:
                self.banner_message("Cannot open report", str(error), True)

    def primary_action(self, *_):
        if not Path(self.settings["destination"]).expanduser().is_dir():
            self.choose_destination()
        elif self.card:
            self.start_transfer()
        else:
            self.poll_card()

    def cancel_transfer(self, *_):
        self.stop_transfer = True
        self.cancel_button.set_sensitive(False)

    def start_transfer(self):
        if self.busy or not self.card or not self.scan.media:
            return
        if not Path(self.settings["destination"]).expanduser().is_dir():
            self.banner_message("Choose a destination", "The destination folder is missing or unavailable.", True)
            return
        card = self.card
        self.busy = True
        self.stop_transfer = False
        self.report = None
        self.activity(f"Transfer started from {card.root}.")
        self.update_view()
        def worker():
            try:
                session, report = core.transfer(card, Path(self.settings["destination"]), self.store,
                    self.settings["group_by_date"], lambda event: GLib.idle_add(self.progress, event),
                    lambda: self.stop_transfer)
                GLib.idle_add(self.transfer_finished, session, report)
            except Exception as error:
                GLib.idle_add(self.operation_failed, error)
        threading.Thread(target=worker, daemon=True).start()

    def progress(self, event):
        phase = event.get("phase", "STANDBY")
        fraction = event.get("fraction", 0)
        self.phase_label.set_text(phase)
        self.percent_label.set_text(f"{fraction:.0%}")
        self.progress_bar.fraction = fraction
        self.progress_bar.queue_draw()
        self.current_file.set_text(event.get("current", ""))
        if "copied" in event:
            self.metrics["COPIED"][0].set_text(str(event["copied"]))
            self.metrics["ALREADY SAFE"][0].set_text(str(event["skipped"]))
        if "processed" in event:
            processed, total = event["processed"], event["total"]
            value, unit = size(processed).split(" ")
            self.metrics["PROCESSED"][0].set_text(value)
            self.metrics["PROCESSED"][1].set_text(f"{unit} of {size(total)}")
            elapsed = event.get("elapsed", 0)
            self.metrics["ELAPSED"][0].set_text(f"{int(elapsed) // 60}:{int(elapsed) % 60:02d}")
            if elapsed > 0 and processed:
                speed, speed_unit = size(processed / elapsed).split(" ")
                self.metrics["THROUGHPUT"][0].set_text(speed)
                self.metrics["THROUGHPUT"][1].set_text(f"{speed_unit}/s avg")
        self.cancel_button.set_visible(self.busy and phase not in ("RE-VERIFYING", "ERASING"))
        return False

    def transfer_finished(self, session, report):
        self.busy = False
        self.session = session
        self.report = report
        self.progress({"phase": "VERIFIED", "fraction": 1, "current": "Transfer verified"})
        self.activity(f"Verification complete — {session['total_files']} files match by SHA-256.")
        self.banner_message(f"Transfer verified — {session['total_files']} files safe in the destination",
                            "SHA-256 matched on every camera file")
        self.update_view()
        if self.settings["notifications"]:
            self.notify("Transfer verified", f"{session['total_files']} camera files are safe in the destination.")
        return False

    def operation_failed(self, error):
        self.busy = False
        cancelled = isinstance(error, core.Cancelled)
        self.phase_label.set_text("CANCELLED" if cancelled else "NEEDS ATTENTION")
        self.banner_message("Transfer cancelled" if cancelled else "Operation needs attention", str(error), not cancelled)
        self.activity(str(error))
        self.update_view()
        return False

    def notify(self, title, detail):
        notification = Gio.Notification.new(title)
        notification.set_body(detail)
        self.get_application().send_notification(None, notification)

    def confirm_erase(self, *_):
        try:
            eligible = self.card and core.erase_eligible(self.card, self.session)
        except (OSError, core.ShuttleError):
            eligible = False
        if not eligible:
            self.banner_message("Erase is locked", "Card contents changed. Scan and transfer again before erasing.", True)
            return
        card = self.card
        dialog = Gtk.Dialog(title="Erase everything on card", transient_for=self, modal=True)
        dialog.add_button("Cancel", Gtk.ResponseType.CANCEL)
        confirm = dialog.add_button("Erase everything", Gtk.ResponseType.OK)
        confirm.get_style_context().add_class("destructive")
        confirm.set_sensitive(False)
        content = dialog.get_content_area()
        content.set_border_width(18)
        content.set_spacing(12)
        content.add(label(f"This permanently removes user content from {card.root}. Every media file will be re-verified before deletion.", "body", wrap=True))
        content.add(label("Type ERASE EVERYTHING to confirm:", "section"))
        phrase = Gtk.Entry()
        content.add(phrase)
        acknowledgement = Gtk.CheckButton(label="I understand this removes the card contents.")
        content.add(acknowledgement)
        def update(*_):
            confirm.set_sensitive(phrase.get_text() == "ERASE EVERYTHING" and acknowledgement.get_active())
        phrase.connect("changed", update)
        acknowledgement.connect("toggled", update)
        dialog.show_all()
        response = dialog.run()
        dialog.destroy()
        if response != Gtk.ResponseType.OK:
            return
        try:
            if not core.erase_eligible(card, self.session):
                raise core.ShuttleError("Card contents changed. Transfer again before erasing.")
        except (OSError, core.ShuttleError) as error:
            self.banner_message("Erase is locked", str(error), True)
            return
        self.busy = True
        self.update_view()
        def worker():
            try:
                count = core.wipe(card, self.session, self.store, lambda event: GLib.idle_add(self.progress, event))
                GLib.idle_add(self.erase_finished, count)
            except Exception as error:
                GLib.idle_add(self.operation_failed, error)
        threading.Thread(target=worker, daemon=True).start()

    def erase_finished(self, count):
        self.busy = False
        self.session = None
        self.activity(f"Card erase complete — {count} files removed.")
        self.banner_message("Card contents erased", f"{count} files removed. Use the camera's Format command for a fresh filesystem.")
        self.scan = core.Scan()
        self.update_view()
        if self.settings["notifications"]:
            self.notify("Card contents erased", f"{count} files removed.")
        return False

    def open_settings(self, *_):
        pop = Gtk.Popover.new(self.settings_button)
        pop.get_style_context().add_class("shuttle-popover")
        pop.set_position(Gtk.PositionType.BOTTOM)
        pane = box(spacing=11)
        pane.set_border_width(16)
        pane.set_size_request(350, -1)
        pane.get_style_context().add_class("popover")
        pane.pack_start(label("Settings", "source-name"), False, False, 0)
        pane.pack_start(label("APPEARANCE", "section"), False, False, 0)
        appearance = Gtk.ComboBoxText()
        for choice in ("System", "Light", "Dark"):
            appearance.append_text(choice)
        appearance.set_active(("System", "Light", "Dark").index(self.settings["appearance"]))
        def change_appearance(widget):
            self.settings["appearance"] = widget.get_active_text()
            self.store.save_settings(self.settings)
            self.apply_theme()
        appearance.connect("changed", change_appearance)
        pane.pack_start(appearance, False, False, 0)
        pane.pack_start(label("TRANSFER", "section"), False, False, 0)
        for key, title in (("auto_transfer", "Transfer automatically when a card is connected"),
                           ("group_by_date", "Group files into YYYY-MM-DD folders"),
                           ("notifications", "Show completion notifications"),
                           ("activity", "Show the activity log")):
            toggle = Gtk.CheckButton(label=title)
            toggle.set_active(self.settings[key])
            def changed(widget, setting=key):
                self.settings[setting] = widget.get_active()
                self.store.save_settings(self.settings)
                self.update_view()
            toggle.connect("toggled", changed)
            pane.pack_start(toggle, False, False, 0)
        pane.pack_start(label("SYSTEM", "section"), False, False, 0)
        startup = Gtk.CheckButton(label="Launch Media Shuttle at login")
        autostart = Path.home() / ".config/autostart/media-shuttle.desktop"
        startup.set_active(autostart.exists())
        def toggle_startup(widget):
            if widget.get_active():
                autostart.parent.mkdir(parents=True, exist_ok=True)
                flatpak_id = os.environ.get("FLATPAK_ID")
                if flatpak_id:
                    # Inside the sandbox the launcher's path doesn't exist on the host, which is
                    # where the session starts autostart entries.
                    command = f"flatpak run {flatpak_id}"
                else:
                    launcher = Path(__file__).resolve().parents[1] / "media-shuttle"
                    command = '"' + str(launcher).replace('"', '\\"') + '"'
                autostart.write_text(
                    "[Desktop Entry]\nType=Application\nName=Media Shuttle\nExec=" + command + "\nTerminal=false\n"
                )
            else:
                autostart.unlink(missing_ok=True)
        startup.connect("toggled", toggle_startup)
        pane.pack_start(startup, False, False, 0)
        pop.add(pane)
        pop.show_all()


class ShuttleApplication(Gtk.Application):
    def __init__(self):
        super().__init__(application_id="io.github.adamnolle.MediaShuttle", flags=Gio.ApplicationFlags.FLAGS_NONE)

    def do_activate(self):
        window = self.get_active_window()
        if window is None:
            window = ShuttleWindow(self)
        window.present()


def main():
    app = ShuttleApplication()
    return app.run(sys.argv)


if __name__ == "__main__":
    raise SystemExit(main())
