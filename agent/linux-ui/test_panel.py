"""Desktop smoke test; never invokes PC power commands or real admin operations."""
import copy
import os
from pathlib import Path
import json
import time
import unittest
from unittest.mock import patch

# Match the launcher's host-runtime handling when tests run inside a Snap IDE.
if '/snap/' in os.environ.get('GTK_PATH', ''):
    for key in ('GTK_PATH', 'GIO_MODULE_DIR', 'GIO_EXTRA_MODULES',
                'GTK_EXE_PREFIX', 'GTK_DATA_PREFIX', 'GSETTINGS_SCHEMA_DIR'):
        os.environ.pop(key, None)

try:
    import gi
    gi.require_version('Gtk', '3.0')
    from gi.repository import Gtk
    import panel
    DISPLAY = Gtk.init_check()[0]
except (ImportError, ValueError):
    DISPLAY = False


@unittest.skipUnless(DISPLAY, 'GTK 3 desktop display is required')
class PanelTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = panel.Application()
        cls.app.set_application_id('com.wakedesk.Control.Tests')
        cls.app.register(None)
        cls.app.hold()

    @classmethod
    def tearDownClass(cls):
        cls.app.release()

    @patch('panel.Panel.refresh', return_value=True)
    def test_running_settings_drafts_discard_and_pairing_clipboard(self, _):
        window = panel.Panel(self.app)
        self.addCleanup(window.destroy)
        self.assertEqual(window.get_size(), (520, 600))
        self.assertEqual(
            {window.stack.child_get_property(child, 'name')
             for child in window.stack.get_children()},
            {'overview', 'connection', 'security'},
        )
        self.assertEqual(window.stack.get_visible_child_name(), 'overview')
        window.state = {'LoadState': 'loaded', 'ActiveState': 'active',
                        'UnitFileState': 'enabled'}
        window.config = {'listen': '0.0.0.0:8787', 'token': 'test-token-' * 8}
        window.networks = [{'name': 'eth0', 'ip': '192.168.1.50',
                            'mac': 'AA:BB:CC:DD:EE:FF',
                            'broadcast': '192.168.1.255'}]
        window.network.append_text('eth0 — 192.168.1.50')
        window.network.set_active(0)
        window.fill_config()
        self.assertFalse(window.fields['listen'].get_editable())
        self.assertFalse(window.fields['token'].get_visibility())
        self.assertFalse(window.start.get_sensitive())
        self.assertTrue(window.stop.get_sensitive())
        self.assertEqual(window.startup_button.get_label(), 'Disable startup')
        self.assertEqual(window.connection_fields['url'].get_text(),
                         'http://192.168.1.50:8787')
        window.show_token.set_active(True)
        self.assertTrue(window.fields['token'].get_visibility())
        clipboard = Gtk.Clipboard.get(panel.Gdk.SELECTION_CLIPBOARD)
        previous_clipboard = clipboard.wait_for_text()
        self.addCleanup(lambda: clipboard.clear() if previous_clipboard is None
                        else clipboard.set_text(previous_clipboard, -1))
        window.copy('url')
        self.assertEqual(clipboard.wait_for_text(), 'http://192.168.1.50:8787')
        clipboard.clear()

        original = copy.deepcopy(window.config)
        window.state['ActiveState'] = 'inactive'
        window.controls()
        self.assertTrue(window.fields['listen'].get_editable())
        self.assertTrue(window.start.get_sensitive())
        window.generate_token(None)
        self.assertEqual(window.config, original)
        self.assertTrue(window.dirty())
        self.assertTrue(window.save.get_sensitive())
        self.assertFalse(window.copy_token.get_sensitive())
        self.assertFalse(window.qr_button.get_sensitive())
        self.assertFalse(window.start.get_sensitive())
        window.fill_config()
        self.assertFalse(window.dirty())
        self.assertFalse(window.fields['token'].get_visibility())
        self.assertEqual(window.fields['token'].get_text(), original['token'])
        self.assertTrue(window.copy_token.get_sensitive())
        self.assertTrue(window.qr_button.get_sensitive())
        self.assertTrue(window.wol_button.get_sensitive())
        window.busy = True
        window.controls()
        self.assertFalse(window.start.get_sensitive())
        self.assertFalse(window.save.get_sensitive())
        self.assertFalse(window.unlock.get_sensitive())
        self.assertFalse(window.wol_button.get_sensitive())

    @patch('panel.subprocess.run')
    def test_qr_request_uses_stdin_and_saved_connection(self, run):
        run.return_value.stdout = b'PNG'
        config = {'listen': '0.0.0.0:8787', 'token': 'test-token-' * 8,
                  'tls_cert': '/cert.pem', 'tls_key': '/key.pem', 'extra': True}
        adapter = {'ip': '192.168.1.50', 'mac': 'AA:BB:CC:DD:EE:FF',
                   'broadcast': '192.168.1.255'}
        self.assertEqual(panel.Panel.qr_png(config, adapter, 'Linux PC'), b'PNG')
        args, kwargs = run.call_args
        self.assertEqual(len(args[0]), 1)
        self.assertNotIn(config['token'], args[0][0])
        request = json.loads(kwargs['input'])
        self.assertEqual(request['adapter'], adapter)
        self.assertEqual(request['config']['token'], config['token'])
        self.assertEqual(request['config']['tls_cert'], '/cert.pem')
        self.assertNotIn('extra', request['config'])
        self.assertEqual(request['name'], 'Linux PC')

    @patch('panel.Panel.refresh', return_value=True)
    def test_qr_popup_renders_generated_png(self, _):
        if not Path(panel.__file__).with_name('pairing-qr').exists():
            self.skipTest('Build the Linux QR helper first')
        window = panel.Panel(self.app)
        self.addCleanup(window.destroy)
        config = {'listen': '0.0.0.0:8787', 'token': 'test-token-' * 8}
        adapter = {'ip': '192.168.1.50', 'mac': 'AA:BB:CC:DD:EE:FF',
                   'broadcast': '192.168.1.255'}
        window.state = {'LoadState': 'loaded', 'ActiveState': 'active',
                        'UnitFileState': 'enabled'}
        window.config = config
        window.networks = [adapter]
        window.network.append_text('eth0 — 192.168.1.50')
        window.network.set_active(0)
        window.fill_config()
        window.stack.set_visible_child_name('connection')
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            while panel.GLib.MainContext.default().pending():
                panel.GLib.MainContext.default().iteration(False)
            time.sleep(.01)
        self.assertEqual(window.get_size(), (520, 600))
        position = window.qr_button.translate_coordinates(window, 0, 0)
        self.assertGreaterEqual(position[1], 0)
        self.assertLessEqual(position[1] + window.qr_button.get_allocated_height(),
                             window.get_allocated_height())
        self.assertTrue(window.qr_button.get_sensitive())
        observed = []

        def close_dialog():
            for dialog in Gtk.Window.list_toplevels():
                if isinstance(dialog, Gtk.Dialog) and dialog.get_title() == 'Pair this PC':
                    children = dialog.get_content_area().get_children()
                    image = children[1].get_child().get_child()
                    observed.append(image.get_pixbuf().get_width())
                    dialog.response(Gtk.ResponseType.CLOSE)
                    return False
            return True

        source = panel.GLib.timeout_add(50, close_dialog)
        try:
            # Exercise the visible button, background encoder, and modal together.
            window.qr_button.clicked()
            deadline = time.monotonic() + 3
            while not observed and time.monotonic() < deadline:
                while panel.GLib.MainContext.default().pending():
                    panel.GLib.MainContext.default().iteration(False)
                time.sleep(.01)
            self.assertTrue(observed, 'Clicking Show QR code did not open the image')
            self.assertGreater(observed[0], 200)
            self.assertEqual(window.feedback.get_text(),
                             'QR code ready. Scan it with the Android app.')
        finally:
            if not observed:
                panel.GLib.source_remove(source)


if __name__ == '__main__':
    unittest.main()
