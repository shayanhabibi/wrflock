const
  wWaitBlock* = 1
  wWaitYield* = 2
  rWaitBlock* = 4
  rWaitYield* = 8
  fWaitBlock* = 16
  fWaitYield* = 32

when cpuEndian == littleEndian:
  const
    countersOffset* = 0
    stateOffset* = 1
else:
  const
    countersOffset* = 1
    stateOffset* = 0

template makeFlags*(flags: typed, le: bool): untyped =
  when cpuEndian == littleEndian:
    if le:
      cast[uint](flags) shl 32u
    else:
      cast[uint](flags)
  else:
    if le:
      cast[uint](flags)
    else:
      cast[uint](flags) shl 32u

template makeShift*(shift: untyped, le: bool): untyped =
  when cpuEndian == littleEndian:
    if le:
      cast[uint](shift) + 32u
    else:
      cast[uint](shift)
  else:
    if le:
      cast[uint](shift)
    else:
      cast[uint](shift) + 32u

const
  privateMask32*: uint32 = 0x04000000
  privateMask64*: uint = makeFlags(privateMask32, false) or makeFlags(privateMask32, true)

  wWaitYieldMask32*: uint32 = 0x00010000
  wWaitYieldMask64*: uint = makeFlags(wWaitYieldMask32, true)

  rWaitYieldMask32*: uint32 = 0x00020000
  rWaitYieldMask64*: uint = makeFlags(rWaitYieldMask32, true)

  fWaitYieldMask32*: uint32 = 0x00040000
  fWaitYieldMask64*: uint = makeFlags(fWaitYieldMask32, true)

  wrAcquireValueShift32* = 28
  rdAcquireValueShift32* = 29
  frAcquireValueShift32* = 30
  rdAcquireCounterShift32* = 0

  wrAcquireValueShift64*: uint = makeShift(wrAcquireValueShift32, true)
  rdAcquireValueShift64*: uint = makeShift(rdAcquireValueShift32, true)
  frAcquireValueShift64*: uint = makeShift(frAcquireValueShift32, true)
  rdAcquireCounterShift64*: uint = makeShift(rdAcquireCounterShift32, false)

  wrAcquireValueMask32*: uint32 = 0x10000000
  rdAcquireValueMask32*: uint32 = 0x20000000
  frAcquireValueMask32*: uint32 = 0x40000000
  rdAcquireCounterMask32*: uint32 = 0x0000FFFF
  rdNxtLoopFlagMask32*: uint32 = 0x02000000

  wrAcquireValueMask64*: uint = makeFlags(wrAcquireValueMask32, true)
  rdAcquireValueMask64*: uint = makeFlags(rdAcquireValueMask32, true)
  frAcquireValueMask64*: uint = makeFlags(frAcquireValueMask32, true)
  rdAcquireCounterMask64*: uint = makeFlags(rdAcquireCounterMask32, false)
  rdNxtLoopFlagMask64*: uint = makeFlags(rdNxtLoopFlagMask32, true)

  nextStateWriteMask32*: uint32 = 0x00000010
  nextStateReadFreeMask32*: uint32 = 0x00000020
  nextStateValueMask32*: uint32 = nextStateWriteMask32 or nextStateReadFreeMask32 # or nextStateFreeMask32

  nextStateWriteMask64*: uint = makeFlags(nextStateWriteMask32, true)
  nextStateReadFreeMask64*: uint = makeFlags(nextStateReadFreeMask32, true)
  nextStateValueMask64*: uint = nextStateWriteMask64 or nextStateReadFreeMask64 # or nextStateFreeMask64

  currStateWriteMask32*: uint32 = 0x00000001
  currStateReadMask32*: uint32 = 0x00000002
  currStateFreeMask32*: uint32 = 0x00000004
  currStateValueMask32*: uint32 = currStateWriteMask32 or currStateReadMask32 or currStateFreeMask32

  currStateWriteMask64*: uint = makeFlags(currStateWriteMask32, true)
  currStateReadMask64*: uint = makeFlags(currStateReadMask32, true)
  currStateFreeMask64*: uint = makeFlags(currStateFreeMask32, true)
  currStateValueMask64*: uint = currStateWriteMask64 or currStateReadMask64 or currStateFreeMask64