# SPDX-License-Identifier: GPL-3.0-only
import copy
import importlib.util
import ipaddress
import json
import os
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest
import uuid
import zipfile

spec = importlib.util.spec_from_file_location('data', Path(__file__).resolve().parents[1] / 'lib/data.py')
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)


def deployment():
    return d.state({'format': 2, 'options': d.profile({'PUBLIC_IP': '203.0.113.5'}),
        'identity': {'private_key': 'A' * 43, 'public_key': 'B' * 43},
        'clients': [{'name': 'alice', 'id': '12345678-1234-4234-8234-123456789abc', 'short_id': 'aabb'}],
        'short_ids': ['aabb'], 'rotation': None, 'xray_version': 'v26.3.27'})


class DataTests(unittest.TestCase):
    def test_ports(self):
        for value, expected in [('1', '1'), ('65535', '65535'), ('00008', '8')]:
            self.assertEqual(d.port(value), expected)
        for value in ['0', '65536', '-1', '0x10', '1;id', '9' * 50, 443, True]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                d.port(value)

    def test_endpoints(self):
        for value in ['1.2.3.4:443', 'example.com:443', '[2001:db8::1]:443']:
            self.assertEqual(d.endpoint(value), value)
        for value in ['::1:443', '[::gg]:443', '1.2.3.999:443', 'x;id:443', 'x\n:443', 'https://example.com:443', '[fe80::1%eth0]:443', '-host:443']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                d.endpoint(value)

    def test_shortids(self):
        self.assertEqual(d.sid('AA00'), 'aa00')
        for value in ['', 'a', 'abc', '0' * 18, 'xx', 123]:
            with self.assertRaises(ValueError):
                d.sid(value)

    def test_profile_defaults(self):
        p = d.profile({})
        self.assertEqual(p['BLOCK_PRIVATE_OUTBOUND'], 'yes')
        for k in ('SSH_HARDENING', 'FAIL2BAN_ENABLED', 'UNATTENDED_UPGRADES_ENABLED', 'ALLOW_PRERELEASE'):
            self.assertEqual(p[k], 'no')
        self.assertEqual(p['FIREWALL_STYLE'], 'none')
        self.assertEqual(p['XRAY_UPDATE_POLICY'], 'manual')

    def test_public_ip_discovery_requires_a_global_literal(self):
        self.assertEqual(d.public_ip(' 8.8.8.8\n'), '8.8.8.8')
        self.assertEqual(d.public_ip('2606:4700:4700::1111'), '2606:4700:4700::1111')
        for value in ['', 'proxy.example.com', '<html>error</html>', '127.0.0.1',
                      '10.0.0.1', '169.254.169.254', '::', '::1', 'fc00::1',
                      'ff02::1', 'fe80::1%eth0', '8.8.8.8\n1.1.1.1']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                d.public_ip(value)

    def test_profile_reload_preserves_the_deployed_client_address(self):
        with tempfile.TemporaryDirectory() as tmp:
            saved = Path(tmp) / 'state.json'
            requested = Path(tmp) / 'profile.json'
            s = deployment(); s['options']['PUBLIC_IP'] = 'proxy.example.com'
            saved.write_text(json.dumps(s))
            for options, expected in [({}, 'proxy.example.com'),
                                      ({'PUBLIC_IP': ''}, ''),
                                      ({'PUBLIC_IP': 'other.example.com'}, 'other.example.com')]:
                requested.write_text(json.dumps(options))
                result = subprocess.check_output([sys.executable, str(Path(d.__file__)),
                    'profile-deployed', str(requested), str(saved)], text=True)
                self.assertEqual(json.loads(result)['PUBLIC_IP'], expected)

    def test_profile_strict(self):
        for value in [{'UNSUPPORTED': 'yes'}, {'LISTEN_PORT': 443}, {'FIREWALL_STYLE': 'iptables'}, {'SERVER_NAME': 'x; return 200;'}, {'LISTEN_PORT': '22'}, {'OS_PRIVATE_OUTBOUND': 'yes'}, {'SHORT_ID_COUNT': '999'}, {'profile_format': '9'}]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                d.profile(value)
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'duplicate.json'
            p.write_text('{"LISTEN_PORT":"443","LISTEN_PORT":"444"}')
            with self.assertRaises(ValueError):
                d.load(p)
            p.write_text(json.dumps({'\x1b[2J': 'untrusted'}))
            result = subprocess.run([sys.executable, str(Path(d.__file__)), 'profile', str(p)], text=True, capture_output=True)
            self.assertEqual(result.returncode, 2)
            self.assertNotIn('\x1b', result.stderr)
            self.assertIn('\\u001b', result.stderr)

    def test_json_input_bounds_and_regular_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'large.json'
            p.write_text(' ' * (2 * 1024 * 1024 + 1))
            with self.assertRaisesRegex(ValueError, '2 MiB'):
                d.load(p)
            fifo = Path(tmp) / 'pipe'
            os.mkfifo(fifo)
            result = subprocess.run([sys.executable, str(Path(d.__file__)), 'profile', str(fifo)], text=True, capture_output=True, timeout=3)
            self.assertEqual(result.returncode, 2)
            self.assertIn('regular file', result.stderr)

    def test_config_has_ipondemand_and_both_families(self):
        s = deployment()
        cfg = d.config(s)
        self.assertEqual(cfg['routing']['domainStrategy'], 'IPOnDemand')
        self.assertEqual(cfg['outbounds'][0]['streamSettings']['sockopt']['domainStrategy'], 'UseIP')
        self.assertEqual(cfg['dns']['queryStrategy'], 'UseIP')
        self.assertEqual(cfg['inbounds'][0]['listen'], '::')
        self.assertNotIn('fallbacks', cfg['inbounds'][0]['settings'])
        self.assertEqual(cfg['inbounds'][0]['streamSettings']['realitySettings']['target'], s['options']['DEST_ENDPOINT'])
        ranges = [ipaddress.ip_network(cidr) for cidr in cfg['routing']['rules'][0]['ip']]
        for value in ['127.0.0.1', '10.0.0.1', '169.254.169.254', '100.64.0.1', '::1', 'fc00::1', 'fe80::1', '::ffff:127.0.0.1', '64:ff9b::a00:1']:
            address = ipaddress.ip_address(value)
            if address.version == 6 and address.ipv4_mapped:
                address = address.ipv4_mapped
            self.assertTrue(any(address.version == r.version and address in r for r in ranges), value)
        for value in ['8.8.8.8', '2606:4700:4700::1111']:
            address = ipaddress.ip_address(value)
            self.assertFalse(any(address.version == r.version and address in r for r in ranges), value)

    def test_add_remove_rotate(self):
        s = deployment()
        original = copy.deepcopy(s)
        d.mutate(s, 'add-client', 'bob', 0)
        self.assertEqual(s['clients'][0], original['clients'][0])
        self.assertNotEqual(s['clients'][0]['id'], s['clients'][1]['id'])
        with self.assertRaises(ValueError):
            d.mutate(s, 'add-client', 'bob', 0)
        old = s['clients'][1]['id']
        d.mutate(s, 'rotate-client', 'bob', 0)
        self.assertNotEqual(old, s['clients'][1]['id'])
        d.mutate(s, 'remove-client', 'bob', 0)
        self.assertEqual(s['clients'], original['clients'])
        self.assertEqual(s['short_ids'], original['short_ids'])
        with self.assertRaises(ValueError):
            d.mutate(s, 'remove-client', 'alice', 0)
        with self.assertRaises(ValueError):
            d.mutate(s, 'remove-client', 'missing', 0)

    def test_rotation_phases_and_keys_preserved(self):
        s = deployment()
        old_id = s['clients'][0]['id']
        keys = copy.deepcopy(s['identity'])
        d.mutate(s, 'rotate-shortid', '', 0)
        self.assertIn('aabb', s['short_ids'])
        self.assertIn(s['clients'][0]['short_id'], s['short_ids'])
        self.assertNotEqual('aabb', s['clients'][0]['short_id'])
        with self.assertRaises(ValueError):
            d.mutate(s, 'rotate-shortid', '', 0)
        d.mutate(s, 'finalize-shortid', '', 0)
        self.assertNotIn('aabb', s['short_ids'])
        self.assertEqual(keys, s['identity'])
        self.assertEqual(old_id, s['clients'][0]['id'])
        d.mutate(s, 'rotate-shortid', '', 3600)
        with self.assertRaises(ValueError):
            d.mutate(s, 'finalize-shortid', '', 0)

    def test_rotation_capacity_and_shared_shortid_removal(self):
        s = deployment()
        for i in range(1, 1024):
            short_id = f'{i:016x}'
            s['clients'].append({'name':str(i), 'id':str(uuid.uuid4()), 'short_id':short_id})
            s['short_ids'].append(short_id)
        s['short_ids'] += [f'ffffffffff{i:06x}' for i in range(15)]
        d.mutate(s, 'rotate-shortid', '', 0)
        self.assertEqual(len(s['clients']), 1024)
        self.assertEqual(len(s['short_ids']), 2063)
        d.mutate(s, 'remove-client', '1', 0)
        d.mutate(s, 'finalize-shortid', '', 0)
        self.assertEqual(len(s['short_ids']), 1023)
        s = deployment()
        s['clients'].append({'name':'shared', 'id':str(uuid.uuid4()), 'short_id':'aabb'})
        d.mutate(s, 'remove-client', 'shared', 0)
        self.assertEqual(s['short_ids'], ['aabb'])

    def test_exports_unicode_ipv6_and_permissions(self):
        s = deployment()
        s['clients'][0]['name'] = '../é snow / $(id)'
        s['options']['PUBLIC_IP'] = '2001:db8::5'
        with tempfile.TemporaryDirectory() as tmp:
            d.export(s, s['clients'][0]['name'], tmp)
            files = list(Path(tmp).iterdir())
            self.assertEqual(len(files), 4)
            uri = next(p for p in files if p.name.endswith('.uri.txt')).read_text()
            self.assertIn('@[2001:db8::5]:443', uri)
            self.assertIn('%C3%A9', uri)
            self.assertIn('%24%28id%29', uri)
            for p in files:
                self.assertEqual(p.stat().st_mode & 0o777, 0o600)
                self.assertNotIn(s['identity']['private_key'], p.read_text())
                if p.suffix == '.json':
                    json.loads(p.read_text())

    def test_export_rejects_symlink(self):
        s = deployment()
        import hashlib
        prefix = hashlib.sha256(b'alice').hexdigest()[:24]
        with tempfile.TemporaryDirectory() as tmp:
            target = Path(tmp) / 'unrelated'
            target.write_text('untouched')
            (Path(tmp) / (prefix + '-primary.uri.txt')).symlink_to(target)
            with self.assertRaises(OSError):
                d.export(s, 'alice', tmp)
            self.assertEqual(target.read_text(), 'untouched')

    def test_archive_traversal_and_symlink(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / 'release.zip'
            for unsafe in ('../escape', '/tmp/escape', 'bad\\file'):
                with zipfile.ZipFile(p, 'w') as z:
                    z.writestr(unsafe, 'bad')
                with self.assertRaises(ValueError):
                    d.extract(p, Path(tmp) / 'unpack')
            with zipfile.ZipFile(p, 'w') as z:
                i = zipfile.ZipInfo('xray')
                i.external_attr = 0o120777 << 16
                z.writestr(i, '/etc/passwd')
            with self.assertRaises(ValueError):
                d.extract(p, Path(tmp) / 'unpack')

    def test_os_egress_contradictions_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            options = Path(tmp) / 'options.json'
            resolver = Path(tmp) / 'resolv.conf'
            resolver.write_text('nameserver 127.0.0.53\n')
            p = d.profile({'FIREWALL_STYLE':'nftables', 'OS_PRIVATE_OUTBOUND':'yes'})
            options.write_text(json.dumps(p))
            with self.assertRaises(ValueError):
                d.egress_check(options, resolver)
            p['DEST_ENDPOINT'] = '1.1.1.1:443'
            options.write_text(json.dumps(p))
            d.egress_check(options, resolver)
            p['DNS_SERVERS'] = '127.0.0.1'
            options.write_text(json.dumps(p))
            with self.assertRaises(ValueError):
                d.egress_check(options, resolver)


    def test_state_validation(self):
        for mutation in [lambda s: s.update(format=3), lambda s: s['clients'][0].update(id='abc'),
                         lambda s: s.update(clients=[]), lambda s: s['identity'].update(private_key='bad'),
                         lambda s: s['clients'][0].update(short_id='ccdd')]:
            s = deployment()
            mutation(s)
            with self.assertRaises(ValueError):
                d.state(s)

    def test_legacy_migration_preserves_credentials(self):
        s = deployment()
        with tempfile.TemporaryDirectory() as tmp:
            cfg = Path(tmp) / 'config.json'
            legacy_cfg = d.config(s)
            legacy_cfg['inbounds'][0]['tag'] = 'vless-reality-primary'
            cfg.write_text(json.dumps(legacy_cfg))
            env = Path(tmp) / 'state.env'
            env.write_text("PROFILE_NAME=alice\nFAIL2BAN_ENABLED=no\nXRAY_VERSION=v26.3.27\nUUID=" + s['clients'][0]['id'] +
                '\nREALITY_PRIVATE_KEY=' + s['identity']['private_key'] + '\nREALITY_PUBLIC_KEY=' + s['identity']['public_key'] + '\n')
            result = d.legacy(env, cfg)
            self.assertEqual(result['identity'], s['identity'])
            self.assertEqual(result['clients'], s['clients'])
            for payload in ['UUID=$(touch /tmp/should-never-exist)', 'UUID=`id`', 'EVIL=x', 'UUID=foo;id']:
                env.write_text(payload + '\n')
                with self.assertRaises(ValueError):
                    d.legacy(env, cfg)

    def test_legacy_printf_q_unicode_and_metacharacters(self):
        for locale in ('C', 'C.UTF-8'):
            for value in ['', 'alice', 'café 日本語', "a 'quote' \\ trailing", '$() `touch /tmp/no` ; a&b', '\tline\n']:
                encoded = subprocess.check_output(['bash', '-c', 'printf %q "$1"', '_', value],
                    env={**os.environ, 'LC_ALL': locale}, text=True)
                self.assertEqual(d.legacy_word(encoded), value)
        for value in ["$'bad\\'", "$'bad\\x'", "$'unescaped'quote'", '$(touch /tmp/no)', 'foo;bar']:
            with self.assertRaises(ValueError):
                d.legacy_word(value)

    def test_legacy_preserves_bind_and_rejects_network_mismatch(self):
        s = deployment()
        cfg = d.config(s)
        cfg['inbounds'][0]['listen'] = '0.0.0.0'
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'config.json'
            path.write_text(json.dumps(cfg))
            env = Path(tmp) / 'state.env'
            original = ('PROFILE_NAME=alice\nXRAY_VERSION=v26.3.27\nUUID=' + s['clients'][0]['id']
                + '\nREALITY_PRIVATE_KEY=' + s['identity']['private_key']
                + '\nREALITY_PUBLIC_KEY=' + s['identity']['public_key'] + '\n')
            env.write_text(original)
            self.assertEqual(d.legacy(env, path)['options']['LISTEN_ADDRESS'], '0.0.0.0')
            options = Path(tmp) / 'profile.json'
            for value, expected in [({'profile_format':'1'}, '0.0.0.0'), ({'LISTEN_ADDRESS':'::'}, '::')]:
                options.write_text(json.dumps(value))
                result = subprocess.check_output([sys.executable, str(Path(d.__file__)), 'profile-legacy',
                    str(options), str(env), str(path)], text=True)
                self.assertEqual(json.loads(result)['LISTEN_ADDRESS'], expected)
            for field, value in [('LISTEN_PORT', '8443'), ('LISTEN_ADDRESS', '::'),
                                 ('SERVER_NAME', 'example.com'), ('DEST_ENDPOINT', 'example.com:443'),
                                 ('FALLBACK_PORT', '9443')]:
                env.write_text(original + field + '=' + value + '\n')
                with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'network mismatch'):
                    d.legacy(env, path)
            env.write_text(original)
            other = copy.deepcopy(cfg['inbounds'][0])
            other['tag'], other['port'] = 'vless-reality-fallback', 8443
            other['streamSettings']['realitySettings']['shortIds'] = ['ccdd']
            cfg['inbounds'].append(other)
            path.write_text(json.dumps(cfg))
            with self.assertRaisesRegex(ValueError, 'different REALITY credentials'):
                d.legacy(env, path)


if __name__ == '__main__':
    unittest.main()
