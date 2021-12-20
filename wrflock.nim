import std/times

import wtbanland/futex

import wrflock/spec

type
  WRFLockObj* = object
    data: uint
  WRFLockObjU* = object
    data: array[2, uint32]
  WRFLock* = ptr WRFLockObj
  WRFLockU* = ptr WRFLockObjU

# ============================================================================ #
# Define helpers
# ============================================================================ #
template loadState(lock: WRFLock, order = ATOMIC_RELAXED): uint32 =
  cast[WRFLockU](lock).data[stateOffset].addr.atomicLoadN(order)

proc `[]`(lock: WRFLock, idx: int): var uint32 {.inline.} =
  cast[WRFLockU](lock).data[idx]

# ============================================================================ #
# Define Constructors and Destructors
# ============================================================================ #
proc initWRFLockObj(lock: var WRFLockObj; waitType: int; pshared: bool) =  
  if pshared:
    lock.data = privateMask64 or nextStateWriteMask64
  else:
    lock.data = 0u
  
  if (waitType and wWaitYield) != 0:
    lock.data = lock.data or wWaitYieldMask64
  if (waitType and rWaitYield) != 0:
    lock.data = lock.data or rWaitYieldMask64
  if (waitType and fWaitYield) != 0:
    lock.data = lock.data or fWaitYieldMask64

proc initWRFLockObj(waitType: int = 0; pshared: bool = false): WRFLockObj =
  result = WRFLockObj()
  initWRFLockObj(result, waitType, pshared)

proc initWRFLock*(waitType: int = 0; pshared: bool = false): WRFLock =
  result = createShared(WRFLockObj)
  result[] = initWRFLockObj(waitType, pshared)

proc freeWRFLock*(lock: WRFLock) =
  freeShared(lock)

# ============================================================================ #
# Define Acquires
# ============================================================================ #
proc wAcquire*(lock: WRFLock): bool {.discardable.} =
  var newData, data: uint32
  data = lock.loadState

  template lop: untyped =
    if (data and wrAcquireValueMask32) != 0u:
      return false # Overflow error
    newData = data or wrAcquireValueMask32
    if (newData and frAcquireValueMask32) != 0u:
      newData = newData or rdNxtLoopFlagMask32
    if (newData and nextStateWriteMask32) != 0u:
      newData = newData xor (nextStateWriteMask32 or currStateWriteMask32)
  
  lop()
  while not lock[stateOffset].addr.atomicCompareExchange(data.addr, newdata.addr, true, ATOMIC_RELAXED, ATOMIC_RELAXED):
    lop()

  result = true

proc rAcquire*(lock: WRFLock): bool {.discardable.} =
  var newData, data: uint32
  data = lock.loadState

  while (data and rdNxtLoopFlagMask32) != 0u:
    if (data and rWaitYieldMask32) != 0u:
      cpuRelax()
    else:
      wait(lock[stateOffset].addr, data)
    data = lock.loadState
  
  if (data and rdAcquireCounterMask32) == rdAcquireCounterMask32:
    return false # Overflow error
  newData = data + (1 shl rdAcquireCounterShift32)

  while not lock[countersOffset].addr.atomicCompareExchange(data.addr, newdata.addr, true, ATOMIC_RELAXED, ATOMIC_RELAXED):
    if (data and rdAcquireCounterMask32) == rdAcquireCounterMask32:
      return false # Overflow error
    newData = data + (1 shl rdAcquireCounterShift32)
  
  data = lock.loadState

  newData = data or rdAcquireValueMask32
  if (newData and nextStateReadFreeMask32) != 0u:
    newData = newData xor (nextStateReadFreeMask32 or currStateReadMask32)
  while not lock[countersOffset].addr.atomicCompareExchange(data.addr, newdata.addr, true, ATOMIC_RELAXED, ATOMIC_RELAXED):
    newData = data or rdAcquireValueMask32
    if (newData and nextStateReadFreeMask32) != 0u:
      newData = newData xor (nextStateReadFreeMask32 or currStateReadMask32)
  
  result = true

proc fAcquire*(lock: WRFLock): bool {.discardable.} =
  var newData, data: uint32
  data = lock.loadState

  if (data and frAcquireValueMask32) != 0u:
    return false # Overflow error
  newData = data or frAcquireValueMask32
  if (newData and nextStateReadFreeMask32) != 0u:
    newData = newData xor (nextStateReadFreeMask32 or currStateFreeMask32)
  while not lock[stateOffset].addr.atomicCompareExchange(data.addr, newdata.addr, true, ATOMIC_RELAXED, ATOMIC_RELAXED):
    if (data and frAcquireValueMask32) != 0u:
      return false # Overflow error
    newData = data or frAcquireValueMask32
    if (newData and nextStateReadFreeMask32) != 0u:
      newData = newData xor (nextStateReadFreeMask32 or currStateFreeMask32)

  result = true

# ============================================================================ #
# Define releases
# ============================================================================ #
proc wRelease*(lock: WRFLock): bool {.discardable.} =
  var newData, data: uint32
  data = lock.loadState

  template lop: untyped =
    if (data and wrAcquireValueMask32) == 0u:
      return false # Overflow error
    newData = data and not(wrAcquireValueMask32 or currStateWriteMask32 or rdNxtLoopFlagMask32)
    if (newData and rdAcquireValueMask32) != 0u:
      newData = newData or currStateReadMask32
    elif (newData and frAcquireValueMask32) != 0u:
      newData = newData or currStateFreeMask32
    else:
      newData = nextStateReadFreeMask32
  
  lop()
  while not lock[stateOffset].addr.atomicCompareExchange(data.addr, newdata.addr, true, ATOMIC_RELEASE, ATOMIC_RELAXED):
    lop()
  
  if (
    (
      ((newData and rWaitYieldMask32) == 0u) and
      ((newData and (currStateReadMask32 or rdNxtLoopFlagMask32)) != 0u)
    ) or
    (
      ((newData and fWaitYieldMask32) == 0u) and
      ((newData and currStateFreeMask32) != 0u)
    )
  ):
    wakeAll(lock[stateOffset].addr)

  result = true

proc rRelease*(lock: WRFLock): bool {.discardable.} =
  var newData, data: uint
  data = lock.data.addr.atomicLoadN(ATOMIC_RELAXED)

  template lop: untyped =
    if (data and rdAcquireCounterMask64) == 0u:
      return false # Overflow error
    newData = data - (1 shl rdAcquireCounterShift64)
    if (newData and rdAcquireCounterMask64) == 0u:
      newData = newData and not(rdAcquireValueMask64)
      if (newData and frAcquireValueMask64) != 0u:
        newData = newData xor (currStateReadMask64 or currStateFreeMask64)
      else:
        newData = newData xor (currStateReadMask64 or nextStateReadFreeMask64)
  
  lop()
  while not lock.data.addr.atomicCompareExchange(data.addr, newdata.addr, true, ATOMIC_RELEASE, ATOMIC_RELAXED):
    lop()
  
  if (
    ((newData and fWaitYieldMask64) == 0u) and
    ((newData and currStateFreeMask64) != 0u)
  ):
    wakeAll(lock[stateOffset].addr)
    
  result = true

proc fRelease*(lock: WRFLock): bool {.discardable.} =
  var newData, data: uint32
  data = lock.loadState

  template lop: untyped =
    if (data and frAcquireValueMask32) != 0u:
      return false # Overflow error
    newData = data and not(frAcquireValueMask32 or currStateFreeMask32)
    if (newData and wrAcquireValueMask32) != 0u:
      newData = newData or currStateWriteMask32
    else:
      newData = newData or nextStateWriteMask32
  
  lop()
  while not lock[stateOffset].addr.atomicCompareExchange(data.addr, newdata.addr, true, ATOMIC_RELEASE, ATOMIC_RELAXED):
    lop()
  
  if (
    ((newData and wWaitYieldMask32) == 0u) and
    ((newData and currStateWriteMask32) != 0u)
  ):
    wakeAll(lock[stateOffset].addr)
  
  result = true

# ============================================================================ #
# Define waits
# ============================================================================ #
proc wTimeWait*(lock: WRFLock, time: int = 0): bool {.discardable.} =
  let stime = getTime()
  var data: uint32
  var dur: Duration
  if time > 0:
    dur = initDuration(milliseconds = time)

  while true:
    data = lock.loadState
    if (data and currStateWriteMask32) != 0u:
      atomicThreadFence(ATOMIC_ACQUIRE)
      result = true
      break
    if (data and wWaitYieldMask32) == 0u:
      wait(lock[stateOffset].addr, data)
    else:
      if time > 0:
        if getTime() > (stime + dur):
          result = false # timed out
          break
      cpuRelax()

proc rTimeWait*(lock: WRFLock, time: int = 0): bool {.discardable.} =
  let stime = getTime()
  var data: uint32
  var dur: Duration
  if time > 0:
    dur = initDuration(milliseconds = time)
  while true:
    data = lock.loadState
    if (data and currStateReadMask32) != 0u:
      atomicThreadFence(ATOMIC_ACQUIRE)
      result = true
      break
    if (data and rWaitYieldMask32) == 0u:
      wait(lock[stateOffset].addr, data)
    else:
      if time > 0:
        if getTime() > (stime + dur):
          result = false # timed out
          break
      cpuRelax()

proc fTimeWait*(lock: WRFLock, time: int = 0): bool {.discardable.} =
  let stime = getTime()
  var data: uint32
  var dur: Duration
  if time > 0:
    dur = initDuration(milliseconds = time)
  while true:
    data = lock.loadState
    if (data and currStateFreeMask32) != 0u:
      atomicThreadFence(ATOMIC_ACQUIRE)
      result = true
      break
    if (data and fWaitYieldMask32) == 0u:
      wait(lock[stateOffset].addr, data)
    else:
      if time > 0:
        if getTime() > (stime + dur):
          result = false # timed out
          break
      cpuRelax()
    
proc wWait*(lock: WRFLock): bool {.discardable.} = wTimeWait(lock, 0)
proc rWait*(lock: WRFLock): bool {.discardable.} = rTimeWait(lock, 0)
proc fWait*(lock: WRFLock): bool {.discardable.} = fTimeWait(lock, 0)

proc wTryWait*(lock: WRFLock): bool {.discardable.} =
  let data = lock.loadState(ATOMIC_ACQUIRE)
  if (data and currStateWriteMask32) == 0u:
    result = false
  result = true

proc rTryWait*(lock: WRFLock): bool {.discardable.} =
  let data = lock.loadState(ATOMIC_ACQUIRE)
  if (data and currStateReadMask32) == 0u:
    result = false
  result = true
  
proc fTryWait*(lock: WRFLock): bool {.discardable.} =
  let data = lock.loadState(ATOMIC_ACQUIRE)
  if (data and currStateFreeMask32) == 0u:
    result = false
  result = true