import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import control


class ConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.path = Path(self.folder.name) / 'config.json'
        self.original = {'listen': '0.0.0.0:8787', 'token': 'a' * 64,
                         'tls_cert': '/etc/wakedesk/cert.pem',
                         'tls_key': '/etc/wakedesk/key.pem', 'extra': True}
        self.path.write_text(json.dumps(self.original))

    @patch('control.service_state', return_value={'ActiveState': 'inactive'})
    def test_atomic_save_preserves_tls_and_protects_credentials(self, _):
        update = {'listen': '192.168.1.50:8788', 'token': 'b' * 64}
        saved = control.save_config(update, self.path)
        self.assertEqual(saved, {**self.original, **update})
        self.assertEqual(json.loads(self.path.read_text()), saved)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    @patch('control.service_state', return_value={'ActiveState': 'active'})
    def test_running_service_cannot_change_config(self, _):
        with self.assertRaises(ValueError):
            control.save_config({'listen': '0.0.0.0:8787', 'token': 'b' * 64}, self.path)
        self.assertEqual(json.loads(self.path.read_text()), self.original)

    @patch('control.service_state', return_value={'ActiveState': 'inactive'})
    def test_invalid_or_unexpected_fields_do_not_modify_config(self, _):
        for update in ({'listen': 'host/path:8787', 'token': 'b' * 64},
                       {'listen': '0.0.0.0:0', 'token': 'b' * 64},
                       {'listen': '0.0.0.0:8787', 'token': 'short'},
                       {'listen': '0.0.0.0:8787', 'token': 'b' * 64, 'tls_key': 'changed'}):
            with self.subTest(update=update), self.assertRaises(ValueError):
                control.save_config(update, self.path)
        self.assertEqual(json.loads(self.path.read_text()), self.original)

    def test_missing_listen_uses_agent_default(self):
        self.path.write_text(json.dumps({'token': 'a' * 64}))
        self.assertEqual(control.read_config(self.path)['listen'], '127.0.0.1:8787')

    def test_urls_respect_binding_and_tls(self):
        self.assertEqual(control.agent_url(self.original, '192.168.1.50'),
                         'https://192.168.1.50:8787')
        self.assertEqual(control.agent_url({'listen': '127.0.0.1:8787'}, '192.168.1.50'),
                         'http://127.0.0.1:8787')
        self.assertEqual(control.agent_url({'listen': '[::]:8787'}, '192.168.1.50'),
                         'http://192.168.1.50:8787')
        self.assertEqual(control.agent_url({'listen': '[::1]:8787'}, '192.168.1.50'),
                         'http://[::1]:8787')

    @patch('control.run')
    def test_network_broadcast_uses_actual_prefix(self, run):
        run.return_value = json.dumps([
            {'ifname': 'lo', 'flags': ['LOOPBACK'], 'address': '00:00:00:00:00:00'},
            {'ifname': 'eth0', 'flags': ['UP'], 'address': 'aa:bb:cc:dd:ee:ff',
             'addr_info': [{'family': 'inet', 'scope': 'global',
                            'local': '10.0.1.4', 'prefixlen': 23}]},
        ])
        self.assertEqual(control.adapters(), [{'name': 'eth0', 'ip': '10.0.1.4',
                                              'mac': 'AA:BB:CC:DD:EE:FF',
                                              'broadcast': '10.0.1.255'}])
        run.assert_called_once_with('ip', '-j', 'address', 'show', 'up')

    @patch('control.os.geteuid', return_value=0)
    @patch('control.run')
    @patch('control.sys.argv', ['control.py', 'restart-other-service'])
    def test_helper_rejects_unknown_operations(self, run, _):
        with self.assertRaises(ValueError):
            control.main()
        run.assert_not_called()


if __name__ == '__main__':
    unittest.main()
