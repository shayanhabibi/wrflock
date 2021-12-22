when defined(windows):
  import pkg/waitonaddress

  proc wait*[T](monitor: ptr T; compare: T; time: static int = 0): bool {.inline, discardable.} =
    when time == 0:
      const t = INFINITE
    else:
      const t = time
    result = waitOnAddress(monitor, compare.unsafeAddr, sizeof(T).int32, t)
      

  proc wake*(monitor: pointer) {.inline.} =
    wakeByAddressSingle(monitor)

  proc wakeAll*(monitor: pointer) {.inline.} =
    wakeByAddressAll(monitor)
elif defined(linux):
  import pkg/futex
  import std/posix

  proc wait*[T](monitor: ptr T, compare: T; time: static int = 0): bool {.inline, discardable.} =
    ## Suspend a thread if the value of the futex is the same as refVal.
    
    # Returns 0 in case of a successful suspend
    # If value are different, it returns EWOULDBLOCK
    # We discard as this is not needed and simplifies compat with Windows futex
    when time == 0:
      result = not(sysFutex(monitor, FutexWaitPrivate, cast[cint](compare)) != 0.cint)
    else:
      var timeout: posix.TimeSpec
      timeout.tv_sec = posix.Time(time div 1_000)
      timeout.tv_nsec = (time mod 1_000) * 1_000 * 1_000
      result = not(sysFutex(monitor, FutexWaitPrivate, cast[cint](compare), timeout = timeout.addr) != 0.cint)

  proc wake*(monitor: pointer) {.inline.} =
    ## Wake one thread (from the same process)

    # Returns the number of actually woken threads
    # or a Posix error code (if negative)
    # We discard as this is not needed and simplifies compat with Windows futex
    discard sysFutex(monitor, FutexWakePrivate, 1)

  proc wakeAll*(monitor: pointer) {.inline.} =
    discard sysFutex(monitor, FutexWakePrivate, high(cint))
elif defined(macosx):
  import pkg/ulock
  
  proc wait*[T](monitor: ptr T; compare: T; time: static int = 0): bool {.inline, discardable.} =
    when time == 0:
      ulock_wait(UL_COMPARE_AND_WAIT, monitor, cast[uint64](compare), high(uint32).uint32) >= 0
    else:
      ulock_wait(UL_COMPARE_AND_WAIT, monitor, cast[uint64](compare), (time * 1000).uint32) >= 0

  proc wake*(monitor: pointer) {.inline.} =
    discard ulock_wake(UL_COMPARE_AND_WAIT or ULF_WAKE_THREAD, monitor, cast[uint64](0))

  proc wakeAll*(monitor: pointer) {.inline.} =
    discard ulock_wake(UL_COMPARE_AND_WAIT or ULF_WAKE_ALL, monitor, cast[uint64](0))

else:
  proc wait*[T](monitor: ptr T; compare: T; time: static int = 0): bool {.inline, discardable.} =
    {.fatal: "Your OS is not supported with implemented futexes, please submit an issue".}
  proc wake*(monitor: pointer) {.inline.} =
    {.fatal: "Your OS is not supported with implemented futexes, please submit an issue".}
  proc wakeAll*(monitor: pointer) {.inline.} =
    {.fatal: "Your OS is not supported with implemented futexes, please submit an issue".}
