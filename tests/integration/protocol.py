#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real Xray processes and local DNS/TLS/HTTP fixtures; no systemd claims."""
import argparse
import base64
import contextlib
import copy
import http.server
import importlib.util
import json
import os
from pathlib import Path
import re
import socket
import ssl
import struct
import subprocess
import tempfile
import threading
import time
import uuid

root = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('data', root / 'lib/data.py')
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)


def free_port(family=socket.AF_INET):
    with socket.socket(family) as s:
        s.bind(('::1' if family == socket.AF_INET6 else '127.0.0.1', 0))
        return s.getsockname()[1]


class Handler(http.server.BaseHTTPRequestHandler):
    hits = 0

    def do_GET(self):
        Handler.hits += 1
        self.send_response(200)
        self.send_header('Content-Length', '11')
        self.end_headers()
        self.wfile.write(b'local-proof')

    def log_message(self, *args):
        pass


def dns_fixture():
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(('127.0.0.1', 0))
    def run():
        while True:
            try:
                packet, peer = sock.recvfrom(4096)
                offset = 12
                labels = []
                while packet[offset]:
                    labels.append(packet[offset + 1:offset + 1 + packet[offset]].decode('ascii'))
                    offset += 1 + packet[offset]
                offset += 1
                qtype = struct.unpack('!H', packet[offset:offset + 2])[0]
                end = offset + 4
                hostname = '.'.join(labels)
                address = (socket.inet_pton(socket.AF_INET6, '2001:db8::1' if hostname == 'dual.test' else '::1')
                           if qtype == 28 else socket.inet_aton('127.0.0.2' if hostname == 'dual6.test' else '127.0.0.1'))
                answer = b'\xc0\x0c' + struct.pack('!HHIH', qtype, 1, 60, len(address)) + address
                # Each hostname has exactly one family, for deterministic controls.
                count = int(hostname in ('dual.test', 'dual6.test') or ((qtype == 28) == (hostname == 'private6.test')))
                if not count:
                    answer = b''
                header = packet[:2] + struct.pack('!HHHHH', 0x8180, 1, count, 0, 0)
                sock.sendto(header + packet[12:end] + answer, peer)
            except OSError:
                return
    threading.Thread(target=run, daemon=True).start()
    return sock


def wait_port(port, process):
    for _ in range(50):
        if process.poll() is not None:
            raise AssertionError('Xray process exited; inspect protected test logs')
        try:
            with socket.create_connection(('127.0.0.1', port), timeout=.1):
                return
        except OSError:
            time.sleep(.1)
    raise AssertionError('Xray listener did not appear')


def write_json(path, value):
    path.write_text(json.dumps(value))


def main(binary):
    print(subprocess.check_output([binary, 'version'], text=True).splitlines()[0])
    with tempfile.TemporaryDirectory(prefix='xray-protocol-') as tmp, contextlib.ExitStack() as stack:
        tmp = Path(tmp)
        # Backup validation uses a staged filename, which need not end in .json.
        write_json(tmp / 'staged-config', {'outbounds': [{'protocol': 'freedom'}]})
        subprocess.run(['bash', '-c', 'source "$1"; WORK=$2; validate_xray "$3" "$2/staged-config" "$2"',
            '_', str(root / 'xray_reality_bootstrap.sh'), str(tmp), binary], check=True)
        print('PASS: staged configuration validation specifies JSON format')
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
            '-subj', '/CN=example.com', '-addext', 'subjectAltName=DNS:example.com',
            '-keyout', str(tmp / 'tls.key'), '-out', str(tmp / 'tls.crt')], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_3
        context.set_ecdh_curve('X25519')
        context.set_alpn_protocols(['h2'])
        context.load_cert_chain(tmp / 'tls.crt', tmp / 'tls.key')
        class TLSHandler(Handler):
            def setup(self):
                self.request.settimeout(5)
                self.request = context.wrap_socket(self.request, server_side=True)
                super().setup()
        class QuietTLSHTTP(http.server.ThreadingHTTPServer):
            def handle_error(self, request, client_address):
                # Rejected credentials intentionally abort the forwarded TLS connection.
                pass
        target = QuietTLSHTTP(('127.0.0.1', 0), TLSHandler)
        stack.callback(target.server_close)
        threading.Thread(target=target.serve_forever, daemon=True).start()
        http_server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        stack.callback(http_server.server_close)
        threading.Thread(target=http_server.serve_forever, daemon=True).start()
        dns = dns_fixture()
        stack.callback(dns.close)
        ipv6_http = None
        try:
            class IPv6HTTP(http.server.ThreadingHTTPServer):
                address_family = socket.AF_INET6
            ipv6_http = IPv6HTTP(('::1', 0), Handler)
            stack.callback(ipv6_http.server_close)
            threading.Thread(target=ipv6_http.serve_forever, daemon=True).start()
        except OSError:
            print('SKIP IPv6 runtime: IPv6 loopback unavailable')
        keypair = subprocess.check_output([binary, 'x25519'], text=True)
        private = re.search(r'^PrivateKey: (\S+)', keypair, re.M)[1]
        public = re.search(r'^(?:Password(?: \(PublicKey\))?|PublicKey): (\S+)', keypair, re.M)[1]
        port = free_port()
        alternate_port = free_port()
        while alternate_port == port:
            alternate_port = free_port()
        state = d.state({'format': 2, 'options': d.profile({'PUBLIC_IP': '127.0.0.1',
            'LISTEN_ADDRESS': '127.0.0.1', 'LISTEN_PORT': str(port), 'FALLBACK_PORT': str(alternate_port), 'SERVER_NAME': 'example.com',
            'DEST_ENDPOINT': '127.0.0.1:' + str(target.server_port), 'BLOCK_PRIVATE_OUTBOUND': 'no'}),
            'identity': {'private_key': private, 'public_key': public},
            'clients': [{'name': 'alice', 'id': str(uuid.uuid4()), 'short_id': 'aabb'}],
            'short_ids': ['aabb'], 'rotation': None, 'xray_version': 'v26.3.27'})
        write_json(tmp / 'state.json', state)
        subprocess.run(['python3', str(root / 'lib/data.py'), 'key-der', str(tmp / 'state.json'), str(tmp / 'private.der')], check=True)
        subprocess.run(['openssl', 'pkey', '-inform', 'DER', '-in', str(tmp / 'private.der'), '-pubout', '-outform', 'DER', '-out', str(tmp / 'public.der')], check=True)
        encoded_public = base64.urlsafe_b64encode((tmp / 'public.der').read_bytes()[-32:]).decode().rstrip('=')
        assert public == encoded_public, 'Go/OpenSSL X25519 public key mismatch'
        print('PASS: keypair validation via protected files without private argv')
        server_path = tmp / 'server.json'
        server_process = None
        client_process = None

        def stop(process):
            if process is not None and process.poll() is None:
                process.terminate()
                process.wait(timeout=5)

        stack.callback(lambda: stop(server_process))
        stack.callback(lambda: stop(client_process))

        def start_server(s, routing_guard=True, prefer_ipv6=False):
            nonlocal server_process
            stop(server_process)
            cfg = d.config(s)
            cfg['outbounds'][0]['streamSettings']['sockopt']['happyEyeballs']['prioritizeIPv6'] = prefer_ipv6
            if not routing_guard:
                cfg['routing']['rules'] = []
            # Isolated fixture resolver allows deterministic private DNS responses.
            cfg['dns']['servers'] = [{'address': '127.0.0.1', 'port': dns.getsockname()[1]}]
            cfg['log'] = {'access': 'none', 'error': str(tmp / 'server-debug.log'), 'loglevel': 'debug'}
            write_json(server_path, cfg)
            subprocess.run([binary, 'run', '-test', '-config', str(server_path)], check=True, stdout=subprocess.DEVNULL)
            log = stack.enter_context(open(tmp / ('server-' + str(time.time_ns()) + '.log'), 'w'))
            server_process = subprocess.Popen([binary, 'run', '-config', str(server_path)], stdout=log, stderr=log)
            for _ in range(50):
                if server_process.poll() is not None:
                    raise AssertionError('Server startup failed')
                if subprocess.check_output(['ss', '-H', '-lnt', 'sport = :' + str(port)]):
                    break
                time.sleep(.1)
            else:
                raise AssertionError('Server listener absent')

        def request(s, client_name='alice', old_sid=None, old_uuid=None, host='127.0.0.1', http_port=None, alternate=False):
            nonlocal client_process
            stop(client_process)
            d.export(s, client_name, str(tmp / 'exports'))
            import hashlib
            prefix = hashlib.sha256(client_name.encode()).hexdigest()[:24]
            label = 'fallback' if alternate else 'primary'
            cfg = json.loads((tmp / 'exports' / (prefix + '-v2rayn-' + label + '.json')).read_text())
            if old_sid:
                cfg['outbounds'][0]['streamSettings']['realitySettings']['shortId'] = old_sid
            if old_uuid:
                cfg['outbounds'][0]['settings']['vnext'][0]['users'][0]['id'] = old_uuid
            socks = free_port()
            cfg['inbounds'] = [{'listen': '127.0.0.1', 'port': socks, 'protocol': 'socks', 'settings': {'auth': 'noauth'}}]
            cfg['log'] = {'error': str(tmp / 'client-debug.log'), 'loglevel': 'debug'}
            write_json(tmp / 'client.json', cfg)
            log = stack.enter_context(open(tmp / ('client-' + str(time.time_ns()) + '.log'), 'w'))
            client_process = subprocess.Popen([binary, 'run', '-config', str(tmp / 'client.json')], stdout=log, stderr=log)
            wait_port(socks, client_process)
            address = '[' + host + ']' if ':' in host else host
            response = subprocess.run(['curl', '--noproxy', '', '-fsS', '--max-time', '4',
                '--socks5-hostname', '127.0.0.1:' + str(socks), f'http://{address}:{http_port or http_server.server_port}/'],
                capture_output=True)
            return response.returncode == 0 and response.stdout == b'local-proof'

        start_server(state)
        if not request(state):
            for log_path in (tmp / 'server-debug.log', tmp / 'client-debug.log'):
                if log_path.exists():
                    content = log_path.read_text()
                    content = re.sub(r'[A-Za-z0-9_-]{43}|[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}', '<redacted>', content)
                    print(content[-12000:])
            raise AssertionError('VLESS REALITY Vision baseline failed')
        print('PASS: real VLESS + REALITY + Vision connection')
        assert request(state, alternate=True), 'Alternate REALITY listener failed'
        print('PASS: alternate REALITY listener and exported client configuration')
        assert request(state, host='private.test'), 'Private DNS positive control failed'
        if ipv6_http:
            assert request(state, host='private6.test', http_port=ipv6_http.server_port), 'IPv6 DNS positive control failed'
            assert request(state, host='dual6.test', http_port=ipv6_http.server_port), 'IPv4 failure did not fall back to IPv6'
        print('PASS: private DNS destinations work with filtering explicitly disabled')
        start_server(state, prefer_ipv6=True)
        assert request(state, host='dual.test'), 'IPv6 failure did not fall back to IPv4'
        print('PASS: Happy Eyeballs connects through the reachable address family')
        # Ordinary unauthenticated TLS gets the target certificate and target page.
        with socket.create_connection(('127.0.0.1', port), timeout=5) as conn:
            c = ssl.create_default_context(cafile=str(tmp / 'tls.crt'))
            c.minimum_version = ssl.TLSVersion.TLSv1_3
            with c.wrap_socket(conn, server_hostname='example.com') as tls:
                tls.sendall(b'GET / HTTP/1.0\r\nHost: example.com\r\n\r\n')
                content = b''
                while True:
                    part = tls.recv(4096)
                    if not part:
                        break
                    content += part
                assert b'local-proof' in content
        print('PASS: invalid REALITY authentication forwards to TLS target')
        d.mutate(state, 'add-client', 'bob', 0)
        start_server(state)
        assert request(state, 'alice') and request(state, 'bob')
        bob_old = d.find_client(state, 'bob')['id']
        d.mutate(state, 'rotate-client', 'bob', 0)
        start_server(state)
        assert request(state, 'bob') and not request(state, 'bob', old_uuid=bob_old)
        bob_rotated = d.find_client(state, 'bob')['id']
        d.mutate(state, 'remove-client', 'bob', 0)
        start_server(state)
        assert request(state, 'alice') and not request(state, 'alice', old_uuid=bob_rotated)
        print('PASS: multiple clients, UUID rotation/removal revocation')
        old_sid = d.find_client(state, 'alice')['short_id']
        d.mutate(state, 'rotate-shortid', '', 0)
        start_server(state)
        assert request(state) and request(state, old_sid=old_sid)
        d.mutate(state, 'finalize-shortid', '', 0)
        start_server(state)
        assert request(state) and not request(state, old_sid=old_sid)
        print('PASS: old/new shortIds accepted during overlap, old rejected after finalization')
        state['options']['BLOCK_PRIVATE_OUTBOUND'] = 'yes'
        start_server(state)
        before = Handler.hits
        assert not request(state, host='127.0.0.1')
        assert not request(state, host='::ffff:127.0.0.1')
        assert not request(state, host='private.test')
        assert not request(state, host='private.test', alternate=True)
        if ipv6_http:
            assert not request(state, host='::1', http_port=ipv6_http.server_port)
            assert not request(state, host='private6.test', http_port=ipv6_http.server_port)
        assert before == Handler.hits, 'Blocked destinations received requests'
        print('PASS: private IPv4/IPv6 literals and DNS hostname denied without reaching target')
        version = subprocess.check_output([binary, 'version'], text=True).split()[1]
        if tuple(map(int, version.split('.'))) >= (26, 10, 10):
            start_server(state, routing_guard=False)
            before = Handler.hits
            assert not request(state, host='127.0.0.1')
            assert not request(state, host='private.test')
            assert before == Handler.hits
            print('PASS: Freedom finalRules independently deny private literal and resolved addresses')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('binary')
    main(os.path.abspath(parser.parse_args().binary))
