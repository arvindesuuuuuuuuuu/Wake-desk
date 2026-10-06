#!/usr/bin/python3
"""WakeDesk Linux desktop control panel (GTK 3)."""
import json
from pathlib import Path
import secrets
import socket
import subprocess
import threading
import urllib.request

import gi

gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
gi.require_version('GdkPixbuf', '2.0')
from gi.repository import Gdk, GdkPixbuf, Gio, GLib, Gtk

import control


class Panel(Gtk.ApplicationWindow):
    def __init__(self, app):
        super().__init__(application=app, title='WakeDesk')
        self.set_default_size(520, 600)
        self.set_border_width(0)
        self.config = None
        self.networks = []
        self.state = {}
        self.busy = False
        self.polling = False
        self.closed = False
        self.connect('destroy', self.close_panel)

        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.add(scroll)
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        content.set_border_width(12)
        scroll.add(content)
        title = Gtk.Label(xalign=0)
        title.set_markup('<span size="xx-large" weight="bold">WakeDesk</span>')
        content.pack_start(title, False, False, 0)
        content.pack_start(Gtk.Label(label='Linux PC control agent', xalign=0), False, False, 0)
        self.status = Gtk.Label(label='Checking agent…', xalign=0)
        self.uptime = Gtk.Label(label='Uptime —', xalign=0)
        self.startup = Gtk.Label(label='Startup —', xalign=0)
        for widget in (self.status, self.uptime, self.startup):
            content.pack_start(widget, False, False, 0)

        row = Gtk.Box(spacing=8, homogeneous=True)
        content.pack_start(row, False, False, 0)
        self.start = self.button(row, 'Start agent', lambda _: self.operation('start'))
        self.stop = self.button(row, 'Stop agent', lambda _: self.operation('stop'))
        self.startup_button = self.button(row, 'Enable startup', self.toggle_startup)
        self.button(content, 'Refresh status', lambda _: self.refresh())
        content.pack_start(Gtk.Separator(), False, False, 0)

        self.unlock = self.button(content, 'Unlock connection settings', self.load_config)
        self.hint = Gtk.Label(label='Authenticate to view the phone token and edit settings.', xalign=0)
        self.hint.set_line_wrap(True)
        content.pack_start(self.hint, False, False, 0)
        grid = Gtk.Grid(column_spacing=8, row_spacing=6)
        content.pack_start(grid, False, False, 0)
        self.fields = {}
        for i, (key, label) in enumerate((('listen', 'Listen address'), ('token', 'Access token'))):
            grid.attach(Gtk.Label(label=label, xalign=0), 0, i, 1, 1)
            entry = Gtk.Entry(hexpand=True)
            entry.connect('changed', lambda _: self.controls())
            grid.attach(entry, 1, i, 1, 1)
            self.fields[key] = entry
        self.fields['token'].set_visibility(False)
        self.show_token = Gtk.CheckButton(label='Show token')
        self.show_token.connect('toggled', lambda button: self.fields['token'].set_visibility(button.get_active()))
        content.pack_start(self.show_token, False, False, 0)
        row = Gtk.Box(spacing=8, homogeneous=True)
        content.pack_start(row, False, False, 0)
        self.generate = self.button(row, 'Generate token', self.generate_token)
        self.save = self.button(row, 'Save settings', self.save_config)
        self.discard = self.button(row, 'Discard changes', lambda _: self.fill_config())
        content.pack_start(Gtk.Separator(), False, False, 0)
        heading = Gtk.Label(xalign=0)
        heading.set_markup('<b>Phone connection</b>')
        phone_heading = Gtk.Box(spacing=8)
        phone_heading.pack_start(heading, True, True, 0)
        self.qr_button = self.button(phone_heading, 'Show QR code', self.show_qr)
        content.pack_start(phone_heading, False, False, 0)
        self.network = Gtk.ComboBoxText()
        self.network.connect('changed', lambda _: self.update_network())
        content.pack_start(self.network, False, False, 0)
        grid = Gtk.Grid(column_spacing=8, row_spacing=6)
        content.pack_start(grid, False, False, 0)
        self.connection_fields = {}
        self.copy_buttons = []
        for i, (key, label) in enumerate((('url', 'Agent URL'), ('mac', 'MAC address'), ('broadcast', 'Broadcast'))):
            grid.attach(Gtk.Label(label=label, xalign=0), 0, i, 1, 1)
            entry = Gtk.Entry(hexpand=True, editable=False)
            grid.attach(entry, 1, i, 1, 1)
            button = Gtk.Button(label='Copy')
            button.connect('clicked', lambda _, k=key: self.copy(k))
            grid.attach(button, 2, i, 1, 1)
            self.connection_fields[key] = entry
            self.copy_buttons.append(button)
        self.copy_token = self.button(content, 'Copy access token', lambda _: self.copy('token'))
        note = Gtk.Label(label='Choose the network reachable from your phone. Keep the token private. '
                              'Stop the agent before editing; save changes before pairing.', xalign=0)
        note.set_line_wrap(True)
        content.pack_start(note, False, False, 0)
        self.feedback = Gtk.Label(label='Ready', xalign=0, selectable=True)
        self.feedback.set_line_wrap(True)
        content.pack_start(self.feedback, False, False, 0)
        self.controls()
        self.show_all()
        self.refresh()
        self.timer = GLib.timeout_add_seconds(5, self.refresh)

    @staticmethod
    def button(parent, label, callback):
        button = Gtk.Button(label=label)
        button.connect('clicked', callback)
        parent.pack_start(button, False, False, 0)
        return button

    def close_panel(self, *_):
        self.closed = True
        GLib.source_remove(self.timer)

    def dirty(self):
        return self.config is not None and any(
            self.fields[key].get_text() != self.config[key] for key in self.fields)

    def controls(self):
        active = self.state.get('ActiveState')
        installed = self.state.get('LoadState') == 'loaded'
        stopped = active in ('inactive', 'failed')
        self.start.set_sensitive(installed and stopped and not self.busy and not self.dirty())
        self.stop.set_sensitive(installed and active in ('active', 'activating') and not self.busy)
        startup_known = self.state.get('UnitFileState') in ('enabled', 'disabled')
        self.startup_button.set_sensitive(installed and startup_known and not self.busy)
        self.startup_button.set_label('Disable startup' if self.state.get('UnitFileState') == 'enabled' else 'Enable startup')
        self.unlock.set_sensitive(not self.busy)
        editable = self.config is not None and stopped and not self.busy
        for entry in self.fields.values():
            entry.set_editable(editable)
            entry.set_sensitive(self.config is not None)
        self.generate.set_sensitive(editable)
        self.save.set_sensitive(editable and self.dirty())
        self.discard.set_sensitive(not self.busy and self.dirty())
        self.show_token.set_sensitive(self.config is not None)
        pairing = self.config is not None and not self.busy and not self.dirty()
        self.copy_token.set_sensitive(pairing)
        self.network.set_sensitive(not self.busy)
        self.qr_button.set_sensitive(pairing and 0 <= self.network.get_active() < len(self.networks))
        for button in self.copy_buttons:
            button.set_sensitive(pairing and bool(self.networks))
        if self.config is not None:
            self.hint.set_text('Unsaved changes' if self.dirty() else
                               'Saved settings' if stopped else 'Settings are read-only while the agent is running.')

    def async_work(self, work, done, working_message='Working… An administrator prompt may appear.',
                   error_message='Operation failed or authentication was canceled. Check the agent and settings.'):
        if self.busy:
            return
        self.busy = True
        self.feedback.set_text(working_message)
        self.controls()

        def worker():
            try:
                result, error = work(), None
            except Exception:
                result, error = None, error_message

            def finish():
                if self.closed:
                    return False
                self.busy = False
                if error:
                    self.feedback.set_text(error)
                else:
                    done(result)
                self.controls()
                self.refresh()
                return False
            GLib.idle_add(finish)
        threading.Thread(target=worker, daemon=True).start()

    @staticmethod
    def privileged(action, data=None):
        # Always use the installed, root-owned helper, never a workspace script.
        result = subprocess.run(
            ['pkexec', '/usr/bin/python3', '-I', '/usr/local/lib/wakedesk/control.py', action],
            input=json.dumps(data) if data is not None else None,
            text=True, capture_output=True, check=True, timeout=120)
        return json.loads(result.stdout) if action in ('read', 'save') else None

    def operation(self, action):
        self.async_work(lambda: self.privileged(action),
                        lambda _: self.feedback.set_text(f'Agent {action} completed.'))

    def toggle_startup(self, _):
        self.operation('disable' if self.state.get('UnitFileState') == 'enabled' else 'enable')

    def load_config(self, _):
        if self.dirty():
            self.feedback.set_text('Save or discard changes before reloading settings.')
            return

        def loaded(config):
            self.config = config
            self.fill_config()
            self.unlock.set_label('Reload connection settings')
            self.feedback.set_text('Connection settings unlocked.')
        self.async_work(lambda: self.privileged('read'), loaded)

    def fill_config(self):
        for key, entry in self.fields.items():
            entry.set_text(self.config[key])
        self.show_token.set_active(False)
        self.update_network()
        self.controls()

    def generate_token(self, _):
        self.fields['token'].set_text(secrets.token_hex(32))
        self.feedback.set_text('New token is a draft. Save it, then update your phone.')

    def save_config(self, _):
        update = {key: entry.get_text().strip() for key, entry in self.fields.items()}
        candidate = {**self.config, **update}
        try:
            control.validate(candidate)
        except ValueError as error:
            self.feedback.set_text(str(error))
            return

        def saved(config):
            self.config = config
            self.fill_config()
            self.feedback.set_text('Settings saved. Update the phone if you changed its token or URL.')
        self.async_work(lambda: self.privileged('save', update), saved)

    def update_network(self):
        index = self.network.get_active()
        adapter = self.networks[index] if 0 <= index < len(self.networks) else None
        values = dict(adapter or {})
        values['url'] = control.agent_url(self.config, adapter['ip']) if self.config and adapter else ''
        for key, entry in self.connection_fields.items():
            entry.set_text(values.get(key, ''))
        self.controls()

    def copy(self, key):
        text = self.config['token'] if key == 'token' else self.connection_fields[key].get_text()
        Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).set_text(text, -1)
        self.feedback.set_text(f'{"Access token" if key == "token" else key.capitalize()} copied.')

    @staticmethod
    def qr_png(config, adapter, name):
        # The helper shares the Windows payload/QR encoder. No files or uploads.
        request = {
            'config': {key: config[key] for key in ('listen', 'token', 'tls_cert', 'tls_key') if key in config},
            'adapter': adapter,
            'name': name,
        }
        return subprocess.run(
            [str(Path(__file__).with_name('pairing-qr'))],
            input=json.dumps(request).encode('utf-8'), capture_output=True,
            check=True, timeout=10).stdout

    def show_qr(self, _):
        index = self.network.get_active()
        if self.busy or self.config is None or self.dirty() or not 0 <= index < len(self.networks):
            return
        config, adapter = dict(self.config), dict(self.networks[index])
        self.async_work(
            lambda: self.qr_png(config, adapter, socket.gethostname()),
            self.display_qr,
            working_message='Generating QR code…',
            error_message='Could not generate the QR code. Build and reinstall the Linux QR helper.',
        )

    def display_qr(self, png):
        loader = GdkPixbuf.PixbufLoader.new_with_type('png')
        loader.write(png)
        loader.close()
        dialog = Gtk.Dialog(title='Pair this PC', transient_for=self, modal=True)
        dialog.add_button('Close', Gtk.ResponseType.CLOSE)
        content = dialog.get_content_area()
        content.set_border_width(16)
        content.set_spacing(12)
        instruction = Gtk.Label(label='In the Android app, open Connection → Scan PC QR code.')
        instruction.set_line_wrap(True)
        content.pack_start(instruction, False, False, 0)
        scroll = Gtk.ScrolledWindow()
        scroll.set_min_content_width(320)
        scroll.set_max_content_width(520)
        scroll.set_max_content_height(520)
        scroll.set_propagate_natural_width(True)
        scroll.set_propagate_natural_height(True)
        scroll.add(Gtk.Image.new_from_pixbuf(loader.get_pixbuf()))
        content.pack_start(scroll, True, True, 0)
        privacy = Gtk.Label(label='This code includes your access token. Keep it private.')
        privacy.set_line_wrap(True)
        content.pack_start(privacy, False, False, 0)
        self.feedback.set_text('QR code ready. Scan it with the Android app.')
        dialog.show_all()
        dialog.run()
        dialog.destroy()

    def refresh(self):
        if self.closed:
            return False
        if self.busy or self.polling:
            return True
        self.polling = True
        config = self.config

        def worker():
            try:
                state = control.service_state()
                networks = control.adapters()
                with open('/proc/uptime') as uptime:
                    seconds = int(float(uptime.read().split()[0]))
                message = 'Running' if state.get('ActiveState') == 'active' else state.get('ActiveState', 'Unknown')
                if state.get('LoadState') != 'loaded':
                    message = 'Agent is not installed'
                elif state.get('ActiveState') == 'active' and config:
                    request = urllib.request.Request(control.agent_url(config, '127.0.0.1') + '/v1/status',
                                                     headers={'Authorization': 'Bearer ' + config['token']})
                    try:
                        with urllib.request.urlopen(request, timeout=2) as response:
                            json.load(response)
                        message = 'Running · connection verified'
                    except Exception:
                        message = 'Running · API unreachable or authentication mismatch'
            except Exception:
                state, networks, seconds, message = {}, [], 0, 'Could not read agent status'

            def finish():
                self.polling = False
                if self.closed:
                    return False
                if self.busy or config != self.config:
                    return False
                self.state = state
                self.status.set_text('Agent: ' + message)
                self.uptime.set_text(f'Uptime {seconds // 86400}d {(seconds // 3600) % 24}h {(seconds // 60) % 60}m')
                self.startup.set_text('Start at boot: ' + state.get('UnitFileState', 'unknown'))
                if networks != self.networks:
                    previous = self.network.get_active()
                    previous_ip = self.networks[previous]['ip'] if 0 <= previous < len(self.networks) else None
                    self.networks = networks
                    self.network.remove_all()
                    for adapter in networks:
                        self.network.append_text(f"{adapter['name']} — {adapter['ip']}")
                    selected = next((i for i, a in enumerate(networks) if a['ip'] == previous_ip), 0)
                    self.network.set_active(selected if networks else -1)
                self.update_network()
                return False
            GLib.idle_add(finish)
        threading.Thread(target=worker, daemon=True).start()
        return True


class Application(Gtk.Application):
    def __init__(self):
        super().__init__(application_id='com.wakedesk.Control', flags=Gio.ApplicationFlags.FLAGS_NONE)

    def do_activate(self):
        window = self.get_active_window()
        if window is None:
            window = Panel(self)
        window.present()


if __name__ == '__main__':
    Application().run()
