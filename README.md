# WRFLock

> Pure nim implementation of the synchronisation object proposed by Mariusz Orlikowski in 'Single Producer - Multiple Consumers Ring Buffer Data Distribution System with Memory Management'

Implementation of a lock that allows multiple readers, one writer, and a special write state
for freeing. It is only 8 bytes large making it incredibly memory efficient.

Using futexes makes this primitive truly faster and more efficient than mutexes for its
use case.

## Principle

A thread will acquire the capability to perform an action (write, read, free)
and then **wait** for that action to be allowed. Once the thread has completed
its action, it then releases the capability which will then allow the following
action to be completed.

**Principally, the wrflock is a state machine.**

## Usage

> **Note: the api has not been finalised and is subject to change**

Example is for write, the same can be done for read and free by changing the
prefix letter.

```nim
let lock = initWRFLock()

if lock.wAcquire(): # all operations return bools; they are discardable if you
                    # know what you're doing.
  lock.wWait()
  # do write things here
  lock.wRelease()
```

By default, the Wait operations for all 3 actions (write, read, free) are blocking
using a futex. You can pass flags to change this to just have the thread yield
to the scheduler for any of the actions.

```nim
let lock = initWRFLock([wWaitYield, rWaitYield, fWaitYield])
```