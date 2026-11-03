"""Run one explicit RTL test suite using Icarus Verilog; no hardware access."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
SUITES_FILE = Path(__file__).with_name('suites.json')


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def executable(value):
    resolved = shutil.which(value)
    if resolved is None:
        raise FileNotFoundError('Executable not found: ' + value)
    return str(Path(resolved).resolve())


def main():
    suites = json.loads(SUITES_FILE.read_text(encoding='utf-8'))
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('suite', nargs='?', choices=sorted(suites))
    parser.add_argument('--list', action='store_true', help='List suites without running tools')
    parser.add_argument('--iverilog', default=os.environ.get('IVERILOG', 'iverilog'))
    parser.add_argument('--vvp', default=os.environ.get('VVP', 'vvp'))
    parser.add_argument('--timeout', type=int, default=600, help='Maximum seconds per compile/run stage')
    args = parser.parse_args()
    if args.list:
        for name in sorted(suites):
            print(name)
        return 0
    if args.suite is None:
        parser.print_help()
        return 0
    if args.timeout <= 0:
        parser.error('--timeout must be positive')

    suite = suites[args.suite]
    sources = [(ROOT / name).resolve() for name in suite['sources']]
    for path in sources:
        path.relative_to(ROOT)
        if not path.is_file():
            raise FileNotFoundError(path)
    compiler = executable(args.iverilog)
    runtime = executable(args.vvp)
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    out = ROOT / 'build' / 'tests' / (args.suite + '-' + stamp)
    out.mkdir(parents=True, exist_ok=False)
    image = out / 'test.vvp'
    record = {
        'suite': args.suite,
        'status': 'running',
        'hardware_access': False,
        'started_utc': datetime.now(timezone.utc).isoformat(),
        'inputs': {p.relative_to(ROOT).as_posix(): sha256(p) for p in sources},
        'stages': {},
    }
    commands = [
        ('compile', [compiler, '-g2012', '-Wall', '-I', str(ROOT / 'fpga'),
                     '-s', suite['top'], '-o', str(image), *map(str, sources)]),
        ('run', [runtime, '-i', str(image)]),
    ]
    try:
        for name, command in commands:
            result = subprocess.run(
                command, cwd=ROOT / 'fpga', capture_output=True, text=True,
                errors='replace', timeout=args.timeout, check=False,
                creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0),
            )
            output = result.stdout + result.stderr
            (out / (name + '.log')).write_text(output, encoding='utf-8')
            record['stages'][name] = {'returncode': result.returncode}
            if result.returncode != 0:
                raise RuntimeError(name + ' failed; inspect ' + name + '.log')
        if suite['pass_marker'] not in output:
            raise RuntimeError('Expected final test marker was not produced')
        if any(sha256(ROOT / name) != value for name, value in record['inputs'].items()):
            raise RuntimeError('An input changed during the run')
        record['status'] = 'passed'
        record['pass_marker'] = suite['pass_marker']
    except Exception as exc:
        record['status'] = 'failed'
        record['error'] = str(exc)
    finally:
        record['ended_utc'] = datetime.now(timezone.utc).isoformat()
        (out / 'result.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print(args.suite + ': ' + record['status'])
    print(out.relative_to(ROOT).as_posix())
    return 0 if record['status'] == 'passed' else 1


if __name__ == '__main__':
    sys.exit(main())
