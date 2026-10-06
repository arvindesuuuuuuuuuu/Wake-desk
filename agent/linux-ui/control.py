#!/usr/bin/python3
"""Fixed operations for the system agent; the desktop panel runs unprivileged."""
import ipaddress
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import socket

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


def enable_wol(interface):
    """Persist magic-packet wake for one active physical Ethernet adapter."""
    if not isinstance(interface, str) or not re.fullmatch(r'[A-Za-z0-9_.:-]{1,15}', interface):
        raise ValueError('Choose a valid network adapter.')
    available = {item['name'] for item in adapters()
                 if Path('/sys/class/net', item['name'], 'device').exists()}
    if interface not in available:
        raise ValueError('Choose an active physical network adapter.')
    if shutil.which('nmcli') is None:
        raise ValueError('NetworkManager is required to save Wake-on-LAN settings.')

    if shutil.which('ethtool') is not None:
        details = run('ethtool', interface)
        supported = next((line.split(':', 1)[1].strip() for line in details.splitlines()
                          if line.strip().startswith('Supports Wake-on:')), '')
        if 'g' not in supported:
            raise ValueError('The selected adapter does not support magic-packet wake.')

    device = run('nmcli', '-g', 'GENERAL.TYPE,GENERAL.CON-UUID',
                 'device', 'show', interface).splitlines()
    if len(device) < 2 or device[0].strip() != 'ethernet' or not device[1].strip():
        raise ValueError('The selected adapter is not an active NetworkManager Ethernet connection.')
    connection_uuid = device[1].strip()
    run('nmcli', 'connection', 'modify', 'uuid', connection_uuid,
        '802-3-ethernet.wake-on-lan', 'magic')

    # Reapply without intentionally disconnecting the phone or agent. Some
    # NetworkManager versions defer this property until the next reconnect.
    reapplied = subprocess.run(
        ('nmcli', 'device', 'reapply', interface), capture_output=True,
        text=True, timeout=30).returncode == 0
    if shutil.which('ethtool') is not None:
        run('ethtool', '-s', interface, 'wol', 'g')
        reapplied = True
    return {'interface': interface, 'active': reapplied}


def agent_url(config, address):
    host, port = config['listen'].rsplit(':', 1)
    host = host.strip('[]')
    if host in ('', '0.0.0.0', '::'):
        host = address
    if ':' in host:
        host = f'[{host}]'
    scheme = 'https' if config.get('tls_cert') else 'http'
    return f'{scheme}://{host}:{port}'


def unlock_request(path, data=None):
    body = json.dumps(data, separators=(',', ':')).encode() if data is not None else b''
    method = 'POST' if data is not None else 'GET'
    request = (f'{method} {path} HTTP/1.1\r\nHost: localhost\r\n'
               f'Content-Type: application/json\r\nConnection: close\r\n'
               f'Content-Length: {len(body)}\r\n\r\n').encode() + body
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(3)
    try:
        client.connect('/run/wakedesk/unlock.sock')
        client.sendall(request)
        chunks = []
        while True:
            chunk = client.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
    finally:
        client.close()
    response = b''.join(chunks)
    head, _, payload = response.partition(b'\r\n\r\n')
    if not head.startswith(b'HTTP/1.1 200 '):
        raise ValueError('The unlock service rejected the operation.')
    return json.loads(payload)


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
    elif action == 'enable-wol':
        raw = sys.stdin.read(1025)
        if len(raw) > 1024:
            raise ValueError('Settings are too large.')
        request = json.loads(raw)
        if not isinstance(request, dict) or set(request) != {'interface'}:
            raise ValueError('Choose one network adapter.')
        print(json.dumps(enable_wol(request['interface'])))
    elif action == 'unlock-pending':
        print(json.dumps(unlock_request('/pending')))
    elif action == 'unlock-approve':
        raw = sys.stdin.read(1025)
        if len(raw) > 1024:
            raise ValueError('Settings are too large.')
        request = json.loads(raw)
        if not isinstance(request, dict) or set(request) != {'request_id'}:
            raise ValueError('Choose one enrollment request.')
        print(json.dumps(unlock_request('/approve', request)))
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
