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
        self.set_size_request(520, 600)
        self.set_border_width(0)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.config = None
        self.networks = []
        self.state = {}
        self.busy = False
        self.polling = False
        self.closed = False
        self.connect('destroy', self.close_panel)
        self.install_styles()

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        root.get_style_context().add_class('app-root')
        self.add(root)

        header = Gtk.Box(spacing=12)
        header.set_margin_start(18)
        header.set_margin_end(18)
        header.set_margin_top(14)
        header.set_margin_bottom(10)
        brand = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=1)
        title = Gtk.Label(label='WakeDesk', xalign=0)
        title.get_style_context().add_class('app-title')
        subtitle = Gtk.Label(label='Linux control center', xalign=0)
        subtitle.get_style_context().add_class('muted')
        brand.pack_start(title, False, False, 0)
        brand.pack_start(subtitle, False, False, 0)
        header.pack_start(brand, True, True, 0)
        self.header_state = Gtk.Label(label='CHECKING')
        self.header_state.get_style_context().add_class('status-pill')
        header.pack_end(self.header_state, False, False, 0)
        root.pack_start(header, False, False, 0)

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE,
                               transition_duration=160)
        switcher = Gtk.StackSwitcher(stack=self.stack, halign=Gtk.Align.CENTER)
        switcher.set_margin_start(16)
        switcher.set_margin_end(16)
        switcher.set_margin_bottom(10)
        root.pack_start(switcher, False, False, 0)
        root.pack_start(self.stack, True, True, 0)

        overview = self.page()
        overview_scroll = self.scroll_page(overview)
        self.stack.add_titled(overview_scroll, 'overview', 'Overview')
        status_card, status_body = self.card('Agent status', '')
        overview.pack_start(status_card, False, False, 0)
        self.status = Gtk.Label(label='Checking agent…', xalign=0)
        self.status.get_style_context().add_class('status-title')
        status_body.pack_start(self.status, False, False, 2)
        metrics = Gtk.Box(spacing=10, homogeneous=True)
        self.uptime = self.metric(metrics, 'UPTIME', '—')
        self.startup = self.metric(metrics, 'START AT BOOT', '—')
        status_body.pack_start(metrics, False, False, 4)

        actions_card, actions = self.card('Agent controls', '')
        overview.pack_start(actions_card, False, False, 0)
        row = Gtk.Box(spacing=8, homogeneous=True)
        actions.pack_start(row, False, False, 0)
        self.start = self.button(row, 'Start', lambda _: self.operation('start'))
        self.start.get_style_context().add_class('suggested-action')
        self.stop = self.button(row, 'Stop', lambda _: self.operation('stop'))
        self.startup_button = self.button(row, 'Enable startup', self.toggle_startup)
        self.refresh_button = self.button(actions, 'Refresh status', lambda _: self.refresh())

        tip_card, tip = self.card('Quick setup', '')
        overview.pack_start(tip_card, False, False, 0)
        tip_label = Gtk.Label(
            label='1  Choose a wired adapter\n2  Pair with the QR code\n3  Enable Wake-on-LAN',
            xalign=0)
        tip.pack_start(tip_label, False, False, 0)
        open_connection = self.button(tip, 'Open connection settings',
                                      lambda _: self.stack.set_visible_child_name('connection'))
        open_connection.get_style_context().add_class('flat')

        connection = self.page()
        connection_scroll = self.scroll_page(connection)
        self.stack.add_titled(connection_scroll, 'connection', 'Connection')
        phone_card, phone = self.card('Phone connection', 'Pair and select the reachable wired network')
        connection.pack_start(phone_card, False, False, 0)
        phone_heading = Gtk.Box(spacing=8)
        phone.pack_start(phone_heading, False, False, 0)
        self.network = Gtk.ComboBoxText(hexpand=True)
        self.network.connect('changed', lambda _: self.update_network())
        phone_heading.pack_start(self.network, True, True, 0)
        self.qr_button = self.button(phone_heading, 'Show QR', self.show_qr)
        self.qr_button.get_style_context().add_class('suggested-action')
        self.wol_button = self.button(phone, 'Enable Wake-on-LAN for selected adapter', self.enable_wol)
        grid = Gtk.Grid(column_spacing=8, row_spacing=7)
        phone.pack_start(grid, False, False, 2)
        self.connection_fields = {}
        self.copy_buttons = []
        for i, (key, label) in enumerate((('url', 'Agent URL'), ('mac', 'MAC address'),
                                          ('broadcast', 'Broadcast'))):
            field_label = Gtk.Label(label=label, xalign=0)
            field_label.get_style_context().add_class('field-label')
            grid.attach(field_label, 0, i, 1, 1)
            entry = Gtk.Entry(hexpand=True, editable=False)
            grid.attach(entry, 1, i, 1, 1)
            button = Gtk.Button(label='Copy')
            button.get_style_context().add_class('compact')
            button.connect('clicked', lambda _, k=key: self.copy(k))
            grid.attach(button, 2, i, 1, 1)
            self.connection_fields[key] = entry
            self.copy_buttons.append(button)

        settings_card, settings = self.card('Agent settings', 'Protected connection credentials')
        connection.pack_start(settings_card, False, False, 0)
        self.unlock = self.button(settings, 'Unlock connection settings', self.load_config)
        self.hint = Gtk.Label(label='Authenticate to view the phone token and edit settings.', xalign=0)
        self.hint.set_line_wrap(True)
        self.hint.get_style_context().add_class('muted')
        settings.pack_start(self.hint, False, False, 0)
        grid = Gtk.Grid(column_spacing=8, row_spacing=7)
        settings.pack_start(grid, False, False, 2)
        self.fields = {}
        for i, (key, label) in enumerate((('listen', 'Listen address'), ('token', 'Access token'))):
            field_label = Gtk.Label(label=label, xalign=0)
            field_label.get_style_context().add_class('field-label')
            grid.attach(field_label, 0, i, 1, 1)
            entry = Gtk.Entry(hexpand=True)
            entry.connect('changed', lambda _: self.controls())
            grid.attach(entry, 1, i, 1, 1)
            self.fields[key] = entry
        self.fields['token'].set_visibility(False)
        options = Gtk.Box(spacing=8)
        settings.pack_start(options, False, False, 0)
        self.show_token = Gtk.CheckButton(label='Show token')
        self.show_token.connect('toggled', lambda button: self.fields['token'].set_visibility(button.get_active()))
        options.pack_start(self.show_token, False, False, 0)
        self.copy_token = self.button(options, 'Copy token', lambda _: self.copy('token'))
        options.pack_start(Gtk.Box(hexpand=True), True, True, 0)
        row = Gtk.Box(spacing=8, homogeneous=True)
        settings.pack_start(row, False, False, 0)
        self.generate = self.button(row, 'Generate', self.generate_token)
        self.discard = self.button(row, 'Discard', lambda _: self.fill_config())
        self.save = self.button(row, 'Save settings', self.save_config)
        self.save.get_style_context().add_class('suggested-action')

        security = self.page()
        security_scroll = self.scroll_page(security)
        self.stack.add_titled(security_scroll, 'security', 'Phone sign-in')
        unlock_card, unlock_body = self.card('Passwordless sign-in', 'Approve Ubuntu login from your enrolled phone')
        security.pack_start(unlock_card, False, False, 0)
        icon = Gtk.Image.new_from_icon_name('changes-prevent-symbolic', Gtk.IconSize.DIALOG)
        icon.set_halign(Gtk.Align.START)
        unlock_body.pack_start(icon, False, False, 2)
        self.unlock_status = Gtk.Label(label='No enrollment request loaded.', xalign=0)
        self.unlock_status.set_line_wrap(True)
        self.unlock_status.get_style_context().add_class('status-title')
        unlock_body.pack_start(self.unlock_status, False, False, 2)
        explainer = Gtk.Label(
            label='Enrollment requires local administrator approval. Sign-in approvals expire quickly and can only be used once.',
            xalign=0)
        explainer.set_line_wrap(True)
        explainer.get_style_context().add_class('muted')
        unlock_body.pack_start(explainer, False, False, 2)
        row = Gtk.Box(spacing=8, homogeneous=True)
        unlock_body.pack_start(row, False, False, 4)
        self.unlock_refresh = self.button(row, 'Check enrollment', self.check_unlock_enrollment)
        self.unlock_approve = self.button(row, 'Approve phone', self.approve_unlock_enrollment)
        self.unlock_approve.get_style_context().add_class('suggested-action')
        self.pending_unlock = None

        safety_card, safety = self.card('Safety', 'Your Ubuntu password remains available')
        security.pack_start(safety_card, False, False, 0)
        safety_text = Gtk.Label(
            label='If the phone is unavailable or an approval expires, sign in normally with your password.',
            xalign=0)
        safety_text.set_line_wrap(True)
        safety.pack_start(safety_text, False, False, 0)

        feedback_bar = Gtk.Box(spacing=9)
        feedback_bar.get_style_context().add_class('feedback-bar')
        feedback_bar.set_margin_start(12)
        feedback_bar.set_margin_end(12)
        feedback_bar.set_margin_top(8)
        feedback_bar.set_margin_bottom(10)
        self.spinner = Gtk.Spinner()
        feedback_bar.pack_start(self.spinner, False, False, 0)
        self.feedback = Gtk.Label(label='Ready', xalign=0, selectable=True, ellipsize=3)
        self.feedback.set_tooltip_text('Latest WakeDesk activity')
        feedback_bar.pack_start(self.feedback, True, True, 0)
        root.pack_end(feedback_bar, False, False, 0)
        self.controls()
        self.show_all()
        self.refresh()
        self.timer = GLib.timeout_add_seconds(5, self.refresh)

    @staticmethod
    def install_styles():
        css = b'''
        .app-root { background-color: @theme_bg_color; }
        .app-title { font-size: 24px; font-weight: 700; }
        .muted { color: alpha(@theme_fg_color, 0.65); font-size: 12px; }
        .card { background-color: @theme_base_color; border: 1px solid alpha(@theme_fg_color, 0.12); border-radius: 10px; }
        .card-title { font-size: 15px; font-weight: 700; }
        .status-title { font-size: 14px; font-weight: 600; }
        .status-pill { border-radius: 999px; padding: 5px 10px; font-size: 10px; font-weight: 700; background-color: alpha(@theme_fg_color, 0.10); }
        .status-good { color: #2ec27e; background-color: alpha(#26a269, 0.16); }
        .status-bad { color: #ff6b6b; background-color: alpha(#e01b24, 0.14); }
        .metric { background-color: alpha(@theme_fg_color, 0.045); border-radius: 8px; padding: 9px; }
        .metric-label, .field-label { color: alpha(@theme_fg_color, 0.62); font-size: 10px; font-weight: 700; }
        .metric-value { font-size: 14px; font-weight: 600; }
        .feedback-bar { background-color: @theme_base_color; border: 1px solid alpha(@theme_fg_color, 0.10); border-radius: 8px; padding: 8px 10px; }
        button.compact { padding: 3px 8px; }
        stackswitcher button { min-width: 118px; }
        '''
        provider = Gtk.CssProvider()
        provider.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    @staticmethod
    def page():
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        content.set_margin_start(16)
        content.set_margin_end(16)
        content.set_margin_top(2)
        content.set_margin_bottom(10)
        return content

    @staticmethod
    def scroll_page(content):
        scroll = Gtk.ScrolledWindow()
        scroll.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        scroll.set_overlay_scrolling(True)
        scroll.add(content)
        return scroll

    @staticmethod
    def card(title, subtitle):
        frame = Gtk.Frame()
        frame.set_shadow_type(Gtk.ShadowType.NONE)
        frame.get_style_context().add_class('card')
        body = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        body.set_margin_start(14)
        body.set_margin_end(14)
        body.set_margin_top(12)
        body.set_margin_bottom(12)
        heading = Gtk.Label(label=title, xalign=0)
        heading.get_style_context().add_class('card-title')
        body.pack_start(heading, False, False, 0)
        if subtitle:
            detail = Gtk.Label(label=subtitle, xalign=0)
            detail.get_style_context().add_class('muted')
            body.pack_start(detail, False, False, 0)
        frame.add(body)
        return frame, body

    @staticmethod
    def metric(parent, label, value):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        box.get_style_context().add_class('metric')
        caption = Gtk.Label(label=label, xalign=0)
        caption.get_style_context().add_class('metric-label')
        metric = Gtk.Label(label=value, xalign=0)
        metric.get_style_context().add_class('metric-value')
        box.pack_start(caption, False, False, 0)
        box.pack_start(metric, False, False, 0)
        parent.pack_start(box, True, True, 0)
        return metric

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
        self.refresh_button.set_sensitive(not self.busy and not self.polling)
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
        self.wol_button.set_sensitive(not self.busy and 0 <= self.network.get_active() < len(self.networks))
        self.unlock_refresh.set_sensitive(not self.busy)
        self.unlock_approve.set_sensitive(not self.busy and self.pending_unlock is not None)
        self.qr_button.set_sensitive(pairing and 0 <= self.network.get_active() < len(self.networks))
        for button in self.copy_buttons:
            button.set_sensitive(pairing and bool(self.networks))
        if self.config is not None:
            self.hint.set_text('Unsaved changes' if self.dirty() else
                               'Saved settings' if stopped else 'Settings are read-only while the agent is running.')
        if self.busy:
            self.spinner.start()
            self.spinner.set_opacity(1)
        else:
            self.spinner.stop()
            self.spinner.set_opacity(0)

    def set_header_state(self, text, style=None):
        context = self.header_state.get_style_context()
        for name in ('status-good', 'status-bad'):
            context.remove_class(name)
        if style:
            context.add_class(style)
        self.header_state.set_text(text)

    def async_work(self, work, done, working_message='Working… An administrator prompt may appear.',
                   error_message='Operation failed or authentication was canceled. Check the agent and settings.'):
        if self.busy:
            return
        self.busy = True
        self.feedback.set_text(working_message)
        self.set_header_state('WORKING')
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
                    self.set_header_state('ACTION NEEDED', 'status-bad')
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
        return json.loads(result.stdout) if action in ('read', 'save', 'enable-wol', 'unlock-pending', 'unlock-approve') else None

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

    def enable_wol(self, _):
        index = self.network.get_active()
        if not 0 <= index < len(self.networks):
            self.feedback.set_text('Choose a network adapter first.')
            return
        interface = self.networks[index]['name']

        def enabled(result):
            suffix = 'enabled now and saved.' if result['active'] else 'saved; reconnect or reboot to apply it.'
            self.feedback.set_text(f'Wake-on-LAN for {interface} is {suffix}')
        self.async_work(
            lambda: self.privileged('enable-wol', {'interface': interface}), enabled,
            working_message='Configuring Wake-on-LAN… An administrator prompt may appear.',
            error_message=('Could not enable Wake-on-LAN. Select a physical Ethernet adapter and '
                           'install NetworkManager and ethtool, then check BIOS/UEFI support.'),
        )

    def check_unlock_enrollment(self, _):
        def loaded(result):
            pending = result.get('enrollments', [])
            self.pending_unlock = pending[0] if pending else None
            if self.pending_unlock:
                item = self.pending_unlock
                self.unlock_status.set_text(
                    f"Pending: {item['name']} for Ubuntu user {item['user']}. Approve only if this is your phone.")
            else:
                self.unlock_status.set_text('No pending phone enrollment request.')
            self.controls()
        self.async_work(lambda: self.privileged('unlock-pending'), loaded,
                        working_message='Checking phone enrollment…')

    def approve_unlock_enrollment(self, _):
        if not self.pending_unlock:
            return
        request_id = self.pending_unlock['request_id']
        def approved(_result):
            self.pending_unlock = None
            self.unlock_status.set_text('Phone enrolled for Ubuntu sign-in.')
            self.feedback.set_text('Phone enrollment approved.')
        self.async_work(lambda: self.privileged('unlock-approve', {'request_id': request_id}), approved,
                        working_message='Approving phone enrollment…')

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
                self.status.set_text(message)
                self.uptime.set_text(
                    f'{seconds // 86400}d {(seconds // 3600) % 24}h {(seconds // 60) % 60}m')
                startup = state.get('UnitFileState', 'unknown')
                self.startup.set_text(startup.capitalize())
                if state.get('LoadState') != 'loaded':
                    self.set_header_state('NOT INSTALLED', 'status-bad')
                elif state.get('ActiveState') == 'active' and 'verified' in message:
                    self.set_header_state('ONLINE', 'status-good')
                elif state.get('ActiveState') == 'active':
                    self.set_header_state('RUNNING')
                else:
                    self.set_header_state('STOPPED', 'status-bad')
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
