"""Render Proxy templates for a chosen exit. Does not modify networking."""
import argparse
import ipaddress
import json
from pathlib import Path
import re
from urllib.parse import urlsplit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exit-ip', required=True)
    parser.add_argument('--upstream-host', required=True)
    parser.add_argument('--upstream-port', required=True, type=int)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--protocol', required=True, choices=['http','https','socks5'])
    parser.add_argument('--tls-server-name')
    parser.add_argument('--check-url', required=True)
    args = parser.parse_args()
    check = urlsplit(args.check_url)
    if check.scheme != 'https' or not check.hostname or check.username or check.password or not re.fullmatch(r'[A-Za-z0-9:/?&=._%+~-]+', args.check_url):
        parser.error('Use a credential-free HTTPS JSON IP-check URL.')
    tls_name = args.tls_server_name or args.upstream_host
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.-]*', tls_name):
        parser.error('Invalid TLS server name.')
    if args.tls_server_name and args.protocol != 'https':
        parser.error('TLS server name only applies to HTTPS proxy.')
    # Validate everything before creating or changing files.
    address = ipaddress.ip_address(args.exit_ip)
    if not address.is_global or str(address) != args.exit_ip:
        parser.error('Use the assigned public exit IP in canonical form.')
    if not re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9.-]{0,251}[A-Za-z0-9])?', args.upstream_host):
        parser.error('Upstream must be a hostname or IPv4 literal, without URL, port or credentials.')
    if not 1 <= args.upstream_port <= 65535:
        parser.error('Invalid upstream port.')
    src = Path(__file__).resolve().parents[1]
    dest = args.output.resolve()
    if dest.exists() or dest == src or src in dest.parents:
        parser.error('Output must be a new directory outside this skill.')
    replacements = {
        '__PROXY_CHECK_URL__': args.check_url,
        '__PROXY_CHECK_HOST__': check.hostname,
        '__PROXY_CORE_TYPE__': 'socks' if args.protocol == 'socks5' else 'http',
        '__PROXY_TRANSPORT_PS__': ("tls = @{ enabled = $true; server_name = '" + tls_name + "' }") if args.protocol == 'https' else ("version = '5'" if args.protocol == 'socks5' else ''),
        '__PROXY_EXIT_IP__': args.exit_ip,
        '__PROXY_UPSTREAM_HOST__': args.upstream_host,
        '__PROXY_UPSTREAM_PORT__': str(args.upstream_port),
    }
    rendered = {}
    for file in src.rglob('*'):
        if not file.is_file() or file.name == 'materialize.py' or '__pycache__' in file.parts:
            continue
        relative = file.relative_to(src)
        if file.suffix == '.template':
            relative = relative.with_suffix('')
        original = file.read_bytes()
        content = original.decode('utf-8-sig')
        for token, value in replacements.items():
            content = content.replace(token, value)
        if relative.as_posix() == 'references/desired-state.json':
            state = json.loads(content)
            state['exitIp'] = args.exit_ip
            state['upstream']['host'] = args.upstream_host
            state['upstream']['serverName'] = tls_name if args.protocol == 'https' else None
            state['upstream']['type'] = 'socks' if args.protocol == 'socks5' else 'http'
            state['upstream']['tls'] = args.protocol == 'https'
            state['exitCheck']['url'] = args.check_url
            state['upstream']['port'] = args.upstream_port
            state['dns']['bootstrapDomain'] = args.upstream_host
            state['configurationStatus'] = 'parameters-filled; paths, transport, credentials and network still require validation'
            content = json.dumps(state, ensure_ascii=False, indent=2) + '\n'
        encoding = 'utf-8-sig' if relative.suffix == '.ps1' else 'utf-8'
        rendered[relative] = content.encode(encoding)
    try:
        dest.mkdir(parents=True, exist_ok=False)
        for relative, data in rendered.items():
            target = dest / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
        (dest / 'parameters-filled.json').write_text(json.dumps({
            'exitIp': args.exit_ip, 'upstreamHost': args.upstream_host,
            'upstreamPort': args.upstream_port, 'protocol': args.protocol, 'checkUrl': args.check_url,
            'networkConfigured': False,
            'note': 'Adapt machine-specific paths, SID and installed versions; then follow setup and verification.'
        }, ensure_ascii=False, indent=2), encoding='utf-8')
    except Exception:
        # Do not recursively delete on failure; leave the new directory for review.
        raise
    print(json.dumps({'output': str(dest), 'files': len(rendered), 'networkConfigured': False}))


if __name__ == '__main__':
    main()
