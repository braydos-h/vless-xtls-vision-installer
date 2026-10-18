#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Strict data handling. Never evaluate profiles or legacy shell state."""
import base64
import datetime
import hashlib
import ipaddress
import json
import os
import re
import secrets
import shlex
import stat
import sys
import uuid
import zipfile
from urllib.parse import quote

DEFAULTS = {
    'SERVER_NAME': 'www.cloudflare.com', 'DEST_ENDPOINT': 'www.cloudflare.com:443',
    'LISTEN_PORT': '443', 'FALLBACK_PORT': '', 'LISTEN_ADDRESS': '::',
    'FIREWALL_STYLE': 'none', 'SSH_HARDENING': 'no', 'SSH_PORT': '22',
    'CHANGE_SSH_PORT': 'no', 'HAS_SSH_KEYS': 'no', 'DISABLE_PASSWORD_AUTH': 'no',
    'FAIL2BAN_ENABLED': 'no', 'UNATTENDED_UPGRADES_ENABLED': 'no',
    'XRAY_UPDATE_POLICY': 'manual', 'ALLOW_PRERELEASE': 'no', 'XRAY_PIN': '', 'LOG_PROFILE': 'minimal',
    'PROFILE_NAME': 'reality-main', 'SHORT_ID_LABEL': 'main', 'SHORT_ID_COUNT': '3',
    'BLOCK_PRIVATE_OUTBOUND': 'yes', 'OS_PRIVATE_OUTBOUND': 'no',
    'DNS_SERVERS': '1.1.1.1,2606:4700:4700::1111',
    'XRAY_HANDSHAKE_TIMEOUT_SEC': '12', 'XRAY_CONN_IDLE_TIMEOUT_SEC': '600',
    'XRAY_UPLINK_ONLY_TIMEOUT_SEC': '4', 'XRAY_DOWNLINK_ONLY_TIMEOUT_SEC': '10',
    'CAMOUFLAGE_ENABLED': 'no', 'CAMOUFLAGE_WEB_PORT': '18080', 'PUBLIC_IP': ''
}
V4 = ['0.0.0.0/8', '10.0.0.0/8', '100.64.0.0/10', '127.0.0.0/8',
      '169.254.0.0/16', '172.16.0.0/12', '192.0.0.0/24', '192.0.2.0/24',
      '192.168.0.0/16', '198.18.0.0/15', '198.51.100.0/24', '203.0.113.0/24',
      '224.0.0.0/4', '240.0.0.0/4']
V6 = ['::/96', '::ffff:0:0/96', '64:ff9b::/96', '64:ff9b:1::/48',
      '100::/64', '2001::/32', '2001:db8::/32', '2002::/16',
      'fc00::/7', 'fe80::/10', 'fec0::/10', 'ff00::/8']


def fail(message):
    raise ValueError(message)


def pairs(items):
    result = {}
    for key, value in items:
        if key in result:
            fail('duplicate JSON key: ' + key)
        result[key] = value
    return result


def load(path):
    limit = 2 * 1024 * 1024
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(fd, encoding='utf-8') as f:
        info = os.fstat(f.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            fail('JSON input must be a regular file no larger than 2 MiB')
        text = f.read(limit + 1)
        if len(text) > limit:
            fail('JSON input exceeds 2 MiB')
        return json.loads(text, object_pairs_hook=pairs,
                          parse_constant=lambda _: fail('non-finite JSON number'))


def emit(value):
    print(json.dumps(value, ensure_ascii=False, indent=2))


def port(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]{1,5}', value):
        fail('port must be a decimal string of 1-5 digits')
    if not 1 <= int(value) <= 65535:
        fail('port outside 1-65535')
    return str(int(value))


def domain(value):
    if not isinstance(value, str) or len(value) > 253:
        fail('invalid hostname')
    if not re.fullmatch(r'(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', value):
        fail('use an ASCII fully qualified hostname (punycode for Unicode)')
    return value.lower()


def host(value):
    try:
        if '%' in value:
            fail('scoped addresses are unsupported')
        return str(ipaddress.ip_address(value))
    except ValueError:
        if re.fullmatch(r'[0-9.]+', value):
            fail('invalid IPv4 address')
        return domain(value)


def endpoint(value):
    if not isinstance(value, str):
        fail('endpoint must be a string')
    match = re.fullmatch(r'\[([0-9a-fA-F:]+)\]:([0-9]{1,5})', value)
    if match:
        address = ipaddress.IPv6Address(match[1])
        return f'[{address}]:{port(match[2])}'
    match = re.fullmatch(r'([^:\[\]]+):([0-9]{1,5})', value)
    if not match:
        fail('endpoint requires hostname:port, IPv4:port or [IPv6]:port')
    return host(match[1]) + ':' + port(match[2])


def name(value):
    if not isinstance(value, str) or not 1 <= len(value.encode('utf-8')) <= 100:
        fail('client name must contain 1-100 UTF-8 bytes')
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        fail('control characters are forbidden in names')
    return value


def sid(value):
    if not isinstance(value, str) or not re.fullmatch(r'(?:[0-9a-fA-F]{2}){1,8}', value):
        fail('shortId must contain 2-16 hexadecimal digits, in pairs')
    return value.lower()


def profile(value):
    if not isinstance(value, dict):
        fail('profile must be a JSON object')
    allowed = set(DEFAULTS) | {'profile_format', 'generated_at_utc', 'script_version'}
    if set(value) - allowed:
        fail('unknown profile field: ' + ', '.join(sorted(set(value) - allowed)))
    if value.get('profile_format', '2') not in ('1', '2'):
        fail('unsupported profile_format')
    for k, v in value.items():
        if not isinstance(v, str) or '\x00' in v:
            fail('profile fields must be strings: ' + k)
    result = dict(DEFAULTS)
    result.update({k: v for k, v in value.items() if k in DEFAULTS})
    for k in ('LISTEN_PORT', 'SSH_PORT', 'CAMOUFLAGE_WEB_PORT'):
        result[k] = port(result[k])
    if result['FALLBACK_PORT']:
        result['FALLBACK_PORT'] = port(result['FALLBACK_PORT'])
    result['SERVER_NAME'] = domain(result['SERVER_NAME'])
    result['DEST_ENDPOINT'] = endpoint(result['DEST_ENDPOINT'])
    for k in DEFAULTS:
        if DEFAULTS[k] in ('yes', 'no') and result[k] not in ('yes', 'no'):
            fail(k + ' must be yes or no')
    enums = {'FIREWALL_STYLE': ('none', 'nftables', 'ufw'),
             'XRAY_UPDATE_POLICY': ('manual', 'weekly', 'daily'),
             'LOG_PROFILE': ('minimal', 'verbose')}
    for k, choices in enums.items():
        if result[k] not in choices:
            fail('unsupported ' + k)
    if result['OS_PRIVATE_OUTBOUND'] == 'yes' and result['FIREWALL_STYLE'] != 'nftables':
        fail('OS_PRIVATE_OUTBOUND requires nftables')
    try:
        result['LISTEN_ADDRESS'] = str(ipaddress.ip_address(result['LISTEN_ADDRESS']))
    except ValueError:
        fail('LISTEN_ADDRESS must be an IPv4 or IPv6 literal')
    if not re.fullmatch(r'[0-9]{1,2}', result['SHORT_ID_COUNT']) or not 1 <= int(result['SHORT_ID_COUNT']) <= 16:
        fail('SHORT_ID_COUNT must be 1-16')
    result['SHORT_ID_COUNT'] = str(int(result['SHORT_ID_COUNT']))
    for key, minimum, maximum in [('XRAY_HANDSHAKE_TIMEOUT_SEC', 1, 60),
                                  ('XRAY_CONN_IDLE_TIMEOUT_SEC', 1, 86400),
                                  ('XRAY_UPLINK_ONLY_TIMEOUT_SEC', 0, 3600),
                                  ('XRAY_DOWNLINK_ONLY_TIMEOUT_SEC', 0, 3600)]:
        if not re.fullmatch(r'[0-9]{1,5}', result[key]) or not minimum <= int(result[key]) <= maximum:
            fail('invalid timeout range: ' + key)
        result[key] = str(int(result[key]))
    resolvers = result['DNS_SERVERS'].split(',')
    if not 1 <= len(resolvers) <= 8:
        fail('DNS_SERVERS requires 1-8 comma-separated resolver IPs')
    try:
        result['DNS_SERVERS'] = ','.join(str(ipaddress.ip_address(r)) for r in resolvers)
    except ValueError:
        fail('DNS_SERVERS requires IPv4 or IPv6 literals')
    name(result['PROFILE_NAME'])
    name(result['SHORT_ID_LABEL'])
    if result['PUBLIC_IP']:
        result['PUBLIC_IP'] = host(result['PUBLIC_IP'])
    if result['XRAY_PIN'] and not re.fullmatch(r'v[0-9]{1,3}\.[0-9]{1,2}\.[0-9]{1,2}', result['XRAY_PIN']):
        fail('XRAY_PIN requires a release tag such as v26.3.27')
    ports = [result['LISTEN_PORT']]
    if result['FALLBACK_PORT']:
        ports.append(result['FALLBACK_PORT'])
    if result['CAMOUFLAGE_ENABLED'] == 'yes':
        ports.append(result['CAMOUFLAGE_WEB_PORT'])
    if len(set(ports)) != len(ports) or result['SSH_PORT'] in ports:
        fail('Xray, SSH and local web ports must be different')
    result['profile_format'] = '2'
    return result


def identity(value):
    if not isinstance(value, dict) or set(value) != {'private_key', 'public_key'}:
        fail('invalid identity fields')
    for k in value:
        if not isinstance(value[k], str) or not re.fullmatch(r'[A-Za-z0-9_-]{43}', value[k]):
            fail('invalid X25519 key encoding')
        if len(base64.urlsafe_b64decode(value[k] + '=')) != 32:
            fail('invalid X25519 key length')
    return value


def state(value):
    expected = {'format', 'options', 'identity', 'clients', 'short_ids', 'rotation', 'xray_version'}
    if not isinstance(value, dict) or set(value) != expected or type(value['format']) is not int or value['format'] != 2:
        fail('unsupported state format or fields')
    value['options'] = profile(value['options'])
    identity(value['identity'])
    if not isinstance(value['clients'], list) or not 1 <= len(value['clients']) <= 1024:
        fail('deployment must contain 1-1024 clients')
    names, ids = set(), set()
    for c in value['clients']:
        if not isinstance(c, dict) or set(c) != {'name', 'id', 'short_id'}:
            fail('invalid client fields')
        name(c['name'])
        if not isinstance(c['id'], str) or not re.fullmatch(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}', c['id']):
            fail('client UUID must be canonical')
        c['id'] = str(uuid.UUID(c['id']))
        c['short_id'] = sid(c['short_id'])
        if c['name'] in names or c['id'] in ids:
            fail('duplicate client name or UUID')
        names.add(c['name'])
        ids.add(c['id'])
    if not isinstance(value['short_ids'], list) or not 1 <= len(value['short_ids']) <= 4096:
        fail('invalid short_ids list')
    value['short_ids'] = list(dict.fromkeys(sid(s) for s in value['short_ids']))
    if any(c['short_id'] not in value['short_ids'] for c in value['clients']):
        fail('client shortId is not accepted by the server')
    r = value['rotation']
    if r is not None:
        if not isinstance(r, dict) or set(r) != {'old_ids', 'finalize_after'} or type(r['finalize_after']) is not int or r['finalize_after'] < 0:
            fail('invalid rotation metadata')
        if not isinstance(r['old_ids'], list) or not r['old_ids']:
            fail('invalid old shortIds')
        for s in r['old_ids']:
            if sid(s) not in value['short_ids'] or s in [c['short_id'] for c in value['clients']]:
                fail('invalid rotation mapping')
    if not isinstance(value['xray_version'], str) or not re.fullmatch(r'v[0-9]{1,3}\.[0-9]{1,2}\.[0-9]{1,2}', value['xray_version']):
        fail('invalid deployment Xray version')
    return value


def legacy_word(word):
    # Decode Bash printf %q as data, including octal UTF-8 under LC_ALL=C.
    # No shell, substitutions, or eval are involved.
    if not (word.startswith("$'") and word.endswith("'")):
        if re.search(r'(?<!\\)[;$`|&<>\n()]', word):
            fail('legacy state contains shell operators')
        words = shlex.split(word)
        if len(words) != 1:
            fail('legacy state must contain one literal word per value')
        return words[0]
    body, result, index = word[2:-1], bytearray(), 0
    escapes = {'a': '\a', 'b': '\b', 'e': '\x1b', 'E': '\x1b',
               'f': '\f', 'n': '\n', 'r': '\r', 't': '\t', 'v': '\v',
               '\\': '\\', "'": "'", '"': '"', '?': '?'}
    while index < len(body):
        c = body[index]
        index += 1
        if c == "'":
            fail('invalid legacy quoting')
        if c != '\\':
            result.extend(c.encode('utf-8'))
            continue
        if index == len(body):
            fail('incomplete legacy escape')
        c = body[index]
        index += 1
        if c in escapes:
            result.extend(escapes[c].encode())
        elif c in '01234567':
            digits = re.match(r'[0-7]{0,2}', body[index:])[0]
            index += len(digits)
            result.append(int(c + digits, 8) % 256)
        elif c in 'xuU':
            maximum = {'x': 2, 'u': 4, 'U': 8}[c]
            digits = re.match(r'[0-9a-fA-F]{1,' + str(maximum) + '}', body[index:])
            if not digits:
                fail('invalid legacy numeric escape')
            index += len(digits[0])
            value = int(digits[0], 16)
            if c == 'x':
                result.append(value)
            elif value > 0x10ffff or 0xd800 <= value <= 0xdfff:
                fail('invalid legacy Unicode escape')
            else:
                result.extend(chr(value).encode('utf-8'))
        else:
            fail('unsupported legacy escape')
    return result.decode('utf-8')


def legacy(path, config_path):
    values = {}
    allowed = set(DEFAULTS) | {'SCRIPT_VERSION', 'OS_ID', 'OS_VERSION_ID', 'XRAY_ASSET',
              'XRAY_VERSION', 'UUID', 'REALITY_PRIVATE_KEY', 'REALITY_PUBLIC_KEY',
              'REALITY_SHORT_ID', 'REALITY_SHORT_IDS', 'HTTP_CONNECT_TIMEOUT',
              'HTTP_MAX_TIME', 'HTTP_RETRIES', 'HTTP_RETRY_DELAY',
              'XRAY_HANDSHAKE_TIMEOUT_SEC', 'XRAY_CONN_IDLE_TIMEOUT_SEC',
              'XRAY_UPLINK_ONLY_TIMEOUT_SEC', 'XRAY_DOWNLINK_ONLY_TIMEOUT_SEC'}
    with open(path, encoding='utf-8') as f:
        for line in f:
            line = line.rstrip('\n')
            if not line or line.startswith('#'):
                continue
            match = re.fullmatch(r'([A-Z][A-Z0-9_]*)=(.*)', line)
            if not match or match[1] not in allowed or match[1] in values:
                fail('legacy state contains unsupported syntax or fields')
            values[match[1]] = legacy_word(match[2])
    cfg = load(config_path)
    inbounds = cfg.get('inbounds', [])
    vless = [i for i in inbounds if i.get('protocol') == 'vless']
    if not vless:
        fail('no VLESS inbound for migration')
    if len(inbounds) != len(vless) or any(i.get('tag') not in ('vless-reality-primary', 'vless-reality-fallback') for i in inbounds):
        fail('legacy config contains unmanaged inbounds; migrate manually to preserve them')
    if len({i['tag'] for i in vless}) != len(vless) or not any(i['tag'] == 'vless-reality-primary' for i in vless):
        fail('legacy config requires one primary and at most one alternate listener')
    vless.sort(key=lambda i: i['tag'] != 'vless-reality-primary')
    if any([(c['id'], c.get('flow', '')) for c in i['settings']['clients']] != [(c['id'], c.get('flow', '')) for c in vless[0]['settings']['clients']] for i in vless):
        fail('legacy listeners contain different clients; migrate manually to preserve them')
    reality = vless[0]['streamSettings']['realitySettings']
    clients = vless[0]['settings']['clients']
    ids = list(dict.fromkeys(sid(s) for s in reality['shortIds']))
    deployed = []
    for inbound in vless:
        stream = inbound['streamSettings']
        transport = stream['realitySettings']
        if (stream.get('network') not in ('tcp', 'raw') or stream.get('security') != 'reality'
                or transport.get('xver', 0) != 0 or len(transport['serverNames']) != 1
                or any(c.get('flow') != 'xtls-rprx-vision' for c in inbound['settings']['clients'])):
            fail('custom legacy transport settings require manual migration')
        target = endpoint(transport.get('target', transport.get('dest')))
        if 'target' in transport and 'dest' in transport and endpoint(transport['dest']) != target:
            fail('conflicting legacy REALITY target aliases')
        deployed.append({'LISTEN_PORT': port(str(inbound['port'])),
            'LISTEN_ADDRESS': str(ipaddress.ip_address(inbound.get('listen', '0.0.0.0'))),
            'SERVER_NAME': domain(transport['serverNames'][0]), 'DEST_ENDPOINT': target})
        if (transport['privateKey'] != reality['privateKey']
                or {sid(s) for s in transport['shortIds']} != set(ids)):
            fail('legacy listeners have different REALITY credentials; migrate manually')
    for other in deployed[1:]:
        if any(other[k] != deployed[0][k] for k in ('LISTEN_ADDRESS', 'SERVER_NAME', 'DEST_ENDPOINT')):
            fail('legacy listeners have different network settings; migrate manually')
    if values.get('REALITY_PRIVATE_KEY') != reality['privateKey']:
        fail('legacy state/config key mismatch; restore a consistent backup first')
    if values.get('UUID') != clients[0]['id']:
        fail('legacy state/config UUID mismatch')
    opts = profile({k: v for k, v in values.items() if k in DEFAULTS})
    network = {**deployed[0], 'FALLBACK_PORT': deployed[1]['LISTEN_PORT'] if len(deployed) == 2 else ''}
    for key, actual in network.items():
        if key in values and opts[key] != actual:
            fail('legacy state/config network mismatch: ' + key + '; reconcile before migration')
        opts[key] = actual
    # Upgrading software must never silently reapply old host-wide defaults.
    opts.update(FIREWALL_STYLE='none', SSH_HARDENING='no', FAIL2BAN_ENABLED='no',
                UNATTENDED_UPGRADES_ENABLED='no', CAMOUFLAGE_ENABLED='no')
    migrated = []
    for index, c in enumerate(clients):
        migrated.append({'name': opts['PROFILE_NAME'] if index == 0 else 'legacy-' + str(index),
                         'id': c['id'], 'short_id': ids[0]})
    return state({'format': 2, 'options': opts, 'identity': {
        'private_key': reality['privateKey'], 'public_key': values['REALITY_PUBLIC_KEY']},
        'clients': migrated, 'short_ids': ids, 'rotation': None,
        'xray_version': values['XRAY_VERSION']})


def config(s):
    o = s['options']
    inbounds = []
    for tag, p in [('primary', o['LISTEN_PORT']), ('alternate', o['FALLBACK_PORT'])]:
        if not p:
            continue
        inbounds.append({'tag': 'vless-reality-' + tag, 'listen': o['LISTEN_ADDRESS'],
            'port': int(p), 'protocol': 'vless', 'settings': {'decryption': 'none',
            'clients': [{'id': c['id'], 'flow': 'xtls-rprx-vision',
                         'email': hashlib.sha256(c['name'].encode()).hexdigest()[:24] + '@xray'}
                        for c in s['clients']]}, 'streamSettings': {
            'network': 'raw', 'security': 'reality', 'realitySettings': {
            'show': False, 'target': o['DEST_ENDPOINT'], 'xver': 0,
            'serverNames': [o['SERVER_NAME']], 'privateKey': s['identity']['private_key'],
            'shortIds': s['short_ids']}}, 'sniffing': {'enabled': False}})
    block = o['BLOCK_PRIVATE_OUTBOUND'] == 'yes'
    # Xray normalizes mapped addresses to IPv4 and rejects the mapped /96 CIDR.
    ranges = V4 + [cidr for cidr in V6 if cidr != '::ffff:0:0/96']
    # Recent Freedom versions enforce finalRules on the resolved/dialed address.
    # An explicit opt-out must override their built-in private-IP default.
    final_rules = [{'action': 'block', 'ip': ranges}] if block else [
        {'action': 'allow', 'ip': ['0.0.0.0/0', '::/0']}]

    return {'log': {'access': 'none' if o['LOG_PROFILE'] == 'minimal' else '/var/log/xray/access.log',
                   'error': '/var/log/xray/error.log', 'loglevel': 'warning' if o['LOG_PROFILE'] == 'minimal' else 'info'},
            'policy': {'levels': {'0': {'handshake': int(o['XRAY_HANDSHAKE_TIMEOUT_SEC']),
                'connIdle': int(o['XRAY_CONN_IDLE_TIMEOUT_SEC']),
                'uplinkOnly': int(o['XRAY_UPLINK_ONLY_TIMEOUT_SEC']),
                'downlinkOnly': int(o['XRAY_DOWNLINK_ONLY_TIMEOUT_SEC'])}}},
            'dns': {'servers': o['DNS_SERVERS'].split(','), 'queryStrategy': 'UseIP'},
            'inbounds': inbounds,
            'outbounds': [{'tag': 'direct', 'protocol': 'freedom', 'settings': {'finalRules': final_rules},
                'streamSettings': {'sockopt': {'domainStrategy': 'UseIP', 'happyEyeballs': {
                    'prioritizeIPv6': False, 'interleave': 1, 'tryDelayMs': 250, 'maxConcurrentTry': 2}}}}]
                         + ([{'tag': 'blocked', 'protocol': 'blackhole'}] if block else []),
            'routing': {'domainStrategy': 'IPOnDemand' if block else 'AsIs',
                        'rules': [{'type': 'field', 'ip': ranges, 'outboundTag': 'blocked'}] if block else []}}


def find_client(s, client_name):
    for c in s['clients']:
        if c['name'] == client_name:
            return c
    fail('client name does not exist')


def mutate(s, operation, client_name, window):
    if operation == 'add-client':
        name(client_name)
        if any(c['name'] == client_name for c in s['clients']):
            fail('client name already exists')
        new_sid = secrets.token_hex(8)
        s['short_ids'].append(new_sid)
        s['clients'].append({'name': client_name, 'id': str(uuid.uuid4()), 'short_id': new_sid})
    elif operation in ('remove-client', 'rotate-client'):
        c = find_client(s, client_name)
        if operation == 'remove-client':
            if len(s['clients']) == 1:
                fail('cannot remove the last client')
            s['clients'].remove(c)
            retained = {client['short_id'] for client in s['clients']}
            if s['rotation']:
                retained.update(s['rotation']['old_ids'])
            if c['short_id'] not in retained:
                s['short_ids'].remove(c['short_id'])
        else:
            c['id'] = str(uuid.uuid4())
        # ShortIds are global REALITY gates, not tied cryptographically to UUIDs.
    elif operation == 'rotate-shortid':
        if s['rotation'] is not None:
            fail('finalize the existing shortId rotation first')
        old = s['short_ids'][:]
        for c in s['clients']:
            c['short_id'] = secrets.token_hex(8)
            s['short_ids'].append(c['short_id'])
        s['rotation'] = {'old_ids': old, 'finalize_after': int(datetime.datetime.now().timestamp()) + window}
    elif operation == 'finalize-shortid':
        if not s['rotation']:
            fail('no pending shortId rotation')
        if int(datetime.datetime.now().timestamp()) < s['rotation']['finalize_after']:
            fail('migration window has not elapsed')
        s['short_ids'] = [c['short_id'] for c in s['clients']]
        s['rotation'] = None
    return state(s)


def export(s, client_name, directory):
    c = find_client(s, client_name)
    o = s['options']
    address = o['PUBLIC_IP']
    if not address:
        fail('set PUBLIC_IP to the server public IP or hostname before exporting')
    authority = '[' + address + ']' if ':' in address else address
    prefix = hashlib.sha256(client_name.encode()).hexdigest()[:24]
    os.makedirs(directory, mode=0o700, exist_ok=True)
    def write(suffix, content):
        path = os.path.join(directory, prefix + suffix)
        flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW
        fd = os.open(path, flags, 0o600)
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(content)
        return path
    for label, p in [('primary', o['LISTEN_PORT']), ('fallback', o['FALLBACK_PORT'])]:
        if not p:
            continue
        uri = f"vless://{c['id']}@{authority}:{p}?encryption=none&flow=xtls-rprx-vision&security=reality&sni={quote(o['SERVER_NAME'], safe='')}&fp=chrome&pbk={quote(s['identity']['public_key'], safe='')}&sid={c['short_id']}&type=tcp&spx=%2F#{quote(client_name, safe='')}"
        write('-' + label + '.uri.txt', uri + '\n')
        client = {'log': {'loglevel': 'warning'}, 'outbounds': [{'tag': 'proxy', 'protocol': 'vless',
            'settings': {'vnext': [{'address': address, 'port': int(p), 'users': [{'id': c['id'],
                                  'encryption': 'none', 'flow': 'xtls-rprx-vision'}]}]},
            'streamSettings': {'network': 'raw', 'security': 'reality', 'realitySettings': {
            'serverName': o['SERVER_NAME'], 'fingerprint': 'chrome',
            'password': s['identity']['public_key'], 'shortId': c['short_id'], 'spiderX': '/'}}}]}
        for flavor in ('v2rayn', 'v2rayng'):
            write('-' + flavor + '-' + label + '.json', json.dumps(client, ensure_ascii=False, indent=2) + '\n')
        sing = {'type': 'vless', 'tag': client_name, 'server': address, 'server_port': int(p),
                'uuid': c['id'], 'flow': 'xtls-rprx-vision', 'packet_encoding': 'xudp',
                'tls': {'enabled': True, 'server_name': o['SERVER_NAME'],
                        'utls': {'enabled': True, 'fingerprint': 'chrome'},
                        'reality': {'enabled': True, 'public_key': s['identity']['public_key'], 'short_id': c['short_id']}}}
        write('-sing-box-' + label + '.json', json.dumps(sing, ensure_ascii=False, indent=2) + '\n')
    print(prefix)


def extract(archive, directory):
    with zipfile.ZipFile(archive) as z:
        total = 0
        for item in z.infolist():
            if item.filename.startswith('/') or '..' in item.filename.split('/') or '\\' in item.filename or (item.external_attr >> 16) & 0o170000 == 0o120000:
                fail('unsafe release archive member')
            total += item.file_size
            if total > 512 * 1024 * 1024:
                fail('release archive exceeds unpacked size limit')
        z.testzip() is None or fail('corrupt release archive')
        z.extractall(directory)


def egress_check(options_path, resolver_path):
    o = profile(load(options_path))
    if o['OS_PRIVATE_OUTBOUND'] != 'yes':
        return
    ranges = [ipaddress.ip_network(c) for c in V4 + V6]
    def blocked(address):
        return any(address.version == r.version and address in r for r in ranges)
    for resolver in o['DNS_SERVERS'].split(','):
        if blocked(ipaddress.ip_address(resolver)):
            fail('OS egress policy blocks a configured DNS resolver; use reachable public resolver IPs')
    target = o['DEST_ENDPOINT'].rsplit(':', 1)[0].strip('[]')
    try:
        address = ipaddress.ip_address(target)
    except ValueError:
        with open(resolver_path, encoding='utf-8') as f:
            servers = [line.split()[1] for line in f if line.startswith('nameserver ') and len(line.split()) >= 2]
        if not servers or all(blocked(ipaddress.ip_address(r)) for r in servers):
            fail('OS egress blocks the system DNS used by the REALITY hostname; configure a public system resolver or a public literal target IP')
    else:
        if blocked(address):
            fail('OS egress policy blocks the REALITY target; select a reachable public TLS endpoint')


def main():
    if len(sys.argv) < 2:
        fail('data command required')
    command, a = sys.argv[1], sys.argv[2:]
    counts = {'defaults':0, 'profile':1, 'profile-legacy':3, 'profile-deployed':2, 'state':1, 'migrate':2, 'config':1,
              'mutate':4, 'export':3, 'extract':2, 'validate':2, 'cidrs':1,
              'egress-check':2, 'key-der':2, 'public-key':1}
    if command not in counts or len(a) != counts[command]:
        fail('invalid data command or argument count')
    if command == 'defaults':
        emit(profile({}))
    elif command == 'profile':
        emit(profile(load(a[0])))
    elif command in ('profile-legacy', 'profile-deployed'):
        raw = load(a[0])
        if not isinstance(raw, dict):
            fail('profile must be a JSON object')
        deployed = legacy(a[1], a[2]) if command == 'profile-legacy' else state(load(a[1]))
        raw.setdefault('LISTEN_ADDRESS', deployed['options']['LISTEN_ADDRESS'])
        emit(profile(raw))
    elif command == 'state':
        emit(state(load(a[0])))
    elif command == 'migrate':
        emit(legacy(a[0], a[1]))
    elif command == 'config':
        emit(config(state(load(a[0]))))
    elif command == 'mutate':
        emit(mutate(state(load(a[0])), a[1], a[2], int(a[3])))
    elif command == 'export':
        export(state(load(a[0])), a[1], a[2])
    elif command == 'extract':
        extract(a[0], a[1])
    elif command == 'validate':
        {'port': port, 'endpoint': endpoint, 'domain': domain, 'host': host,
         'shortid': sid, 'name': name}[a[0]](a[1])
    elif command == 'key-der':
        value = state(load(a[0]))
        raw = base64.urlsafe_b64decode(value['identity']['private_key'] + '=')
        fd = os.open(a[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'wb') as f:
            f.write(bytes.fromhex('302e020100300506032b656e04220420') + raw)
    elif command == 'public-key':
        with open(a[0], 'rb') as f:
            der = f.read()
        if len(der) != 44 or not der.startswith(bytes.fromhex('302a300506032b656e032100')):
            fail('invalid X25519 public key DER')
        print(base64.urlsafe_b64encode(der[-32:]).decode().rstrip('='))
    elif command == 'egress-check':
        egress_check(a[0], a[1])
    elif command == 'cidrs':
        emit(V4 if a[0] == '4' else V6)
    else:
        fail('unknown data operation')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, IndexError, OSError, zipfile.BadZipFile) as e:
        # Do not print values from state/configuration in error messages.
        message = str(e) if isinstance(e, ValueError) else type(e).__name__
        print('Data validation failed: ' + json.dumps(message, ensure_ascii=True), file=sys.stderr)
        sys.exit(2)
