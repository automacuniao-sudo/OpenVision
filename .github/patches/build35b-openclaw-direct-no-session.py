from pathlib import Path
p = Path('JARVIS/Services/OpenClaw/OpenClawService.swift')
s = p.read_text()
old = '''            "sessionKey": Self.sessionKey,\n            "idempotencyKey": UUID().uuidString,\n'''
new = '''            "idempotencyKey": UUID().uuidString,\n'''
if old not in s:
    raise SystemExit('Build35 direct invocation anchor not found')
p.write_text(s.replace(old, new, 1))
print('Removed optional sessionKey from direct tools.invoke')
