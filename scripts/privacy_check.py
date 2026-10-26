#!/usr/bin/env python3
"""Allowlisted publication check; never reads login or runtime directories."""
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = {
    'AlertAppearance', 'App', 'TiboResetMonitor', 'DemoPreview', 'PersonalPlan',
    'TiboAlert', 'LoginLaunch', 'ResetAnnouncementTime', 'TiboPostLink',
    'BatteryIcon', 'UsageClient', 'UsageModels', 'ResetCountdown',
}
TESTS = {
    'UsageModelsTests', 'UsageClientTests', 'ResetCountdownTests',
    'TiboResetMonitorTests', 'TiboAlertTests', 'ResetAnnouncementTimeTests',
    'TiboPostLinkTests',
}
ALLOWED = {f'Source/{name}.swift' for name in SOURCE} | {
    f'Tests/{name}.swift' for name in TESTS
} | {
    '.gitignore', 'README.md', 'PRIVACY.md', 'PROMPT.md', 'LICENSE', 'CHANGELOG.md',
    'build.sh', 'test.sh', 'install.sh', '一键安装.command',
    'scripts/install.sh', 'scripts/package.sh', 'scripts/privacy_check.py',
    'Tests/test_install.py', 'docs/使用说明.md', 'docs/RELEASE.md',
    '.github/workflows/check.yml', '.github/workflows/release.yml',
}
PATTERNS = {
    'private absolute path': r'/(?:Users|Volumes)/[^\s\"\']+',
    'personal email': r'[\w.+-]+@(?:gmail|outlook|hotmail|icloud|qq|163)\.[a-z]+',
    'private key': r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    'API credential': r'\b(?:sk-[A-Za-z0-9_-]{24,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})',
    'JWT credential': r'\beyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.',
    'chat identifier': r'codex://threads/[a-fA-F0-9-]{36}',
}
errors = []
seen = set()
for path in ROOT.rglob('*'):
    relative = path.relative_to(ROOT)
    if relative.parts[0] in {'.git', 'build', 'dist'}:
        continue
    if path.is_symlink():
        errors.append(f'{relative}: symlink is not a publication file')
        continue
    if not path.is_file():
        continue
    key = relative.as_posix()
    seen.add(key)
    if key not in ALLOWED:
        errors.append(f'{relative}: not on public allowlist')
        continue
    text = path.read_text(encoding='utf-8')
    for label, pattern in PATTERNS.items():
        if re.search(pattern, text, flags=re.IGNORECASE):
            errors.append(f'{relative}: {label}')
for name in sorted(ALLOWED - seen):
    errors.append(f'{name}: missing publication file')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print(f'Public file check passed: {len(seen)} allowlisted files; no sensitive patterns found.')
