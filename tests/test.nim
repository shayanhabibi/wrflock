import wrflock

let v = newWRFLock()
echo v.facquire()
echo v.wacquire()
echo v.wrelease()
echo v.racquire()
echo v.racquire()
echo v.racquire()