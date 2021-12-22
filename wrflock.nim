## Copyright (c) 2021 Shayan Habibi
## Copyright (c) 2019 Mariusz Orlikowski - algorithm
## 
## Pure nim implementation of a specialised lock  which enforces linear operations
## of write, reading and freeing/deallocating while allowing multiple readers,
## and a single writer and deallocator; known as the WRFLock.
## 
## Principally, the WRFLock acts as a state machine. Its advantages is the use
## of futexes or schedule yielding and a incredibly small memory footprint (8 bytes).
## 
## It's primary implementation purpose is for the Single Producer Multiple Producer
## ring buffer queue proposed by the algorithm author Mariusz Orlikowski. It's use
## is quite flexible  however and can be used in a variety of designs.
## 
## While the schedule yielding waits should be platform independent, the blocking
## waits are only implemented on operating systems that have been tested for functional
## implementations of futexes. Linux futex, darwin (macosx) ulocks and windows 
## WaitOnAddress kernel primitives are used.

import std/times
export times.`<`

import wrflock/futexes

import wrflock/spec
export wWaitBlock, wWaitYield, rWaitBlock, rWaitYield, fWaitBlock, fWaitYield

type
  WRFLockObj = object
    data: uint
  WRFLockObjU = object
    data: array[2, uint32]
  WRFLock* = ptr WRFLockObj
  WRFLockU = ptr WRFLockObjU

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
proc initWRFLockObj(lock: var WRFLockObj; waitType: openArray[int]; pshared: bool) =  
  if pshared:
    lock.data = privateMask64 or nextStateWriteMask64
  else:
    lock.data = 0u or nextStateWriteMask64
  
  if wWaitYield in waitType:
    lock.data = lock.data or wWaitYieldMask64
  if rWaitYield in waitType:
    lock.data = lock.data or rWaitYieldMask64
  if fWaitYield in waitType:
    lock.data = lock.data or fWaitYieldMask64

proc initWRFLockObj(waitType: openArray[int]; pshared: bool = false): WRFLockObj =
  result = WRFLockObj()
  initWRFLockObj(result, waitType, pshared)

proc initWRFLock*(waitType: openArray[int] = []; pshared: bool = false): WRFLock =
  ## Initialise a WRFLock. pShared arg is nonfunctional at the moment.
  ## 
  ## Default operation for write, read and free waits are blocking. Pass wWaitYield,
  ## rWaitYield and/or fWaitYield to waitType to change the operations to schedule yielding
  ## respectively.
  result = createShared(WRFLockObj)
  result[] = initWRFLockObj(waitType, pshared)

proc freeWRFLock*(lock: WRFLock) =
  ## Deallocates a WRFLock.
  freeShared(lock)

# ============================================================================ #
# Define Acquires
# ============================================================================ #
proc wAcquire*(lock: WRFLock): bool {.discardable.} =
  ## Acquires write access to the WRFLock. Will return false if there is already
  ## a writer holding write access.
  ## 
  ## This is a non blocking operation and must be coupled with a successful wWait/wTimeWait/wTryWait
  ## followed by a wRelease.
  # runnableExamples:
  #   let lock = initWRFLock()
  #   assert lock.wAcquire() # Success

  #   assert not lock.wAcquire() # Fails
  var newData, data: uint32
  data = lock.loadState

  while true:
    if (data and wrAcquireValueMask32) != 0u:
      return false # Overflow error
    newData = data or wrAcquireValueMask32
    if (newData and frAcquireValueMask32) != 0u:
      newData = newData or rdNxtLoopFlagMask32
    if (newData and nextStateWriteMask32) != 0u:
      newData = newData xor (nextStateWriteMask32 or currStateWriteMask32)
    if lock[stateOffset].addr.atomicCompareExchange(data.addr, newdata.addr, true, ATOMIC_RELAXED, ATOMIC_RELAXED):
      break

  result = true

proc rAcquire*(lock: WRFLock): bool {.discardable.} =
  ## Acquires read access to the WRFLock. Will return false if there are too many
  ## readers already holding access (65535 readers).
  ## 
  ## This is a non blocking operation and must be coupled with a successful rWait/rTimeWait/rTryWait
  ## followed by a rRelease.
  # runnableExamples:
  #   let lock = initWRFLock()
  #   assert lock.rAcquire() # Success
  #   # Alternatively:
  #   lock.rAcquire() # Automatically discards the result since
  #                   # unlikely  the barrier of 65335 readers will
  #                   # be exceeded
  var newData, data: uint32
  data = lock.loadState

  while (data and rdNxtLoopFlagMask32) != 0u:
    if (data and rWaitYieldMask32) != 0u:
      cpuRelax()
    else:
      wait(lock[stateOffset].addr, data)
    data = lock.loadState
  
  while true:
    if (data and rdAcquireCounterMask32) == rdAcquireCounterMask32:
      return false # Overflow error
    newData = data + (1 shl rdAcquireCounterShift32)
    if lock[countersOffset].addr.atomicCompareExchange(data.addr, newdata.addr, true, ATOMIC_RELAXED, ATOMIC_RELAXED):
      break
    
  data = lock.loadState

  while true:
    newData = data or rdAcquireValueMask32
    if (newData and nextStateReadFreeMask32) != 0u:
      newData = newData xor (nextStateReadFreeMask32 or currStateReadMask32)
    if lock[stateOffset].addr.atomicCompareExchange(data.addr, newdata.addr, true, ATOMIC_RELAXED, ATOMIC_RELAXED):
      break

  result = true

proc fAcquire*(lock: WRFLock): bool {.discardable.} =
  ## Acquires free access to the WRFLock. Will return false if there is already a
  ## free/deallocater.
  ## 
  ## This is a non blocking operation and must be coupled with a successful fWait/fTimeWait/fTryWait
  ## followed by a fRelease.
  # runnableExamples:
  #   let lock = initWRFLock()

  #   assert lock.fAcquire() # Success

  #   assert not lock.fAcquire() # Fails
  var newData, data: uint32
  data = lock.loadState

  while true:
    if (data and frAcquireValueMask32) != 0u:
      return false # Overflow error
    newData = data or frAcquireValueMask32
    if (newData and nextStateReadFreeMask32) != 0u:
      newData = newData xor (nextStateReadFreeMask32 or currStateFreeMask32)
    if lock[stateOffset].addr.atomicCompareExchange(data.addr, newdata.addr, true, ATOMIC_RELAXED, ATOMIC_RELAXED):
      break
    
  result = true

# ============================================================================ #
# Define releases
# ============================================================================ #
proc wRelease*(lock: WRFLock): bool {.discardable.} =
  ## Releases write access to the WRFLock. Will return false if there isn't a registered
  ## write access.
  ## 
  ## This is a non blocking operation and must be coupled with a prior wAcquire.
  ## 
  ## Success of this operation will allow readers to proceed by returning rWait
  ## operations successfuly.
  # runnableExamples:
  #   let lock = initWRFLock()

  #   assert lock.wAcquire() # Success
  #   # Do a wWait here
  #   # Do writing work  here
  #   assert lock.wRelease() # Success

  #   assert not lock.wRelease() # Fails - has not acquired write access

  var newData, data: uint32
  data = lock.loadState

  while true:
    if (data and wrAcquireValueMask32) == 0u:
      return false # Overflow error
    newData = data and not(wrAcquireValueMask32 or currStateWriteMask32 or rdNxtLoopFlagMask32)
    if (newData and rdAcquireValueMask32) != 0u:
      newData = newData or currStateReadMask32
    elif (newData and frAcquireValueMask32) != 0u:
      newData = newData or currStateFreeMask32
    else:
      newData = newData or nextStateReadFreeMask32
    if lock[stateOffset].addr.atomicCompareExchange(data.addr, newdata.addr, true, ATOMIC_RELEASE, ATOMIC_RELAXED):
      break
  
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
  ## Releases read access to the WRFLock. Will return false if there isn't a registered
  ## read access.
  ## 
  ## This is a non blocking operation and must be coupled with a prior rAcquire to
  ## prevent overflow errors.
  ## 
  ## Success of this operation reduces the reader counter by 1. When all readers
  ## release their access, the thread with 'free' access will be allowed to continue
  ## via returning fWait operations successfully.
  # runnableExamples:
  #   let lock = initWRFLock()

  #   assert lock.rAcquire() # Success
  #   # Do a rWait here
  #   # Do reading work  here
  #   assert lock.rRelease() # Success

  var newData, data: uint
  data = lock.data.addr.atomicLoadN(ATOMIC_RELAXED)

  while true:
    if (data and rdAcquireCounterMask64) == 0u:
      return false # Overflow error
    newData = data - (1 shl rdAcquireCounterShift64)
    if (newData and rdAcquireCounterMask64) == 0u:
      newData = newData and not(rdAcquireValueMask64)
      if (newData and frAcquireValueMask64) != 0u:
        newData = newData xor (currStateReadMask64 or currStateFreeMask64)
      else:
        newData = newData xor (currStateReadMask64 or nextStateReadFreeMask64)
    if lock.data.addr.atomicCompareExchange(data.addr, newdata.addr, true, ATOMIC_RELEASE, ATOMIC_RELAXED):
      break
    
  if (
    ((newData and fWaitYieldMask64) == 0u) and
    ((newData and currStateFreeMask64) != 0u)
  ):
    wakeAll(lock[stateOffset].addr)
    
  result = true

proc fRelease*(lock: WRFLock): bool {.discardable.} =
  ## Releases free access to the WRFLock. Will return false if there isn't a registered
  ## free/deallocater access.
  ## 
  ## This is a non blocking operation and must be coupled with a prior fAcquire.
  ## 
  ## Success of this operation will allow writers to proceed by returning wWait
  ## operations successfuly.
  # runnableExamples:
  #   let lock = initWRFLock()

  #   assert lock.fAcquire() # Success
  #   # Do a fWait here
  #   # Do free/cleaning work  here
  #   assert lock.fRelease() # Success

  #   assert not lock.fRelease() # Fails - has not acquired free access

  var newData, data: uint32
  data = lock.loadState

  while true:
    if (data and frAcquireValueMask32) == 0u:
      return false # Overflow error
    newData = data and not(frAcquireValueMask32 or currStateFreeMask32)
    if (newData and wrAcquireValueMask32) != 0u:
      newData = newData or currStateWriteMask32
    else:
      newData = newData or nextStateWriteMask32
    if lock[stateOffset].addr.atomicCompareExchange(data.addr, newdata.addr, true, ATOMIC_RELEASE, ATOMIC_RELAXED):
      break
  
  if (
    ((newData and wWaitYieldMask32) == 0u) and
    ((newData and currStateWriteMask32) != 0u)
  ):
    wakeAll(lock[stateOffset].addr)
  
  result = true

# ============================================================================ #
# Define waits
# ============================================================================ #
proc wTimeWait*(lock: WRFLock, time: static int = 0): bool {.discardable.} =
  ## Waits for `time` in msecs (0 = infinite) for permission to execute its write
  ## operations. Returns false if it times out or otherwise errors (depending on OS).
  ## 
  ## NOTE: At most the true time waited may be up to double the passed time when
  ## blocking. This is not the same when schedule yielding.

  let stime = getTime()
  var data: uint32
  var dur: Duration
  when time > 0:
    dur = initDuration(milliseconds = time)

  while true:
    data = lock.loadState
    if (data and currStateWriteMask32) != 0u:
      atomicThreadFence(ATOMIC_ACQUIRE)
      result = true
      break
    if (data and wWaitYieldMask32) == 0u:
      if not wait(lock[stateOffset].addr, data, time):
        result = false
        break
    else:
      when time > 0:
        if getTime() > (stime + dur):
          result = false # timed out
          break
      cpuRelax()

proc rTimeWait*(lock: WRFLock, time: static int = 0): bool {.discardable.} =
  ## Waits for `time` in msecs (0 = infinite) for permission to execute its read
  ## operations. Returns false if it times out or otherwise errors (depending on OS).
  ## 
  ## NOTE: At most the true time waited may be up to double the passed time when
  ## blocking. This is not the same when schedule yielding.
  let stime = getTime()
  var data: uint32
  var dur: Duration
  when time > 0:
    dur = initDuration(milliseconds = time)
  while true:
    data = lock.loadState
    if (data and currStateReadMask32) != 0u:
      atomicThreadFence(ATOMIC_ACQUIRE)
      result = true
      break
    if (data and rWaitYieldMask32) == 0u:
      if not wait(lock[stateOffset].addr, data, time):
        result = false
        break
    else:
      when time > 0:
        if getTime() > (stime + dur):
          result = false # timed out
          break
      cpuRelax()

proc fTimeWait*(lock: WRFLock, time: static int = 0): bool {.discardable.} =
  ## Waits for `time` in msecs (0 = infinite) for permission to execute its free
  ## operations. Returns false if it times out or otherwise errors (depending on OS).
  ## 
  ## NOTE: At most the true time waited may be up to double the passed time when
  ## blocking. This is not the same when schedule yielding.

  let stime = getTime()
  var data: uint32
  var dur: Duration
  when time > 0:
    dur = initDuration(milliseconds = time)
  while true:
    data = lock.loadState
    if (data and currStateFreeMask32) != 0u:
      atomicThreadFence(ATOMIC_ACQUIRE)
      result = true
      break
    if (data and fWaitYieldMask32) == 0u:
      if not wait(lock[stateOffset].addr, data, time):
        result = false
        break
    else:
      when time > 0:
        if getTime() > (stime + dur):
          result = false # timed out
          break
      cpuRelax()
    
proc wWait*(lock: WRFLock): bool {.discardable.} =
  ## Alias for wTimeWait of infinite duration
  wTimeWait(lock, 0)
proc rWait*(lock: WRFLock): bool {.discardable.} =
  ## Alias  for rTimeWait of infinite duration
  rTimeWait(lock, 0)
proc fWait*(lock: WRFLock): bool {.discardable.} =
  ## Alias for fTimeWait of infinite duration
  fTimeWait(lock, 0)

proc wTryWait*(lock: WRFLock): bool {.discardable.} =
  ## Non blocking check to see if the thread can perform its write actions.
  let data = lock.loadState(ATOMIC_ACQUIRE)
  if (data and currStateWriteMask32) == 0u:
    result = false
  else:
    result = true

proc rTryWait*(lock: WRFLock): bool {.discardable.} =
  ## Non blocking check to see if the thread can perform its read actions.
  let data = lock.loadState(ATOMIC_ACQUIRE)
  if (data and currStateReadMask32) == 0u:
    result = false
  else:
    result = true
  
proc fTryWait*(lock: WRFLock): bool {.discardable.} =
  ## Non blocking check to see if the thread can perform its free/cleaning actions.
  let data = lock.loadState(ATOMIC_ACQUIRE)
  if (data and currStateFreeMask32) == 0u:
    result = false
  else:
    result = true

proc setFlags*(lock: WRFLock, flags: openArray[int]): bool {.discardable.} =
  ## EXPERIMENTAL - non blocking change of flags on a lock. Any change from
  ## a blocking wait to a schedule yield will result in all waiters being awoken.
  ## Operations that are blocking will return to sleep after checking their condition
  ## while the schedule yield operations will yield after checking their condition.
  var newData: uint32
  var data = lock.loadState
  var mustWake: bool

  while true:
    mustWake = false
    newData = data

    if wWaitYield in flags and (data and wWaitYieldMask32) == 0u:
      mustWake = true
      newData = newData or wWaitYieldMask32
    elif wWaitBlock in flags and (data and wWaitYieldMask32) != 0u:
      newData = newData xor wWaitYieldMask32

    if rWaitYield in flags and (data and rWaitYieldMask32) == 0u:
      mustWake = true
      newData = newData or rWaitYieldMask32
    elif rWaitBlock in flags and (data and rWaitYieldMask32) != 0u:
      newData = newData xor rWaitYieldMask32

    if fWaitYield in flags and (data and fWaitYieldMask32) == 0u:
      mustWake = true
      newData = newData or fWaitYieldMask32
    elif fWaitBlock in flags and (data and fWaitYieldMask32) != 0u:
      newData = newData xor fWaitYieldMask32
    if lock[stateOffset].addr.atomicCompareExchange(data.addr, newdata.addr, true, ATOMIC_RELEASE, ATOMIC_RELAXED):
      if mustWake:
        wakeAll(lock[stateOffset].addr)
      break
    else:
      data = lock.loadState
  result = true

type
  CurrState* = enum
    Uninit, Write, Read, Free

proc getCurrState*(lock: WRFLock): CurrState =
  ## For debugging purposes; checks what state the lock is currently in.
  ## 
  ## Returns Uninit if no valid state is found.
  let data = lock.loadState
  if (data and currStateReadMask32) != 0u:
    result = CurrState.Read
  elif (data and currStateWriteMask32) != 0u:
    result = CurrState.Write
  elif (data and currStateFreeMask32) != 0u:
    result = CurrState.Free
  else:
    result = CurrState.Uninit

template withWLock*(lock: WRFLock; body: untyped): untyped =
  ## Convenience template; raises OverFlow error if there is already a writer.
  ## 
  ## Blocks until the lock allows writing
  if not lock.wAcquire():
    raise newException(OverflowError, "Tried to acquire write status to a WRFLock that already has a writer")
  else:
    lock.wWait()
    body
    doAssert lock.wRelease(), "Releasing write status of the WRFLock was unsuccesful"
    
template withRLock*(lock: WRFLock; body: untyped): untyped =
  ## Convenience template; raises OverFlow error if there is already too many readers.
  ## 
  ## Blocks until the lock allows reading
  if not lock.rAcquire():
    raise newException(OverflowError, "Tried to acquire read status to a WRFLock that has no tokens remaining. Ensure you release reads with rRelease()")
  else:
    lock.rWait()
    body
    doAssert lock.rRelease(), "Releasing read status of the WRFLock was unsuccesful"

template withFLock*(lock: WRFLock; body: untyped): untyped =
  ## Convenience template; raises OverFlow error if there is already a free/deallocater.
  ## 
  ## Blocks until the lock allows free/deallocating
  if not lock.fAcquire():
    raise newException(OverflowError, "Tried to acquire free status to a WRFLock that already has a free/deallocator")
  else:
    lock.fWait()
    body
    doAssert lock.fRelease(), "Releasing free status of the WRFLock was unsuccesful"

template whileTryingWLock*(lock: WRFLock; body: untyped; succ: untyped): untyped =
  ## Convenience template; raises OverFlow error if there is already a writer.
  ## 
  ## Acquires write access, and then continuously evaluates `body` until the lock
  ## allows writing, at which time it performs `succ` before releasing write access.
  if not lock.wAcquire():
    raise newException(OverflowError, "Tried to acquire write status to a WRFLock that already has a writer")
  while not lock.wTryWait():
    body
  succ
  doAssert lock.wRelease(), "Releasing write status of the WRFLock was unsuccesful"
  
template whileTryingRLock*(lock: WRFLock; body: untyped; succ: untyped): untyped =
  ## Convenience template; raises OverFlow error if there is too many readers.
  ## 
  ## Acquires read access, and then continuously evaluates `body` until the lock
  ## allows reading, at which time it performs `succ` before releasing read access.
  if not lock.rAcquire():
    raise newException(OverflowError, "Tried to acquire read status to a WRFLock that has no tokens remaining. Ensure you release reads with rRelease()")
  while not lock.rTryWait():
    body
  succ
  doAssert lock.rRelease(), "Releasing read status of the WRFLock was unsuccesful"
  
template whileTryingFLock*(lock: WRFLock; body: untyped; succ: untyped): untyped =
  ## Convenience template; raises OverFlow error if there is already a free/deallocator.
  ## 
  ## Acquires free access, and then continuously evaluates `body` until the lock
  ## allows freeing, at which time it performs `succ` before releasing free access.
  if not lock.fAcquire():
    raise newException(OverflowError, "Tried to acquire free status to a WRFLock that already has a free/deallocator")
  while not lock.fTryWait():
    body
  succ
  doAssert lock.fRelease(), "Releasing free status of the WRFLock was unsuccesful"
  
    