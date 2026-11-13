#!/usr/bin/env python3
"""Discover an installed development certificate's team without storing it."""
import re
import subprocess
certificate = subprocess.run(['/usr/bin/security', 'find-certificate', '-c', 'Apple Development', '-p'], capture_output=True)
subject = subprocess.run(['/usr/bin/openssl', 'x509', '-noout', '-subject'], input=certificate.stdout, capture_output=True)
match = re.search(r'OU\s*=\s*([A-Z0-9]+)', subject.stdout.decode())
if match:
    print(match.group(1))
