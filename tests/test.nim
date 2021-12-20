import std/os

import wrflock

let v = initWRFLock()
echo v.facquire()
echo v.wacquire()
echo v.wrelease()
echo v.racquire()
echo v.racquire()
echo v.racquire()