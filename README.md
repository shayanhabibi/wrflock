# WRFLock

> Pure nim implementation of the synchronisation object proposed by Mariusz Orlikowski in 'Single Producer - Multiple Consumers Ring Buffer Data Distribution System with Memory Management'

Implementation of a lock that allows multiple readers, one writer, and a special write state
for freeing. It is only 8 bytes large making it incredibly memory efficient.

Using futexes makes this primitive truly faster and more efficient than mutexes for its
use case.
