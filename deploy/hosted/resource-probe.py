import json, os, subprocess, time
# Run inside tenant cgroup; no host memory pressure beyond its existing cap.
def counters():
    return dict(line.split() for line in open('/sys/fs/cgroup/cpu.stat'))
a=counters()
procs=[subprocess.Popen(['python3','-c','import time\ne=time.monotonic()+3\nwhile time.monotonic()<e: pass']) for _ in range(2)]
for p in procs: p.wait()
b=counters()
assert int(b['nr_throttled']) > int(a['nr_throttled'])
assert int(b['usage_usec'])-int(a['usage_usec']) < 4500000
print('PASS CPU stress: two busy workers throttled to the one-CPU cgroup budget')
# A child gives itself highest OOM preference. The tenant cannot consume more
# than 1.5 GiB; this verifies the actual kernel limit without risking host swap.
code="""import os
open('/proc/self/oom_score_adj','w').write('1000')
a=bytearray(2*1024*1024*1024)
"""
a=dict(l.split() for l in open('/sys/fs/cgroup/memory.events'))
p=subprocess.run(['python3','-c',code])
b=dict(l.split() for l in open('/sys/fs/cgroup/memory.events'))
assert p.returncode == -9 and int(b['oom_kill']) > int(a['oom_kill'])
print('PASS memory stress: over-limit tenant child killed by cgroup; probe survived')
