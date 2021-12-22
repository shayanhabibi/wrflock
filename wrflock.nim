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

  WaitType* = enum        ## Flags for setting the wait behaviour of WRFLock
    WriteBlock = wWaitBlock
    WriteYield = wWaitYield
    ReadBlock = rWaitBlock
    ReadYield = rWaitYield
    FreeBlock = fWaitBlock
    FreeYield = fWaitYield

  WRFLockOp* = enum
    Write, Read, Free

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
proc initWRFLock*(waitType: set[WaitType] = {}; pshared: bool = false): WRFLock =
  ## Initialise a WRFLock. pShared arg is nonfunctional at the moment.
  ## 
  ## Default operation for write, read and free waits are blocking. Pass WriteYield,
  ## ReadYield and/or FreeYield to waitType to change the operations to schedule yielding
  ## respectively.
  ## 
  ## Note: Yield flags take precedence over Block flags when there are conflicting
  ## flags in the waitType set
  result = createShared(WRFLockObj)

  if pshared:
    result.data = privateMask64 or nextStateWriteMask64
  else:
    result.data = 0u or nextStateWriteMask64
  
  if WriteYield in waitType:
    result.data = result.data or wWaitYieldMask64
  if ReadYield in waitType:
    result.data = result.data or rWaitYieldMask64
  if FreeYield in waitType:
    result.data = result.data or fWaitYieldMask64

proc freeWRFLock*(lock: WRFLock) =
  ## Deallocates a WRFLock.
  freeShared(lock)

# ============================================================================ #
# Define Acquires
# ============================================================================ #
template wAcquireImpl(lock: WRFLock): bool =  
  mixin loadState

  var res: bool
  var newData, data: uint32
  data = lock.loadState

  while true:
    if (data and wrAcquireValueMask32) != 0u:
      # Overflow error
      break
    newData = data or wrAcquireValueMask32
    if (newData and frAcquireValueMask32) != 0u:
      newData = newData or rdNxtLoopFlagMask32
    if (newData and nextStateWriteMask32) != 0u:
      newData = newData xor (nextStateWriteMask32 or currStateWriteMask32)
    if lock[stateOffset].addr.atomicCompareExchange(data.addr, newdata.addr, true, ATOMIC_RELAXED, ATOMIC_RELAXED):
      res = true
      break
  
  res

template rAcquireImpl(lock: WRFLock): bool =
  mixin loadState
  var res: bool
  var newData, data: uint32
  data = lock.loadState
  block acqloop:
    while (data and rdNxtLoopFlagMask32) != 0u:
      if (data and rWaitYieldMask32) != 0u:
        cpuRelax()
      else:
        wait(lock[stateOffset].addr, data)
      data = lock.loadState
    
    while true:
      if (data and rdAcquireCounterMask32) == rdAcquireCounterMask32:
        # Overflow error
        break acqloop
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
    res = true

  res

template fAcquireImpl(lock: WRFLock): bool =
  mixin loadState

  var res: bool
  var newData, data: uint32
  data = lock.loadState

  while true:
    if (data and frAcquireValueMask32) != 0u:
      # Overflow error
      break
    newData = data or frAcquireValueMask32
    if (newData and nextStateReadFreeMask32) != 0u:
      newData = newData xor (nextStateReadFreeMask32 or currStateFreeMask32)
    if lock[stateOffset].addr.atomicCompareExchange(data.addr, newdata.addr, true, ATOMIC_RELAXED, ATOMIC_RELAXED):
      res = true
      break

  res

proc wAcquire*(lock: WRFLock): bool {.discardable.} =
  ## Acquires write access to the WRFLock. Will return false if there is already
  ## a writer holding write access.
  ## 
  ## This is a non blocking operation and must be coupled with a successful wWait/wTimeWait/wTryWait
  ## followed by a wRelease.
  wAcquireImpl(lock)
proc rAcquire*(lock: WRFLock): bool {.discardable.} =
  ## Acquires read access to the WRFLock. Will return false if there are too many
  ## readers already holding access (65535 readers).
  ## 
  ## This is a non blocking operation and must be coupled with a successful rWait/rTimeWait/rTryWait
  ## followed by a rRelease.
  rAcquireImpl(lock)
proc fAcquire*(lock: WRFLock): bool {.discardable.} =
  ## Acquires free access to the WRFLock. Will return false if there is already a
  ## free/deallocater.
  ## 
  ## This is a non blocking operation and must be coupled with a successful fWait/fTimeWait/fTryWait
  ## followed by a fRelease.
  fAcquireImpl(lock)

proc acquire*(lock: WRFLock, op: static WRFLockOp): bool {.discardable.} =
  ## Acquires the specified access in `op` from the WRFLock.
  ## 
  ## acquire(lock, Read) is therefore the same as rAcquire(lock)
  ## acquire(lock, Write) is therefore the same as wAcquire(lock)
  ## acquire(lock, Free) is therefore the same as fAcquire(lock)
  when op == Write:
    wAcquireImpl(lock)
  elif op == Read:
    rAcquireImpl(lock)
  elif op == Free:
    fAcquireImpl(lock)

# ============================================================================ #
# Define releases
# ============================================================================ #
template wReleaseImpl(lock: WRFLock): bool =
  mixin loadState

  var res: bool
  var newData, data: uint32
  data = lock.loadState
  block impl:
    while true:
      if (data and wrAcquireValueMask32) == 0u:
        # Overflow error
        break impl
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
    res = true

  res

template rReleaseImpl(lock: WRFLock): bool =
  mixin loadState

  var res: bool
  var newData, data: uint
  data = lock.data.addr.atomicLoadN(ATOMIC_RELAXED)

  block impl:
    while true:
      if (data and rdAcquireCounterMask64) == 0u:
        # Overflow error
        break impl
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
    res = true
  
  res

template fReleaseImpl(lock: WRFLock): bool =
  mixin loadState

  var res: bool
  var newData, data: uint32
  data = lock.loadState

  block impl:
    while true:
      if (data and frAcquireValueMask32) == 0u:
        # Overflow error
        break impl
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
    res = true
  res

proc wRelease*(lock: WRFLock): bool {.discardable.} =
  ## Releases write access to the WRFLock. Will return false if there isn't a registered
  ## write access.
  ## 
  ## This is a non blocking operation and must be coupled with a prior wAcquire.
  ## 
  ## Success of this operation will allow readers to proceed by returning rWait
  ## operations successfuly.
  wReleaseImpl(lock)
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
  rReleaseImpl(lock)
proc fRelease*(lock: WRFLock): bool {.discardable.} =
  ## Releases free access to the WRFLock. Will return false if there isn't a registered
  ## free/deallocater access.
  ## 
  ## This is a non blocking operation and must be coupled with a prior fAcquire.
  ## 
  ## Success of this operation will allow writers to proceed by returning wWait
  ## operations successfuly.
  fReleaseImpl(lock)

proc release*(lock: WRFLock, op: static WRFLockOp): bool {.discardable.} =
  ## Releases the specified access in `op` from the WRFLock.
  ## 
  ## release(lock, Read) is therefore the same as rRelease(lock)
  ## release(lock, Write) is therefore the same as wRelease(lock)
  ## release(lock, Free) is therefore the same as fRelease(lock)
  when Write == op:
    wReleaseImpl(lock)
  elif Read == op:
    rReleaseImpl(lock)
  elif Free == op:
    fReleaseImpl(lock)
# ============================================================================ #
# Define waits
# ============================================================================ #

template waitImpl(lock: WRFLock, time: int, op: static WRFLockOp): bool =
  mixin loadState

  const currStateMask =
    case op
    of Write: currStateWriteMask32
    of Read: currStateReadMask32
    of Free: currStateFreeMask32
  const yieldMask =
    case op
    of Write: wWaitYieldMask32
    of Read: rWaitYieldMask32
    of Free: fWaitYieldMask32
    
  var res: bool
  let stime = getTime()
  var data: uint32
  var dur: Duration
  if time > 0:
    dur = initDuration(milliseconds = time)

  while true:
    data = lock.loadState
    if (data and currStateMask) != 0u:
      atomicThreadFence(ATOMIC_ACQUIRE)
      res = true
      break
    if (data and yieldMask) == 0u:
      if not wait(lock[stateOffset].addr, data, time):
        # timed out
        break
    else:
      if time > 0 and getTime() > (stime + dur):
        # timed out
        break
      cpuRelax()
  res
    
proc wWait*(lock: WRFLock; time: int = 0): bool =
  ## Waits for `time` in msecs (0 = infinite) for permission to execute its write
  ## operations. Returns false if it times out or otherwise errors (depending on OS).
  ## 
  ## NOTE: At most the true time waited may be up to double the passed time when
  ## blocking. This is not the same when schedule yielding.
  waitImpl(lock, time, WRFLockOp.Write)
proc rWait*(lock: WRFLock; time: int = 0): bool =
  ## Waits for `time` in msecs (0 = infinite) for permission to execute its read
  ## operations. Returns false if it times out or otherwise errors (depending on OS).
  ## 
  ## NOTE: At most the true time waited may be up to double the passed time when
  ## blocking. This is not the same when schedule yielding.
  waitImpl(lock, time, WRFLockOp.Read)
proc fWait*(lock: WRFLock; time: int = 0): bool =
  ## Waits for `time` in msecs (0 = infinite) for permission to execute its free
  ## operations. Returns false if it times out or otherwise errors (depending on OS).
  ## 
  ## NOTE: At most the true time waited may be up to double the passed time when
  ## blocking. This is not the same when schedule yielding.
  waitImpl(lock, time, WRFLockOp.Free)

proc wait*(lock: WRFLock; op: static WRFLockOp; time: int = 0): bool =
  waitImpl(lock, time, op)

template tryWaitImpl(lock: WRFLock, op: static WRFLockOp): bool =
  mixin loadState

  const currStateMask =
    case op
    of Write: currStateWriteMask32
    of Read: currStateReadMask32
    of Free: currStateFreeMask32
  
  let data = lock.loadState(ATOMIC_ACQUIRE)
  if (data and currStateMask) == 0u:
    false
  else:
    true

proc wTryWait*(lock: WRFLock): bool =
  ## Non blocking check to see if the thread can perform its write actions.
  tryWaitImpl(lock, WRFLockOp.Write)
proc rTryWait*(lock: WRFLock): bool =
  ## Non blocking check to see if the thread can perform its read actions.
  tryWaitImpl(lock, WRFLockOp.Read)
proc fTryWait*(lock: WRFLock): bool =
  ## Non blocking check to see if the thread can perform its free/cleaning actions.
  tryWaitImpl(lock, WRFLockOp.Free)

proc tryWait*(lock: WRFLock, op: static WRFLockOp): bool =
  tryWaitImpl(lock, op)

proc setFlags*(lock: WRFLock, flags: set[WaitType]) =
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

    if WriteYield in flags and (data and wWaitYieldMask32) == 0u:
      mustWake = true
      newData = newData or wWaitYieldMask32
    elif WriteBlock in flags and (data and wWaitYieldMask32) != 0u:
      newData = newData xor wWaitYieldMask32

    if ReadYield in flags and (data and rWaitYieldMask32) == 0u:
      mustWake = true
      newData = newData or rWaitYieldMask32
    elif ReadBlock in flags and (data and rWaitYieldMask32) != 0u:
      newData = newData xor rWaitYieldMask32

    if FreeYield in flags and (data and fWaitYieldMask32) == 0u:
      mustWake = true
      newData = newData or fWaitYieldMask32
    elif FreeBlock in flags and (data and fWaitYieldMask32) != 0u:
      newData = newData xor fWaitYieldMask32
    if lock[stateOffset].addr.atomicCompareExchange(data.addr, newdata.addr, true, ATOMIC_RELEASE, ATOMIC_RELAXED):
      if mustWake:
        wakeAll(lock[stateOffset].addr)
      break
    else:
      data = lock.loadState

proc getCurrState*(lock: WRFLock): WRFLockOp =
  ## For debugging purposes; checks what state the lock is currently in.
  ## 
  ## raises ValueError if no valid state is found.
  let data = lock.loadState
  if (data and currStateReadMask32) != 0u:
    result = WRFLockOp.Read
  elif (data and currStateWriteMask32) != 0u:
    result = WRFLockOp.Write
  elif (data and currStateFreeMask32) != 0u:
    result = WRFLockOp.Free
  else:
    raise newException(ValueError, "Tried to read the state of a uninitialised WRFLock")

template withLock*(lock: WRFLock; op: static WRFLockOp; body: untyped): untyped =
  ## Convenience template; raises OverFlow error if there is already too many accesses
  ## of the given op to the lock.
  ## 
  ## Blocks until the lock allows the given op to proceed
  if not acquire(lock, op):
    raise newException(OverflowError, "Failed to acquire " & $op & " status to a WRFLock")
  else:
    discard wait(lock, op)
    body
    doAssert release(lock, op), "Releasing " & $op & " status of the WRFLock was unsuccesful"
    
template whileTryingLock*(lock: WRFLock; op: static WRFLockOp; body: untyped; succ: untyped): untyped =
  ## Convenience template; raises OverFlow error if there is already too many accesses
  ## of the given op to the lock.
  ## 
  ## Acquires access, and then continuously evaluates `body` until the lock
  ## allows the given op, at which time it performs `succ` before releasing access.
  if not acquire(lock, op):
    raise newException(OverflowError, "Failed to acquire " & $op & " status to a WRFLock")
  while not tryWait(lock, op):
    body
  succ
  doAssert release(lock, op), "Releasing " & $op & " status of the WRFLock was unsuccesful"
      