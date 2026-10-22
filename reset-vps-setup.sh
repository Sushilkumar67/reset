#!/usr/bin/env bash
# ==============================================================================
#  RESET VPS GOD-MODE HELPER v2.3 (Bugfix for backup path + Faucet + Phrase)
#  Pinned official source: 6c2afd48d8a61198878004d30f7c420b5eeb8788
# ==============================================================================

set -Eeuo pipefail
umask 077

if [[ ${EUID} -ne 0 ]]; then
  echo -e "\n\033[1;31m[ERROR] Please run with root privileges: sudo -i, then bash reset-vps-setup.sh\033[0m\n" >&2
  exit 1
fi

if [[ ! -f /etc/debian_version || ! -d /run/systemd/system ]]; then
  echo -e "\n\033[1;31m[ERROR] Requires an Ubuntu or Debian VPS with systemd.\033[0m\n" >&2
  exit 1
fi

# Ensure basic utilities exist
if ! command -v python3 >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1 || ! command -v git >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y python3 curl git ca-certificates util-linux
fi

exec 9>/run/reset-vps-installer.lock
if ! flock -n 9; then
  echo -e "\033[1;33m[WARN] Another instance of the RESET installer is running. Please wait for it to finish.\033[0m" >&2
  exit 1
fi

stage=$(mktemp -d)
trap 'rm -rf -- "$stage"' EXIT

# ------------------------------------------------------------------------------
# 1. MANAGER.PY (Python Orchestrator & CLI)
# ------------------------------------------------------------------------------
cat > "$stage/manager.py" <<'RESET_HELPER_PY'
#!/usr/bin/env python3
"""RESET VPS God-Mode Orchestrator v2.3."""
import contextlib, datetime, decimal, fcntl, getpass, hashlib, json, os, pathlib, platform
import re, shutil, socket, subprocess, sys, tarfile, tempfile, time, urllib.parse

BASE = pathlib.Path('/opt/reset-vps')
CFG = BASE / 'config.json'
RUN = pathlib.Path('/run/reset-vps')
COMMIT = '6c2afd48d8a61198878004d30f7c420b5eeb8788'
REPO = 'https://github.com/Trac-Systems/reset.git'
AUDIENCE = 'https://drop.reset.invalid'
NONCE = '139abe7d53c83d0bd19818911e1d1487eb471b6cdc74f625537f3099a391d5a1'
MARKER = '# Managed by RESET VPS helper v2'
SERVICES = ['reset-vps-miner.service', 'reset-vps-dashboard.service']

def fail(msg):
    print(f"\n\033[1;31m[ERROR] {msg}\033[0m", file=sys.stderr)
    sys.exit(1)

def say(msg):
    print(msg, flush=True)

def info(msg):
    print(f"\033[1;34m[INFO]\033[0m {msg}", flush=True)

def success(msg):
    print(f"\033[1;32m[SUCCESS]\033[0m {msg}", flush=True)

def warn(msg):
    print(f"\033[1;33m[WARN]\033[0m {msg}", flush=True)

def ask(label, default=None):
    prompt_str = f"\033[1;36m{label}\033[0m" + (f" [\033[1;33m{default}\033[0m]" if default is not None else "") + ": "
    try:
        val = input(prompt_str)
    except (EOFError, OSError):
        try:
            sys.stdout.write(prompt_str)
            sys.stdout.flush()
            val = sys.stdin.readline()
        except Exception:
            val = ""
    val = val.strip() if val else ""
    return val or default or ""

def yes(label, default=False):
    ans = ask(label + (' (Y/n)' if default else ' (y/N)'), 'y' if default else 'n').lower()
    return ans in ('y', 'yes')

def secret(label):
    prompt_str = f"\033[1;36m{label}\033[0m: "
    try:
        val = getpass.getpass(prompt_str)
    except Exception:
        try:
            sys.stdout.write(prompt_str)
            sys.stdout.flush()
            val = sys.stdin.readline()
        except Exception:
            val = ""
    val = val.strip() if val else ""
    if not val or '\n' in val or '\r' in val:
        fail("Empty or invalid secret provided.")
    return val

def safe_path(value):
    p = pathlib.Path(value).expanduser()
    if not p.is_absolute() or not re.fullmatch(r'/[A-Za-z0-9_./-]+', str(p)) or '..' in p.parts:
        fail(f"Invalid path: {value}. Use an absolute path without special symbols or ..")
    for parent in [p, *p.parents]:
        if parent.is_symlink():
            fail(f"Symlink path refused: {parent}")
    return p

def private_dir(p):
    safe_path(str(p))
    p.mkdir(parents=True, exist_ok=True, mode=0o700)
    if p.stat().st_uid != 0:
        fail(f"Directory must be owned by root: {p}")
    os.chmod(p, 0o700)

def write_json(p, data):
    private_dir(p.parent)
    fd, tmp = tempfile.mkstemp(prefix='.write-', dir=p.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(data, f, indent=2)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, p)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

def read_json(p):
    safe_path(str(p))
    if not p.is_file() or p.stat().st_uid != 0 or (p.stat().st_mode & 0o077):
        fail(f"Expected private, root-owned file: {p}")
    return json.loads(p.read_text())

def config():
    if not CFG.exists():
        fail("RESET VPS is not configured yet. Run: reset-vps setup")
    c = read_json(CFG)
    for k in ('repo', 'directory', 'node', 'state_dir'):
        safe_path(c[k])
    return c

def environment(c=None, password=None):
    e = os.environ.copy()
    for k in list(e):
        if k.startswith('RESET_') or k in ('NODE_OPTIONS', 'NODE_PATH'):
            e.pop(k, None)
    if c:
        e['PATH'] = str(pathlib.Path(c['node']).parent) + ':' + e.get('PATH', '/usr/bin:/bin')
    if password is not None:
        e['RESET_SIGNER_PASSWORD'] = password
    return e

def run(args, *, cwd=None, env=None, capture=False, timeout=180, check=True):
    r = subprocess.run([str(x) for x in args], cwd=cwd, env=env or environment(), text=True,
                       stdout=subprocess.PIPE if capture else None,
                       stderr=subprocess.PIPE if capture else None, timeout=timeout)
    if check and r.returncode:
        detail = ((r.stderr or '') + (r.stdout or ''))[-1200:] if capture else "See console logs above."
        fail(f"Command failed (exit {r.returncode}): {detail}")
    return r

def active(name):
    return run(['systemctl', 'is-active', '--quiet', name], capture=True, check=False).returncode == 0

def cli(c, args, password=None, capture=True):
    return run([c['node'], str(pathlib.Path(c['repo']) / 'signer/bin/reset-signer.mjs'), *args,
                '--directory', c['directory']],
               cwd=str(pathlib.Path(c['repo']) / 'signer'),
               env=environment(c, password), capture=capture, timeout=180)

def os_check():
    if sys.version_info < (3, 9):
        fail("Python 3.9+ required. Use Ubuntu 22.04/24.04 or Debian 12/13.")
    if os.geteuid() != 0:
        fail("Run sudo -i, then run this command as root.")
    data = pathlib.Path('/etc/os-release').read_text()
    if not re.search(r'^ID=(?:"?)(ubuntu|debian)(?:"?)$', data, re.M):
        fail("Supported operating systems: Ubuntu or Debian VPS only.")
    if not pathlib.Path('/run/systemd/system').exists():
        fail("VPS booted with systemd is required.")

def packages():
    wanted = ['ca-certificates', 'curl', 'git', 'xz-utils', 'build-essential', 'python3', 'util-linux']
    missing = [p for p in wanted if run(['dpkg-query', '-W', '-f=${Status}', p], capture=True, check=False).returncode != 0]
    if missing:
        info("Installing missing system packages: " + ', '.join(missing))
        run(['apt-get', 'update'], timeout=600)
        run(['apt-get', 'install', '-y', *missing], timeout=1200)
    else:
        info("System dependencies already installed.")

def node_runtime():
    candidates = [shutil.which('node'), str(BASE / 'node/bin/node')]
    candidates += [str(p) for p in pathlib.Path('/root/.nvm/versions/node').glob('v24.*/bin/node')]
    candidates += [str(p) for p in (BASE / 'runtimes').glob('node-v24.*/bin/node')]
    for item in candidates:
        if not item or not pathlib.Path(item).is_file():
            continue
        p = pathlib.Path(item).resolve()
        r = run([p, '--version'], capture=True, check=False)
        npm = p.parent / 'npm'
        if r.returncode == 0 and r.stdout.strip().startswith('v24.') and npm.exists():
            success(f"Detected working Node.js {r.stdout.strip()} ({p})")
            return str(p)
    info("Downloading isolated Node.js 24 LTS (system node is untouched)...")
    arch = 'x64' if platform.machine() == 'x86_64' else 'arm64'
    with tempfile.TemporaryDirectory(prefix='reset-node-') as d:
        d = pathlib.Path(d)
        run(['curl', '-fsSL', 'https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt', '-o', str(d / 'sums')], timeout=60)
        matches = re.findall(r'^([a-f0-9]{64})\s+(node-v24\.\d+\.\d+-linux-' + arch + r'\.tar\.xz)$',
                             (d / 'sums').read_text(), re.M)
        if len(matches) != 1:
            fail("Could not find official Node 24 archive.")
        checksum, name = matches[0]
        version = name.split('-linux-')[0][5:]
        run(['curl', '-fsSL', f"https://nodejs.org/dist/{ver}/{name}", '-o', str(d / name)], timeout=600)
        if hashlib.sha256((d / name).read_bytes()).hexdigest() != checksum:
            fail("Node archive checksum mismatch.")
        dest = BASE / 'runtimes'
        private_dir(dest)
        run(['tar', '-xJf', d / name, '-C', dest], timeout=180)
        node = dest / name.removesuffix('.tar.xz') / 'bin/node'
        return str(node)

def repo_is_pinned(p):
    if not (p / '.git').exists():
        return False
    h = run(['git', '-C', p, 'rev-parse', 'HEAD'], capture=True, check=False)
    c = run(['git', '-C', p, 'diff', '--quiet', 'HEAD', '--'], capture=True, check=False)
    return h.returncode == 0 and h.stdout.strip() == COMMIT and c.returncode == 0

def choose_repo():
    candidate = safe_path(ask("RESET repository location (Enter for default)", '/root/reset'))
    if candidate.exists() and repo_is_pinned(candidate):
        success(f"Reusing existing verified RESET repo: {candidate}")
        return str(candidate)
    if candidate.exists():
        candidate = BASE / ('source-' + COMMIT[:12])
        if candidate.exists() and repo_is_pinned(candidate):
            return str(candidate)
    info(f"Cloning verified RESET repository into {candidate}...")
    private_dir(candidate.parent)
    run(['git', 'clone', '--no-checkout', REPO, str(candidate)], timeout=900)
    run(['git', '-C', candidate, 'checkout', '--detach', COMMIT], timeout=180)
    return str(candidate)

def other_processes():
    found = []
    for p in pathlib.Path('/proc').glob('[0-9]*'):
        try:
            cmd = (p / 'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
            if 'reset-signer.mjs' in cmd and re.search(r'\b(agent|mcp)\b', cmd):
                found.append(p.name)
        except (OSError, PermissionError):
            pass
    return found

def stop_conflicts():
    pids = other_processes()
    if pids and yes(f"Found active RESET miner processes (PIDs: {', '.join(pids)}). Stop them?", True):
        for pid in pids:
            try:
                os.kill(int(pid), 15)
            except OSError:
                pass
        time.sleep(2)

def ensure_deps(c):
    signer = pathlib.Path(c['repo']) / 'signer'
    r = run([c['node'], '--input-type=module', '-e',
             "await import('./lib/local-mcp.mjs'); await import('./lib/index.mjs');"],
            cwd=signer, env=environment(c), capture=True, check=False)
    if r.returncode == 0:
        info("Signer dependencies already functional.")
        return
    stop_conflicts()
    info("Installing npm dependencies for RESET signer...")
    run([pathlib.Path(c['node']).parent / 'npm', 'ci', '--no-audit', '--no-fund'],
        cwd=signer, env=environment(c), timeout=1200)

def extract_seed_phrase(c, password):
    signer_dir = pathlib.Path(c['repo']) / 'signer'
    script = f"""
    import {{ unlock, publicAddress }} from './lib/keystore.mjs';
    try {{
      const wallet = await unlock({{ directory: {json.dumps(c['directory'])}, password: {json.dumps(password)} }});
      const addr = publicAddress(wallet);
      process.stdout.write(JSON.stringify({{ mnemonic: wallet.mnemonic, address: addr }}));
    }} catch(e) {{
      process.stderr.write(e.message || String(e));
      process.exit(1);
    }}
    """
    res = run([c['node'], '--input-type=module', '-e', script], cwd=signer_dir, capture=True, check=False)
    if res.returncode == 0 and res.stdout.strip():
        try:
            data = json.loads(res.stdout)
            phrase = data.get('mnemonic', '')
            if phrase:
                say("\n" + "═" * 76)
                say("\033[1;32m🔑 YOUR SECRET RECOVERY PHRASE (MNEMONIC SEED WORDS):\033[0m")
                say("═" * 76)
                say(f"\033[1;37;44m {phrase} \033[0m")
                say("═" * 76)
                say("\033[1;33m⚠️  IMPORTANT: Ye 12/24 words apne paas kisi safe jagah save kar lo!\033[0m")
                say("═" * 76 + "\n")
                return phrase
        except Exception:
            pass
    return None

def wallet(c):
    directory = safe_path(c['directory'])
    key = directory / 'keystore.json'
    if key.exists():
        os.chmod(directory, 0o700)
        os.chmod(key, 0o600)
        addr = read_json(key).get('address')
        success(f"Existing RESET wallet detected: {addr}")
        password = secret("Enter your RESET keystore password")
        actual = json.loads(cli(c, ['address'], password).stdout)['address']
        if actual != addr:
            fail("Password incorrect or address mismatch.")
        success("Wallet unlocked successfully.")
        c['address'] = addr
        if yes("Do you want to see/backup your recovery seed phrase now?", False):
            extract_seed_phrase(c, password)
    else:
        info(f"No existing wallet found in {directory}.")
        choice = ask("Choose: (NEW) create brand new wallet | (IMPORT) restore mnemonic seed", "NEW").upper()
        if choice not in ('NEW', 'IMPORT'):
            fail("Wallet setup cancelled.")
        password = secret("Set a new wallet password (min 12 characters)")
        if len(password) < 12 or password != secret("Confirm wallet password"):
            fail("Password mismatch or shorter than 12 chars.")
        private_dir(directory)
        if choice == 'NEW':
            output = cli(c, ['init'], password).stdout
            addr = json.loads(output)['address']
            c['address'] = addr
            success(f"New wallet initialized: {addr}")
            extract_seed_phrase(c, password)
        else:
            env = environment(c, password)
            env['RESET_SIGNER_MNEMONIC'] = secret("Enter your 12/24-word recovery mnemonic")
            output = run([c['node'], str(pathlib.Path(c['repo']) / 'signer/bin/reset-signer.mjs'),
                          'import', '--directory', directory], env=env, capture=True).stdout
            addr = json.loads(output)['address']
            c['address'] = addr
            success(f"Wallet imported: {addr}")
    return password

def credentials_path(c):
    return BASE / 'credentials.json' if c.get('persistent_credentials', True) else RUN / 'credentials.json'

def credentials(c, prompt=False):
    f = credentials_path(c)
    if f.exists():
        return read_json(f)
    if not prompt:
        fail("Run 'reset-vps start' to enter password.")
    s = {'password': secret("Enter keystore password"), 'api_key': ''}
    cli(c, ['address'], s['password'])
    if c.get('mode') == 'ai' and c.get('provider') not in ('ollama', 'lmstudio'):
        s['api_key'] = secret("Model API key")
    write_json(f, s)
    return s

def settings(c, pwd):
    say("\n--- CONFIGURATION & MINING SETTINGS ---")
    info("Faucet currently grants 0.01 RESET (~$2-4). Recommended deposit target: 0.01 or 0.1")
    cap = ask("Target deposit in Mine (RESET, minimum 0.01)", c.get('lock_cap', '0.01'))
    if not re.fullmatch(r'(0|[1-9]\d{0,12})(\.\d{1,8})?', cap) or decimal.Decimal(cap) < decimal.Decimal('0.01'):
        fail("Deposit target must be >= 0.01 RESET.")
    c['lock_cap'] = cap

    mode = ask("Mining Mode: 1) Fair Share (No API key needed) | 2) AI Agent", "1" if c.get('mode', 'fair') == 'fair' else "2")
    c.update(mode='fair' if mode == '1' else 'ai', provider='openmayhem', model='qwen/qwen3.8-flash-next', base_url='')
    api = ''
    if mode == '2':
        c['provider'] = ask("AI Provider", "openmayhem")
        c['model'] = ask("Model ID", "qwen/qwen3.8-flash-next" if c['provider'] == 'openmayhem' else "")
        if c['provider'] == 'custom':
            c['base_url'] = ask("Custom OpenAI-compatible base URL")
        if c['provider'] not in ('ollama', 'lmstudio'):
            api = secret("Model API key")

    c['gateway'] = 'https://reset.openmayhem.ai'
    c['header_source'] = 'https://mempool.space'
    c['port'] = int(ask("Local dashboard port", str(c.get('port', 4747))))
    c['persistent_credentials'] = yes("Enable unattended auto-start on VPS reboot?", c.get('persistent_credentials', True))

    write_json(CFG, c)
    write_json(credentials_path(c), {'password': pwd, 'api_key': api})

def units_files(c):
    for role, name in [('mine', SERVICES[0]), ('dashboard', SERVICES[1])]:
        p = pathlib.Path('/etc/systemd/system') / name
        p.write_text(f'''{MARKER}
[Unit]
Description=RESET VPS {role.capitalize()} Service
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=600
StartLimitBurst=6

[Service]
Type=simple
User=root
UMask=0077
WorkingDirectory={BASE}
ExecStart=/usr/bin/python3 {BASE}/manager.py _launch {role}
Restart=on-failure
RestartSec=20
TimeoutStopSec=180
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths={c['directory']} {c['state_dir']} {RUN}
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
LogRateLimitIntervalSec=30s
LogRateLimitBurst=200

[Install]
WantedBy=multi-user.target
''')
        os.chmod(p, 0o644)
    pathlib.Path('/etc/tmpfiles.d/reset-vps.conf').write_text(f"{MARKER}\nd /run/reset-vps 0700 root root -\n")
    run(['systemctl', 'daemon-reload'])
    run(['systemctl', 'enable' if c['persistent_credentials'] else 'disable', *SERVICES])

def sign_proof(c, code=None, audience=AUDIENCE):
    say("\n--- DISCORD FAUCET / BENNY PROOF SIGNER ---")
    info("Tip: Paste the code or command given by the Discord bot (or press Enter for standard Benny proof).")
    raw = code or ask("Paste Discord bot code / command / nonce", "").strip()

    cleaned = raw
    if 'sign_challenge' in raw:
        match = re.search(r'--audience\s+([^\s]+)', raw)
        if match: audience = match.group(1)
        m_code = re.search(r'([0-9a-f]{64})', raw)
        if m_code: cleaned = m_code.group(1)

    pwd = secret("Enter your wallet password to sign")
    addr = json.loads(cli(c, ['address'], pwd).stdout)['address']

    now = time.time_ns() // 1000000
    nonce = NONCE

    if not cleaned:
        info(f"Using default Benny proof nonce: {nonce}")
    elif cleaned.startswith('{') and cleaned.endswith('}'):
        try:
            pkt = json.loads(cleaned)
            pkt['address'] = addr
            nonce = pkt.get('nonce', nonce)
            audience = pkt.get('audience', audience)
        except Exception:
            pass
    elif re.fullmatch(r'[0-9a-f]{64}', cleaned.lower()):
        nonce = cleaned.lower()
        info(f"Using one-time nonce from bot: {nonce}")
    else:
        nonce = hashlib.sha256(cleaned.encode('utf-8')).hexdigest()
        info(f"Processed challenge code into 64-hex nonce: {nonce}")

    packet = {
        'v': 1,
        'domain': 'reset-mcp-login',
        'audience': audience,
        'address': addr,
        'nonce': nonce,
        'issued_at': now,
        'expires_at': now + 120000
    }

    folder = BASE / 'proofs'
    private_dir(folder)
    with tempfile.TemporaryDirectory(prefix='proof-', dir=folder) as d:
        src = pathlib.Path(d) / 'challenge.json'
        signed = pathlib.Path(d) / 'signed.json'
        write_json(src, packet)
        res = json.loads(cli(c, ['sign_challenge', str(src), '--audience', audience], pwd).stdout)
        write_json(signed, res)
        if json.loads(cli(c, ['verify', str(signed), '--audience', audience]).stdout).get('valid') is not True:
            fail("Signature verification failed!")
        write_json(folder / 'latest.json', res)

    output_line = json.dumps(res, separators=(',', ':'))
    say("\n" + "═" * 76)
    say("\033[1;32m>>> COPY AND PASTE THIS EXACT LINE BACK TO THE DISCORD BOT:\033[0m")
    say("═" * 76)
    print(output_line)
    say("═" * 76)
    say("\033[1;33m[NOTE] Proof valid for 120 seconds. Paste it right now in Discord!\033[0m\n")

def start(c):
    stop_conflicts()
    if active(SERVICES[0]):
        say("Miner service already active.")
    else:
        s = credentials(c, True)
        cli(c, ['address'], s['password'])
        run(['systemctl', 'reset-failed', SERVICES[0]], check=False)
        run(['systemctl', 'start', SERVICES[0]])
        success("Miner started in background.")

    if not active(SERVICES[1]):
        with socket.socket() as sock:
            try:
                sock.bind(('127.0.0.1', c['port']))
            except OSError:
                say(f"Dashboard port {c['port']} busy; miner is running.")
                status(c)
                return
        run(['systemctl', 'reset-failed', SERVICES[1]], check=False)
        run(['systemctl', 'start', SERVICES[1]])
        success("Dashboard service started.")
    status(c)

def status(c):
    say("\n" + "═" * 60)
    say(f"\033[1;36mRESET VPS STATUS (Wallet: {c['address'][:10]}...{c['address'][-6:]})\033[0m")
    say("═" * 60)
    for name in SERVICES:
        r = run(['systemctl', 'show', name, '--property=ActiveState,SubState,MainPID', '--no-pager'], capture=True, check=False)
        st = dict(l.split('=', 1) for l in r.stdout.strip().splitlines() if '=' in l)
        color = "\033[1;32m" if st.get('ActiveState') == 'active' else "\033[1;31m"
        say(f"{name:26} : {color}{st.get('ActiveState','unknown')} ({st.get('SubState','')})\033[0m PID={st.get('MainPID','-')}")
    say("-" * 60)
    h = BASE / 'state/health.json'
    if h.exists():
        s = read_json(h)['status']
        say(f"Wallet Balance    : \033[1;33m{s.get('balance', '0.0')} RESET\033[0m")
        say(f"Mine Deposit      : \033[1;32m{s.get('deposit', '0.0')} RESET\033[0m")
        say(f"Current Round     : {s.get('mine', {}).get('round', '-')}")
        say(f"Claim Window Open : {'YES' if s.get('mine', {}).get('window_open') else 'NO'}")
        say(f"Round Claim       : {'CLAIMED' if s.get('claim') else 'NONE'}")
        say(f"Strikes           : {s.get('strikes', 0)}")
    else:
        say("Waiting for network sync snapshot (check back in ~30s)...")
    say(f"Dashboard Local   : http://127.0.0.1:{c['port']}")
    say("═" * 60 + "\n")

def backup(c):
    f = BASE / 'backups'
    private_dir(f)
    dest = f / f"reset-keystore-{datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S')}.json"
    key_file = pathlib.Path(c['directory']) / 'keystore.json'
    dest.write_bytes(key_file.read_bytes())
    os.chmod(dest, 0o600)
    success(f"Encrypted wallet backup saved at: {dest}")

def launch(c, role):
    lock = open(RUN / f"{role}.lock", 'a')
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    os.set_inheritable(lock.fileno(), True)
    args = [c['node'], str(BASE / 'worker.mjs'), role, str(CFG)]
    if role == 'mine':
        credentials(c)
        args.append(str(credentials_path(c)))
    os.execve(c['node'], args, environment(c))

def setup():
    packages()
    node = node_runtime()
    repo = choose_repo()
    directory = safe_path(ask("Wallet directory (Enter for default)", '/root/.reset-signer'))
    c = {'version': 2, 'commit': COMMIT, 'node': node, 'repo': repo, 'directory': str(directory), 'state_dir': str(BASE / 'state')}
    ensure_deps(c)
    pwd = wallet(c)
    private_dir(BASE / 'state')
    settings(c, pwd)
    units_files(c)
    backup(c)
    success("\nGod-Mode setup completed successfully!")
    if yes("Sign Discord Faucet proof right now?", True):
        sign_proof(c)
    if yes("Start the background miner and dashboard now?", False):
        start(c)
    else:
        info("Miner not started. Whenever you want to start, run: reset-vps start")

def main():
    if len(sys.argv) > 1 and sys.argv[1] == '_launch':
        return launch(config(), sys.argv[2])
    private_dir(BASE)
    private_dir(RUN)
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'status' if CFG.exists() else 'setup'
    if cmd == 'setup':
        return setup()
    c = config()
    if cmd in ('faucet', 'proof', 'sign'):
        sign_proof(c, sys.argv[2] if len(sys.argv) > 2 else None)
    elif cmd in ('phrase', 'seed', 'show-seed'):
        pwd = secret("Enter keystore password to reveal phrase")
        extract_seed_phrase(c, pwd)
    elif cmd == 'start':
        start(c)
    elif cmd == 'status':
        status(c)
    elif cmd == 'backup':
        backup(c)
    elif cmd in ('stop', 'down'):
        run(['systemctl', 'stop', *SERVICES])
        success("Services stopped.")
    elif cmd == 'restart':
        run(['systemctl', 'restart', *SERVICES])
        status(c)
    elif cmd == 'logs':
        os.execvp('journalctl', ['journalctl', '-u', SERVICES[0], '-n', '100', '-f', '--no-pager'])
    else:
        fail("Usage: reset-vps [setup|faucet|phrase|start|status|logs|stop|restart|backup]")

if __name__ == '__main__':
    try:
        main()
    except (KeyboardInterrupt, EOFError):
        say("\nCancelled.")
        sys.exit(130)
RESET_HELPER_PY

# ------------------------------------------------------------------------------
# 2. WORKER.MJS (Dynamic Fair-Share & AI Mining Daemon)
# ------------------------------------------------------------------------------
cat > "$stage/worker.mjs" <<'RESET_HELPER_JS'
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';

export function units(s) {
  if (!/^(0|[1-9]\d{0,30})(\.\d{1,8})?$/.test(String(s))) throw new Error(`Invalid coin amount: ${s}`);
  const [a, b = ''] = String(s).split('.');
  return BigInt(a) * 100000000n + BigInt(b.padEnd(8, '0'));
}

export function coins(u) {
  const big = BigInt(u);
  return `${big / 100000000n}.${String(big % 100000000n).padStart(8, '0')}`;
}

export function lockAmount(status, cap) {
  const minLock = status.params?.min_amount ? BigInt(status.params.min_amount) : 1000000n; // 0.01 RESET
  const target = units(cap);
  const current = units(status.deposit);
  if (current >= target) return null;
  const remaining = target - current;
  const balance = units(status.balance);
  const amount = remaining < balance ? remaining : balance;
  return amount >= minLock ? coins(amount) : null;
}

function atomic(file, obj) {
  const tmp = file + `.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
  fs.renameSync(tmp, file);
}

function read(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function log(s) {
  console.log(new Date().toISOString() + ' ' + s);
}

async function main() {
  const [action, configFile, secretsFile] = process.argv.slice(2);
  const cfg = read(configFile);
  const secret = secretsFile ? read(secretsFile) : {};
  const moduleURL = p => pathToFileURL(path.join(cfg.repo, 'signer', p)).href;

  if (action === 'dashboard') {
    const { startDashboard } = await import(moduleURL('dashboard/index.mjs'));
    const dash = await startDashboard({ port: cfg.port, directory: cfg.directory, gateway: cfg.gateway });
    log(`[DASHBOARD] Active at: ${dash.url}`);
    return;
  }

  const { unlock, wipeWallet, publicAddress } = await import(moduleURL('lib/index.mjs'));
  const { createLocalMcp } = await import(moduleURL('lib/local-mcp.mjs'));
  const { createGuard, passwordProbe } = await import(moduleURL('lib/chat-guard.mjs'));

  const wallet = await unlock({ directory: cfg.directory, password: secret.password });
  let service;
  const abort = new AbortController();
  for (const s of ['SIGINT', 'SIGTERM']) process.once(s, () => abort.abort());

  try {
    if (publicAddress(wallet) !== cfg.address) throw new Error('Wallet address mismatch');
    service = await createLocalMcp({
      wallet,
      directory: cfg.directory,
      gatewayUrl: cfg.gateway,
      headerSourceUrl: cfg.header_source,
      role: 'mine',
      processRole: 'mine-agent',
      guard: createGuard({ wallet, passwordSeen: passwordProbe(secret.password) }),
      maxAttempts: 10000000,
      maxWorkMs: 90000
    });
    secret.password = undefined;

    const ledgerFile = path.join(cfg.state_dir, 'actions.json');
    let ledger = fs.existsSync(ledgerFile) ? read(ledgerFile) : { address: cfg.address, gateway: cfg.gateway, claim_round: null, lock: null };
    const save = () => atomic(ledgerFile, ledger);
    const status = async () => {
      const r = await service.call('status');
      if (r.error || !r.data?.mine) throw new Error(r.data || 'Status unavailable');
      return r.data;
    };

    let lastHeaders = 0, lastSummary = 0, lastTip = null, lastTipAt = Date.now();
    log(`[MINER] Running in ${cfg.mode} mode for ${cfg.address}. Target deposit: ${cfg.lock_cap} RESET.`);

    while (!abort.signal.aborted) {
      try {
        let s = await status();
        const minReq = s.params?.min_amount ? BigInt(s.params.min_amount) : 1000000n; // 0.01 RESET

        if (s.tip !== lastTip) {
          lastTip = s.tip;
          lastTipAt = Date.now();
        }

        if (Date.now() - lastHeaders >= 600000) {
          lastHeaders = Date.now();
          try {
            const r = await service.call('post_headers');
            if (r.data?.headers) log(`[HEADERS] Submitted ${r.data.headers} Bitcoin headers.`);
          } catch {
            log('[HEADERS] Header check skipped or already up to date.');
          }
          s = await status();
        }

        if (ledger.lock && units(s.deposit) >= units(ledger.lock.target)) {
          ledger.lock = null;
          save();
        }

        const amount = lockAmount(s, cfg.lock_cap);
        if (amount && !ledger.lock && s.moves_left > 0 && s.capacity_left > 0 && !abort.signal.aborted) {
          ledger.lock = {
            amount,
            target: coins(units(s.deposit) + units(amount)),
            at: new Date().toISOString(),
            outcome: 'pending'
          };
          save();
          log(`[LOCK] Locking ${amount} RESET towards deposit target...`);
          const r = await service.call('lock', { amount });
          ledger.lock.outcome = r.data?.outcome || 'unknown';
          save();
          log(`[LOCK] Lock ${amount} result: ${ledger.lock.outcome}`);
          s = await status();
        }

        if (s.mine.window_open && !s.claim && units(s.deposit) >= minReq && s.moves_left > 0 && s.capacity_left > 0 && ledger.claim_round !== s.mine.round && !abort.signal.aborted) {
          ledger.claim_round = s.mine.round;
          save();
          const r = await service.call('mine_claim', { level: 1000, allow_over: false });
          log(`[CLAIM] Round ${s.mine.round} claim submitted (level 1000): ${r.data?.outcome || 'accepted'}`);
        }

        atomic(path.join(cfg.state_dir, 'health.json'), {
          checked_at: new Date().toISOString(),
          last_tip_change: new Date(lastTipAt).toISOString(),
          status: s,
          pending_lock: ledger.lock
        });

        if (Date.now() - lastSummary >= 300000) {
          lastSummary = Date.now();
          log(`[HEARTBEAT] Balance: ${s.balance} | Deposit: ${s.deposit} | Round: ${s.mine.round} | Claim: ${s.claim ? 'DONE' : 'NONE'} | Strikes: ${s.strikes}`);
          if (units(s.balance) < minReq && units(s.deposit) < minReq) {
            log(`[NOTICE] Balance is below ${coins(minReq)} RESET. Use 'reset-vps faucet' to sign the Discord faucet code.`);
          }
        }
      } catch (e) {
        log(`[CYCLE] ${String(e.message).slice(0, 200)}. Retrying in 60s.`);
      }

      await delay(60000, undefined, { signal: abort.signal }).catch(() => {});
    }
  } finally {
    await service?.close();
    wipeWallet(wallet);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch(e => {
    console.error(e.message);
    process.exitCode = 1;
  });
}
RESET_HELPER_JS

mkdir -p /opt/reset-vps
install -m 600 "$stage/manager.py" /opt/reset-vps/manager.py
install -m 600 "$stage/worker.mjs" /opt/reset-vps/worker.mjs
cat > /usr/local/bin/reset-vps <<'RESET_LAUNCH'
#!/bin/sh
exec /usr/bin/python3 /opt/reset-vps/manager.py "$@"
RESET_LAUNCH
chmod 755 /usr/local/bin/reset-vps
flock -u 9
exec 9>&-
python3 /opt/reset-vps/manager.py "$@"
