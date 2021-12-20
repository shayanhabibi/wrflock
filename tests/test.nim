import std/osproc
import std/strutils
import std/logging
import std/atomics
import std/os
import std/macros

import balls

import wrflock

const threadCount = 6

addHandler newConsoleLogger()
setLogFilter:
  when defined(danger):
    lvlNotice
  elif defined(release):
    lvlInfo
  else:
    lvlDebug

var lock {.global.} = initWRFLock()
var counter {.global.}: Atomic[int]

proc writeLock() {.thread.} =
  sleep(1000)
  doassert lock.wAcquire()
  lock.wWait()
  discard counter.fetchAdd(1)
  doassert lock.wRelease()
    
proc readLock() {.thread.} =
  sleep(200)
  doassert lock.rAcquire()
  lock.rWait()
  doassert counter.load() == 1, "lock allowed read before it was written to"
  doassert lock.rRelease()

proc freeLock() {.thread.} =
  sleep(500)
  doassert lock.fAcquire()
  if not lock.fTimeWait(1_000):
    return
  counter.store(-10000)
  doassert lock.fRelease()

# try to delay a reasonable amount of time despite platform

template expectCounter(n: int): untyped =
  ## convenience
  try:
    check counter.load == n
  except Exception:
    checkpoint " counter: ", load counter
    checkpoint "expected: ", n
    raise

suite "wrflock":
  block:
    ## See if it works with blocking
    
    var threads: seq[Thread[void]]
    newSeq(threads, threadCount)

    counter.store 0

    var i: int
    for thread in threads.mitems:
      if i == 0:
        createThread(thread, writeLock)
      elif i == threadCount - 1:
        createThread(thread, freeLock)
      else:
        createThread(thread, readLock)
      inc i
    checkpoint "created $# threads" % [ $threadCount ]

    for thread in threads.mitems:
      joinThread thread
    checkpoint "joined $# threads" % [ $threadCount ]


    expectCounter -10000

  block:
    ## See if it works with yield
    lock.freeWRFLock()
    lock = initWRFLock([rWaitYield, fWaitYield, wWaitYield])
    
    var threads: seq[Thread[void]]
    newSeq(threads, threadCount)

    counter.store 0

    var i: int
    for thread in threads.mitems:
      if i == 0:
        createThread(thread, writeLock)
      elif i == threadCount - 1:
        createThread(thread, freeLock)
      else:
        createThread(thread, readLock)
      inc i
    checkpoint "created $# threads" % [ $threadCount ]

    for thread in threads.mitems:
      joinThread thread
    checkpoint "joined $# threads" % [ $threadCount ]


    expectCounter -10000