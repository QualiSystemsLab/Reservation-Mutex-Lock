# Reservation-Mutex-Lock

How to lock the reservation for exclusive use, even across drivers and execution servers.

In a nutshell:
Call AddServiceToReservation to add a dummy service with alias "MUTEX". You have obtained exclusive 
access to the reservation only if AddServiceToReservation succeeded. If it failed, 
sleep for a few seconds and try again in a loop. Delete the service to unlock.

This mechanism is currently being used by one specific driver to protect it from other instances of itself. 
Other drivers that adopt compatible locking code will be able to safely coexist with each other.

## Usage

The following code is just an example. The only requirements for this approach to work: 
- rely on the success or failure of AddServiceToReservation to control exclusive access
- use the service alias "MUTEX"

Steps:

1. Drag Mutex_Package.zip into the portal, or create a service model 'Mutex Service' 

1. Paste into your driver or script:

        from random import randint
        from time import sleep, time
        class Mutex(object):
            def __init__(self, api, resid, logger=None, mutex_name='MUTEX'):
                self.api = api
                self.resid = resid
                self.logger = logger
                self.mutex_name = mutex_name
    
            def __enter__(self):
                t0 = time()
                for _ in range(100):
                    try:
                        self.api.AddServiceToReservation(self.resid, 'Mutex Service', self.mutex_name, [])
                        if self.logger:
                            self.logger.info('Got mutex after %d seconds' % (time() - t0))
                        break
                    except Exception as e:
                        if self.logger:
                            self.logger.info('Failed to add mutex service: %s; sleeping 2-5 seconds' % str(e))
                        sleep(randint(2, 5))
                else:
                    if self.logger:
                        self.logger.info('Waited over 200 seconds without getting the mutex; continuing without it')
    
            def __exit__(self, exc_type, exc_val, exc_tb):
                if exc_type:
                    if self.logger:
                        self.logger.info('Releasing mutex, caught error %s %s %s' % (str(exc_type), str(exc_val), str(exc_tb)))
                else:
                    if self.logger:
                        self.logger.info('Releasing mutex')
                self.api.RemoveServicesFromReservation(self.resid, [self.mutex_name])

1. Wrap a 'with mutex' block around every section of code that reads or writes shared information about the reservation:

        with Mutex(api, resid, logger):
            # good idea to reread the reservation information now
            rd = api.GetReservationDetails(resid).ReservationDescription
            # do stuff, e.g. api.UpdateConnectorsInReservation(...)


Within the block you can assume you have exclusive access to the reservation, provided that other drivers
running in the reservation wrap their accesses in the same way.

To achieve safety with the bare minimum effort, you could simply move most of your code under a single 'with Mutex' 
block. But to improve parallelism, you could try to minimize the amount of code executed under 'with Mutex' blocks,
and perform time-consuming tasks outside 'with Mutex' if they don't read or write shared information in the reservation.


## How it works

### Cooperation among drivers

All parties that need safe locked access to the reservation must cooperate and access the reservation only after
obtaining exclusive access with the same mutex mechanism.

Nothing in the system stops an uncooperative party from ignoring the locks and directly accessing the reservation.

This mutex mechanism works only within the same reservation. You are only protected from other parties that use the same mutex name.
In most cases there should be a single mutex name for everyone accessing the reservation, so you could keep the default
name "MUTEX." 

In special situations you might set up multiple independent lock domains with multiple mutex names.

### Mechanism 
A Python lock won't work unless the two functions that need exclusive access are in the same driver instance.
Different driver instances are different Python processes. 

Something like a lock file on the filesystem would only work if there was only a single execution server in the system. If you had a shared network drive, it might  work.

The only universal central component in a CloudShell system with multiple execution servers is the CloudShell database. Accessing the database directly is too complicated and not directly supported. 

There is a way to use the standard CloudShell API, which manipulates the reservation contents in the database, to achieve exclusive access
across execution servers.


### Convenient behavior of AddServiceToReservation
The AddServiceToReservation API protects against adding two services to a reservation with the same name. It most likely has its own 
database-based locking internally.

If you call AddServiceToReservation and it succeeds, you can be sure that nobody else already added a service with the same name.
If someone tries to add the same thing a split second later, their attempt to add the same service name will fail, and they would wait a
few seconds and try again. Based on how reliably the error "CloudShell API error 100: Service with given alias already exists" has been seen, 
we assume that such locking exists in the product.  


Note that Mutex Service itself has no functionality. It is just an arbitrary object to add to the reservation and
exploit the potential of the AddServiceToReservation API as a locking mechanism.



## Why locking is needed

Your driver might change shared components in a reservation, especially connectors, that 
could also be touched by other drivers.
Someone else's driver, or even a second instance of your own driver, could try to simultaneously change 
the reservation and cause random failures and incorrect results in one or both drivers.

This kind of situation can easily deceive you into thinking everything is working, only to randomly fail on a later run.
Connector bugs are especially prone to these errors, and they are painful to debug because they can involve waiting for 
multiple components in a system to be created. 

In the past there have been bugs in the product involving failures of individual API calls that tried to simultaneously modify the
reservation, but those have been fixed by adding more locks in the product. 
If there are future bugs like that, they can also be fixed. But it's outside the scope of the product
to guard against problems caused by a series of legal API calls that each work 
as specified but are not atomic as a group.

Suppose you have two resources with a visual connector in a reservation:

    A -- B

Driver X wants to replace A with A2 and recreate A's connectors on A2. 
Simultaneously Driver Y wants to do the same, replace B with B2 and move B's connectors to B2.

Ideally, the sequence of events would be:

    Driver X: Create A2
    Driver X: Get connectors of A: A--B
    Driver X: Delete A
    Driver X: Create connector A2--B

    Driver Y: Create B2
    Driver Y: Get connectors of B: A2--B
    Driver Y: Delete B
    Driver Y: Create connector A2--B2

Both would succeed and in the reservation you would have:

    A2 -- B2

But nothing prevents the following timeline:

    Driver X                               Driver Y
    -------------------------------------------------------------------------------
    Create A2
                                           Create B2
    Get connectors of A: A--B
                                           Get connectors of B: A--B
    Delete A
                                           Delete B
    Create connector A2--B
    (ERROR: B NOT FOUND)
                                           Create connector A--B2
                                           (ERROR: A NOT FOUND)


This is only one possible interleaving of events. One, both, or neither driver might 
receive outdated information and/or do something that fails. 
To make matters worse, errors might happen where you least expect them and 
the messages could be confusing, or worse, completely hidden. 
Your system would appear to randomly fail. It might work only on your test 
machine and fail on the customer's, and stop failing when you try to debug it with fewer components.


To guarantee correctness, we need a way for each driver to lock the reservation:

    Driver X                               Driver Y

    Create A2
                                           Create B2
    Lock reservation for X
    |
    |Get connectors of A: A--B
    |                                      Lock reservation for Y (MUST WAIT)
    |                                      Wait...
    |                                          .
    |Delete A                                  .
    |                                          .
    |Create connector A2--B                    .
    |                                          .
    Unlock reservation                         .
                                           Finished waiting for lock
                                           Reservation now locked for Y
                                           |
                                           |Get connectors of B: A2--B
                                           |
                                           |Delete B
                                           |
                                           |Create connector A2--B2
                                           |
                                           |Unlock reservation




