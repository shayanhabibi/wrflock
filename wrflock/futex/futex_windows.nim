const
  INFINITE = -1

proc waitOnAddress[T](address: ptr T; compare: ptr T; size: int32;
                      dwMilliseconds: int32): bool {.stdcall, dynlib: "API-MS-Win-Core-Synch-l1-2-0", importc: "WaitOnAddress".}
proc wakeByAddressSingle(address: pointer) {.stdcall, dynlib: "API-MS-Win-Core-Synch-l1-2-0", importc: "WakeByAddressSingle".}
proc wakeByAddressAll(address: pointer) {.stdcall, dynlib: "API-MS-Win-Core-Synch-l1-2-0", importc: "WakeByAddressAll".}

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