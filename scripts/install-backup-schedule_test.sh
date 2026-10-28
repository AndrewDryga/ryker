#!/bin/bash
# Seven scheduled backups failed while other Docker contexts were selected.
# Every host supervisor must retain the installation's context after logout.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
python3 - "$root" <<'PY'
import os
import pathlib
import plistlib
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
with tempfile.TemporaryDirectory() as directory:
    scratch = pathlib.Path(directory)
    binaries = scratch / 'bin'
    binaries.mkdir()
    for name, body in {
        'docker': '#!/bin/sh\n[ "$*" = "context show" ] || exit 2\nprintf "%s\\n" "${DOCKER_CONTEXT:-wrong-default}"\n',
        'launchctl': '#!/bin/sh\ncase "$1" in\nprint) test -f "$LAUNCH_TEST_STATE";;\nbootstrap) touch "$LAUNCH_TEST_STATE";;\nbootout) rm -f "$LAUNCH_TEST_STATE";;\nesac\n',
        'plutil': '#!/bin/sh\nexit 0\n',
    }.items():
        path = binaries / name
        path.write_text(body)
        path.chmod(0o755)
    # Only the child installer sees this isolated home; no developer agent is reloaded.
    environment = dict(os.environ, HOME=str(scratch / 'account'),
                       PATH=str(binaries) + ':' + os.environ['PATH'],
                       DOCKER_CONTEXT='installation-context',
                       LAUNCH_TEST_STATE=str(scratch / 'registered'))
    for script, label in [('install-backup-schedule.sh', 'backup'),
                          ('install-auto-upgrade.sh', 'upgrade'),
                          ('install-watchdog.sh', 'watchdog')]:
        subprocess.run(['bash', str(root / 'scripts' / script)], env=environment,
                       check=True, stdout=subprocess.DEVNULL)
        path = scratch / 'account/Library/LaunchAgents' / f'ai.emisar.ryker.{label}.plist'
        with path.open('rb') as stream:
            document = plistlib.load(stream)
        assert document.get('EnvironmentVariables', {}).get('DOCKER_CONTEXT') == 'installation-context', \
            f'{label} lost the installation context and will follow another Docker daemon'
        print(f'ok   {label} retains its installation Docker context')

    # A fresh deployment backup must not hide a week of failed daily backups.
    for name, body in {'curl': '#!/bin/sh\nexit 1\n', 'gh': '#!/bin/sh\nprintf "[]"\n'}.items():
        path = binaries / name
        path.write_text(body)
        path.chmod(0o755)
    installation = scratch / 'installation'
    backups = installation / 'backups'
    backups.mkdir(parents=True)
    (installation / 'compose.env').write_text('RYKER_CONTROL_PORT=4321\n')
    old = backups / 'scheduled-20261019T033017Z.tar.gz'
    old.write_text('old daily backup')
    os.utime(old, (1, 1))
    (backups / 'pre-deploy-new.tar.gz').write_text('fresh deployment backup')
    environment['RYKER_INSTALL_STATE'] = str(installation)
    status = subprocess.check_output(['bash', str(root / 'scripts/status.sh')],
                                     env=environment, text=True)
    assert 'DAILY BACKUP OVERDUE' in status, status
    print('ok   a new deployment backup cannot hide an overdue daily backup')
PY
