#!/usr/bin/env bats

load test_helper

setup() {
  homelab_test_setup
}

@test "pfSense libvirt domain XML remains headless" {
  local xml
  xml=$(homelab_fixture "libvirt/pfsense-headless.xml")
  [[ -f ${xml} ]] || fail "Fixture not found: ${xml}"

  run python3 - "${xml}" <<'PY'
import sys
import xml.etree.ElementTree as ET
path = sys.argv[1]
root = ET.parse(path).getroot()
issues = []
graphics = root.findall('./devices/graphics')
if graphics:
    issues.append('graphics elements present')
video = root.findall('./devices/video')
if video:
    issues.append('video devices present')
consoles = root.findall('./devices/console')
if not consoles:
    issues.append('console element missing')
else:
    serial_targets = [c.find('target') for c in consoles]
    if not all(t is not None and t.get('type') == 'serial' for t in serial_targets):
        issues.append('console target not serial')
serials = root.findall('./devices/serial')
if not serials:
    issues.append('serial element missing')
else:
    if not any(s.get('type') == 'pty' for s in serials):
        issues.append('expected pty-backed serial console')
if issues:
    print('; '.join(issues))
    sys.exit(1)
PY
  assert_success
}
