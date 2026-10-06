#!/usr/bin/python3
"""Fixed operations for the system agent; the desktop panel runs unprivileged."""
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

CONFIG = Path('/etc/wakedesk/config.json')
SERVICE = 'wakedesk-agent.service'
ACTIONS = {
    'start': ['start'],
    'stop': ['stop'],
    'enable': ['enable'],
    'disable': ['disable'],
}


def run(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True,
                          timeout=30).stdout


def service_state():
    raw = run('systemctl', 'show', SERVICE, '--property=ActiveState',
              '--property=UnitFileState', '--property=LoadState')
    return dict(line.split('=', 1) for line in raw.splitlines() if '=' in line)


def validate(config):
    listen = config.get('listen', '127.0.0.1:8787')
    if not isinstance(listen, str):
        raise ValueError('Enter an IP address and port, such as 0.0.0.0:8787.')
    try:
        host, port = listen.rsplit(':', 1)
        if host.startswith('[') and host.endswith(']'):
            host = host[1:-1]
        elif ':' in host:
            raise ValueError()
        if host not in ('', 'localhost'):
            ipaddress.ip_address(host)
        if not port.isascii() or not port.isdecimal() or not 1 <= int(port) <= 65535:
            raise ValueError()
    except ValueError:
        raise ValueError('Enter an IP address and port, such as 0.0.0.0:8787.') from None
    token = config.get('token')
    if not isinstance(token, str) or not 32 <= len(token) <= 1024 or any(c.isspace() for c in token):
        raise ValueError('Use a token of at least 32 characters without spaces.')
    if bool(config.get('tls_cert')) != bool(config.get('tls_key')):
        raise ValueError('Both TLS certificate and key must be configured.')


def read_config(path=CONFIG):
    config = json.loads(path.read_text())
    if not isinstance(config, dict):
        raise ValueError('Invalid agent configuration.')
    config.setdefault('listen', '127.0.0.1:8787')
    validate(config)
    return config


def save_config(update, path=CONFIG):
    # Only update panel fields; preserve TLS and any other existing settings.
    if not isinstance(update, dict) or set(update) != {'listen', 'token'}:
        raise ValueError('Only listen address and token can be updated.')
    if service_state().get('ActiveState') not in ('inactive', 'failed'):
        raise ValueError('Stop the agent before saving settings.')
    config = read_config(path)
    config.update(update)
    validate(config)
    fd, temporary = tempfile.mkstemp(prefix='.config-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as output:
            json.dump(config, output)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return config


def adapters():
    result = []
    for interface in json.loads(run('ip', '-j', 'address', 'show', 'up')):
        if 'LOOPBACK' in interface.get('flags', []):
            continue
        mac = interface.get('address', '').upper()
        if not mac or mac == '00:00:00:00:00:00':
            continue
        for address in interface.get('addr_info', []):
            if address.get('family') != 'inet' or address.get('scope') != 'global':
                continue
            network = ipaddress.ip_network(
                f"{address['local']}/{address['prefixlen']}", strict=False)
            result.append({'name': interface['ifname'], 'ip': address['local'],
                           'mac': mac, 'broadcast': str(network.broadcast_address)})
    # Prefer physical network interfaces over Docker and other virtual bridges.
    result.sort(key=lambda item: (not Path('/sys/class/net', item['name'], 'device').exists(), item['name']))
    return result


def agent_url(config, address):
    host, port = config['listen'].rsplit(':', 1)
    host = host.strip('[]')
    if host in ('', '0.0.0.0', '::'):
        host = address
    if ':' in host:
        host = f'[{host}]'
    scheme = 'https' if config.get('tls_cert') else 'http'
    return f'{scheme}://{host}:{port}'


def main():
    if os.geteuid() != 0:
        raise ValueError('Administrator authentication is required.')
    if len(sys.argv) != 2:
        raise ValueError('Choose one agent operation.')
    action = sys.argv[1]
    if action == 'read':
        print(json.dumps(read_config()))
    elif action == 'save':
        raw = sys.stdin.read(8193)
        if len(raw) > 8192:
            raise ValueError('Settings are too large.')
        print(json.dumps(save_config(json.loads(raw))))
    elif action in ACTIONS:
        run('systemctl', *ACTIONS[action], SERVICE)
    else:
        raise ValueError('Unknown agent operation.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError):
        # Never echo subprocess input or configuration values into diagnostics.
        print('Could not complete the operation. Check that the agent is installed, '
              'stop it before editing, and verify the settings.', file=sys.stderr)
        sys.exit(1)
