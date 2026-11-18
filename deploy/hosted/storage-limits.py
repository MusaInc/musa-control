#!/usr/bin/python3
"""Bind throttles to the currently mounted loop device before every start."""
import json, subprocess
home='/var/lib/musa-tenants/hafsa/home'
subprocess.run(['mountpoint','-q',home],check=True)
device=subprocess.check_output(['findmnt','-n','-o','SOURCE',home],text=True).strip()
if not device.startswith('/dev/loop'): raise SystemExit('Refusing unbounded/non-loop tenant storage')
limits={'BlkioDeviceReadBps':[{'Path':device,'Rate':20*1024*1024}],
        'BlkioDeviceWriteBps':[{'Path':device,'Rate':10*1024*1024}]}
subprocess.run(['curl','--fail-with-body','--silent','--show-error','--unix-socket','/var/run/docker.sock','-X','POST','-H','Content-Type: application/json','--data-binary','@-','http://localhost/containers/musa-hafsa/update'],input=json.dumps(limits),text=True,check=True,stdout=subprocess.DEVNULL)
