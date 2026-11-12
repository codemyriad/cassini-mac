#!/usr/bin/env python3
"""Launch one runner only after its Aqua virtual display is active."""
import ctypes,json,os,select,subprocess,time
from pathlib import Path
home=Path.home();ready=home/'Library/Caches/cassini-gui/display.json'
assert os.getuid()==503 and os.stat('/dev/console').st_uid==503
cg=ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
cg.CGDisplayIsActive.argtypes=[ctypes.c_uint32];cg.CGDisplayIsActive.restype=ctypes.c_uint32
fd=os.open(ready.parent,os.O_RDONLY);queue=select.kqueue()
queue.control([select.kevent(fd,filter=select.KQ_FILTER_VNODE,flags=select.KQ_EV_ADD|select.KQ_EV_CLEAR,fflags=select.KQ_NOTE_WRITE)],0)
deadline=time.monotonic()+120
try:
 while True:
  try:
   state=json.loads(ready.read_text())
   if cg.CGDisplayIsActive(state['displayId']) and state['pixelWidth']==state['width'] and state['pixelHeight']==state['height']:break
  except (OSError,ValueError,KeyError):pass
  remaining=deadline-time.monotonic()
  if remaining<=0:raise RuntimeError('No active unscaled GUI display before startup hang guard')
  queue.control([],1,remaining)
finally:queue.close();os.close(fd)
subprocess.run(['/usr/bin/osascript','-e','set volume output muted true'],check=True)
os.chdir(home/'runner')
os.execv(str(home/'runner/run.sh'),[str(home/'runner/run.sh')])
