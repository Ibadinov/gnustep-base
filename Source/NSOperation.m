/**Implementation for NSOperation for GNUStep
   Copyright (C) 2009,2010 Free Software Foundation, Inc.

   Written by:  Gregory Casamento <greg.casamento@gmail.com>
   Written by:  Richard Frith-Macdonald <rfm@gnu.org>
   Date: 2009,2010

   This file is part of the GNUstep Base Library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Library General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; if not, write to the Free
   Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
   Boston, MA 02111 USA.

   <title>NSOperation class reference</title>
   $Date: 2008-06-08 11:38:33 +0100 (Sun, 08 Jun 2008) $ $Revision: 26606 $
   */

#import "common.h"

#import "Foundation/NSLock.h"

#define	GS_NSOperation_IVARS \
  NSRecursiveLock *lock; \
  NSConditionLock *cond; \
  NSOperationQueuePriority priority; \
  double threadPriority; \
  BOOL cancelled; \
  BOOL concurrent; \
  BOOL executing; \
  BOOL finished; \
  BOOL blocked; \
  BOOL ready; \
  NSMutableArray *dependencies; \
  GSOperationCompletionBlock completionBlock;

#define	GS_NSOperationQueue_IVARS \
  NSRecursiveLock	*lock; \
  NSConditionLock	*cond; \
  NSMutableArray	*operations; \
  NSMutableArray	*waiting; \
  NSMutableArray	*starting; \
  NSString		*name; \
  BOOL			suspended; \
  NSInteger		executing; \
  NSInteger		threadCount; \
  NSInteger		count;

#import "Foundation/NSOperation.h"
#import "Foundation/NSArray.h"
#import "Foundation/NSAutoreleasePool.h"
#import "Foundation/NSDictionary.h"
#import "Foundation/NSEnumerator.h"
#import "Foundation/NSException.h"
#import "Foundation/NSKeyValueObserving.h"
#import "Foundation/NSThread.h"
#import "GSPrivate.h"
#import "GNUstepBase/NSObject+GNUstepBase.h"
#import "GNUstepBase/NSString+GNUstepBase.h"

#define	GSInternal	NSOperationInternal
#include	"GSInternal.h"
GS_PRIVATE_INTERNAL(NSOperation)

/* The pool of threads for 'non-concurrent' operations in a queue.
 */
#define	POOL	8

static NSArray *empty = nil;

static void GSAssertionFailure(id self, SEL _cmd, NSString *format, ...) NS_FORMAT_FUNCTION(3, 4);
static void GSAssertionFailure(id self, SEL _cmd, NSString *format, ...)
{
  va_list arguments;
  va_start(arguments, format);
  NSString *description = [NSString stringWithFormat:format arguments:arguments];
  va_end(arguments);

  char modifier = class_isMetaClass(object_getClass(self)) ? '+' : '-';
  [NSException raise:NSInvalidArgumentException format:@"*** %c[%@ %@]: %@", modifier, NSStringFromClass([self class]), NSStringFromSelector(_cmd), description];
}

#define GSParameterAssert(condition, format, ...)               \
do {                                                            \
    if (__builtin_expect(!(condition), NO)) {                   \
        GSAssertionFailure(self, _cmd, format, ##__VA_ARGS__);  \
    }                                                           \
} while(0)

@implementation NSOperation

+ (BOOL) automaticallyNotifiesObserversForKey: (NSString*)theKey
{
  return NO; /* Handle all KVO manually */
}

+ (void) initialize
{
    if (!empty) {
        empty = [NSObject leakRetained:[NSArray new]];
    }
}

- (void) addDependency: (NSOperation *)op
{
  GSParameterAssert(op != self, @"attempt to add dependency on self");
  GSParameterAssert([op isKindOfClass:[NSOperation class]], @"dependency is not an NSOperation");

  [self willChangeValueForKey:@"dependencies"];
  [self willChangeValueForKey:@"isReady"];

  [internal->lock lock];
  if (internal->dependencies == nil)
    {
      internal->dependencies = [[NSMutableArray alloc] initWithCapacity:5];
    }
  BOOL isNew = NSNotFound == [internal->dependencies indexOfObjectIdenticalTo:op];
  if (isNew)
    {
      [internal->dependencies addObject:op];
      internal->ready = NO;
    }
  [internal->lock unlock];

  if (isNew)
    {
      NSUInteger options = NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial;
      [op addObserver:self forKeyPath:@"isFinished" options:options context:NULL];
    }

  [self didChangeValueForKey:@"isReady"];
  [self didChangeValueForKey:@"dependencies"];
}

- (void) cancel
{
  [self willChangeValueForKey:@"isCancelled"];
  [internal->lock lock];
  internal->cancelled = YES;
  [internal->lock unlock];
  [self didChangeValueForKey:@"isCancelled"];

  [self willChangeValueForKey:@"isReady"];
  [internal->lock lock];
  internal->ready = YES;
  [internal->lock unlock];
  [self didChangeValueForKey:@"isReady"];
}

- (GSOperationCompletionBlock) completionBlock
{
  return internal->completionBlock;
}

- (void) dealloc
{
  if (internal != nil)
    {
      NSOperation	*op;

      while ((op = [internal->dependencies lastObject]) != nil)
	{
	  [self removeDependency: op];
	}
      RELEASE(internal->dependencies);
      RELEASE(internal->cond);
      RELEASE(internal->lock);
      GS_DESTROY_INTERNAL(NSOperation);
    }
  [super dealloc];
}

- (NSArray *) dependencies
{
  NSArray *dependencies;

  [internal->lock lock];
  if (internal->dependencies == nil)
    {
      dependencies = empty; /* OSX returns an empty array */
    }
  else
    {
      dependencies = [NSArray arrayWithArray:internal->dependencies];
    }
  [internal->lock unlock];
  return dependencies;
}

- (id) init
{
  if ((self = [super init]) != nil)
    {
      GS_CREATE_INTERNAL(NSOperation);
      internal->priority = NSOperationQueuePriorityNormal;
      internal->threadPriority = 0.5;
      internal->ready = YES;
      internal->lock = [NSRecursiveLock new];
    }
  return self;
}

- (BOOL) isCancelled
{
  [internal->lock lock];
  BOOL result = internal->cancelled;
  [internal->lock unlock];
  return result;
}

- (BOOL) isExecuting
{
  [internal->lock lock];
  BOOL result = internal->executing;
  [internal->lock unlock];
  return result;
}

- (BOOL) isFinished
{
  [internal->lock lock];
  BOOL result = internal->finished;
  [internal->lock unlock];
  return result;
}

- (BOOL) isConcurrent
{
  [internal->lock lock];
  BOOL result = internal->concurrent;
  [internal->lock unlock];
  return result;
}

- (BOOL) isReady
{
  [internal->lock lock];
  BOOL result = internal->ready;
  [internal->lock unlock];
  return result;
}

- (NSOperationQueuePriority) queuePriority
{
  [internal->lock lock];
  NSOperationQueuePriority result = internal->priority;
  [internal->lock unlock];
  return result;
}

- (double) threadPriority
{
  [internal->lock lock];
  double result = internal->threadPriority;
  [internal->lock unlock];
  return result;
}

- (void) main;
{
  return; /* OSX default implementation does nothing */
}

- (void) _checkIfReady
{
  /* Some dependency has finished (or been removed) ...
   * so we need to check to see if we are now ready unless we know we are.
   * This is protected by locks so that an update due to an observed
   * change in one thread won't interrupt anything in another thread.
   */
  [internal->lock lock];
  NSEnumerator *en = [internal->dependencies objectEnumerator];
  NSOperation	*op;
  while ((op = [en nextObject]) != nil)
    {
      if (NO == [op isFinished])
        {
          break;
        }
    }
  [internal->lock unlock];
  if (op == nil)
    {
      [self willChangeValueForKey: @"isReady"];
      [internal->lock lock];
      internal->ready = YES;
      [internal->lock unlock];
      [self didChangeValueForKey: @"isReady"];
    }
}

- (void) observeValueForKeyPath: (NSString *)keyPath
		       ofObject: (id)object
                         change: (NSDictionary *)change
                        context: (void *)context
{
  if ([[change objectForKey:NSKeyValueChangeNewKey] boolValue])
    {
      /* NSOperation observes isFinished key only */
      [object removeObserver:self forKeyPath:keyPath];

      if (object == self)
        {
          /*
           * We have finished and need to unlock the condition lock so that
           * any waiting thread can continue
           */
          [internal->cond lock];
          [internal->cond unlockWithCondition: 1];
        }
      else
        {
          [self _checkIfReady];
        }
    }
}

- (void) removeDependency: (NSOperation *)op
{
    [self willChangeValueForKey:@"dependencies"];
    
    [internal->lock lock];
    if (NSNotFound != [internal->dependencies indexOfObjectIdenticalTo:op])
    {
        [op removeObserver:self forKeyPath:@"isFinished"];
        [internal->dependencies removeObject:op];
    }
    [internal->lock unlock];
    [self _checkIfReady];
    
    [self didChangeValueForKey:@"dependencies"];
}

- (void) setCompletionBlock: (GSOperationCompletionBlock)aBlock
{
  [internal->lock lock];
  internal->completionBlock = aBlock;
  [internal->lock unlock];
}

- (void) setQueuePriority: (NSOperationQueuePriority)pri
{
  if (pri <= NSOperationQueuePriorityVeryLow)
    pri = NSOperationQueuePriorityVeryLow;
  else if (pri <= NSOperationQueuePriorityLow)
    pri = NSOperationQueuePriorityLow;
  else if (pri < NSOperationQueuePriorityHigh)
    pri = NSOperationQueuePriorityNormal;
  else if (pri < NSOperationQueuePriorityVeryHigh)
    pri = NSOperationQueuePriorityHigh;
  else
    pri = NSOperationQueuePriorityVeryHigh;

  [self willChangeValueForKey: @"queuePriority"];
  [internal->lock lock];
  internal->priority = pri;
  [internal->lock unlock];
  [self didChangeValueForKey: @"queuePriority"];
}

- (void) setThreadPriority: (double)pri
{
  pri = pri < 0 ? 0 : (pri > 1 ? 1 : pri);
  [internal->lock lock];
  internal->threadPriority = pri;
  [internal->lock unlock];
}

- (void) start
{
  NSAutoreleasePool *pool = [NSAutoreleasePool new];

  [internal->lock lock];
  NS_DURING
    {
      GSParameterAssert(![self isConcurrent], @"called on concurrent operation");
      GSParameterAssert(![self isExecuting], @"called on executing operation");
      GSParameterAssert(![self isFinished], @"called on executing operation");
      GSParameterAssert([self isReady], @"called on operation which is not ready");
    }
  NS_HANDLER
    {
      [internal->lock unlock];
      [localException retain];
      [pool release];
      [[localException autorelease] raise];
    }
  NS_ENDHANDLER
  [internal->lock unlock];

  double previousPriority = [NSThread threadPriority];

  NS_DURING
    {
      BOOL isCancelled = [self isCancelled];
      if (!isCancelled)
        {
          [self willChangeValueForKey: @"isExecuting"];
          [internal->lock lock];
          internal->executing = YES;
          [internal->lock unlock];
          [self didChangeValueForKey: @"isExecuting"];

          [NSThread setThreadPriority: internal->threadPriority];
          [self main];
        }

      /*
       * retain while finishing so that we don't get deallocated when our
       * queue removes and releases us.
       */
      [self retain];

      [self willChangeValueForKey: @"isFinished"];
      if (!isCancelled)
        {
          [self willChangeValueForKey: @"isExecuting"];
          [internal->lock lock];
          internal->executing = NO;
          internal->finished = YES;
          [internal->lock unlock];
          [self didChangeValueForKey: @"isExecuting"];
        }
      else
        {
          [internal->lock lock];
          internal->finished = YES;
          [internal->lock unlock];
        }
      [self didChangeValueForKey: @"isFinished"];

      [internal->lock lock];
      GSOperationCompletionBlock completionBlock = internal->completionBlock;
      [internal->lock unlock];
      if (NULL != completionBlock)
        {
          CALL_BLOCK_NO_ARGS(completionBlock);
        }

      [self release];
    }
  NS_HANDLER
    {
      [NSThread setThreadPriority: previousPriority];
      [localException retain];
      [pool release];
      [[localException autorelease] raise];
    }
  NS_ENDHANDLER;

  [NSThread setThreadPriority: previousPriority];
  [pool release];
}

- (void) waitUntilFinished
{
  [internal->lock lock];
  if (internal->cond == nil)
    {
      /* set up condition to wait on and observer to unblock */
      internal->cond = [[NSConditionLock alloc] initWithCondition: 0];
    }
  [internal->lock unlock];

  [self addObserver:self forKeyPath:@"isFinished" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial context:NULL];

  [internal->cond lockWhenCondition:1]; /* wait until finished */
  [internal->cond unlockWithCondition:1]; /* signal other threads */
}

@end


#undef	GSInternal
#define	GSInternal	NSOperationQueueInternal
#include	"GSInternal.h"
GS_PRIVATE_INTERNAL(NSOperationQueue)


@interface	NSOperationQueue (Private)
+ (void) _mainQueue;
- (void) _execute;
- (void) _thread;
- (void) observeValueForKeyPath: (NSString *)keyPath
		       ofObject: (id)object
                         change: (NSDictionary *)change
                        context: (void *)context;
@end

static NSInteger	maxConcurrent = 200;	// Thread pool size

static NSComparisonResult
sortFunc(id o1, id o2, void *ctxt)
{
  NSOperationQueuePriority p1 = [o1 queuePriority];
  NSOperationQueuePriority p2 = [o2 queuePriority];

  if (p1 < p2) return NSOrderedDescending;
  if (p1 > p2) return NSOrderedAscending;
  return NSOrderedSame;
}


static NSString	*threadKey = @"NSOperationQueue";
static NSOperationQueue *mainQueue = nil;


@implementation NSOperationQueue

+ (id) currentQueue
{
  return [[[NSThread currentThread] threadDictionary] objectForKey: threadKey];
}

+ (void) initialize
{
  if (mainQueue == nil)
    {
      [self performSelectorOnMainThread: @selector(_mainQueue)
			     withObject: nil
			  waitUntilDone: YES];
    }
}

+ (id) mainQueue
{
  return mainQueue;
}

- (void) addOperation: (NSOperation *)op
{
  GSParameterAssert([op isKindOfClass:[NSOperation class]], @"object is not an NSOperation");
  GSParameterAssert(![op isExecuting], @"operation is executing and cannot be enqueued");
  GSParameterAssert(![op isFinished], @"operation is finished and cannot be enqueued");

  [self willChangeValueForKey:@"operations"];
  [self willChangeValueForKey:@"operationCount"];

  [internal->lock lock];
  if (NSNotFound == [internal->operations indexOfObjectIdenticalTo:op])
    {
      [internal->operations addObject:op];
    }
  [internal->lock unlock];
  [op addObserver:self forKeyPath:@"isReady" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionInitial context:NULL];

  [self didChangeValueForKey:@"operationCount"];
  [self didChangeValueForKey:@"operations"];
}

- (void)addOperations:(NSArray *)operations waitUntilFinished:(BOOL)shouldWait
{
  GSParameterAssert([operations isKindOfClass:[NSArray class]], @"object is not an NSArray");

  NSUInteger count = [operations count];
  for (NSUInteger index = 0; index < count; ++index)
    {
      NSOperation *operation = [operations objectAtIndex:index];
      [self addOperation:operation];
    }

  if (shouldWait)
    {
      for (NSUInteger index = 0; index < count; ++index)
        {
          NSOperation *operation = [operations objectAtIndex:index];
          [operation waitUntilFinished];
        }
    }
}

- (void) cancelAllOperations
{
  [[self operations] makeObjectsPerformSelector: @selector(cancel)];
}

- (void) dealloc
{
  [internal->operations release];
  [internal->starting release];
  [internal->waiting release];
  [internal->name release];
  [internal->cond release];
  [internal->lock release];
  GS_DESTROY_INTERNAL(NSOperationQueue);
  [super dealloc];
}

- (id) init
{
  if ((self = [super init]) != nil)
    {
      GS_CREATE_INTERNAL(NSOperationQueue);
      internal->suspended = NO;
      internal->count = NSOperationQueueDefaultMaxConcurrentOperationCount;
      internal->operations = [NSMutableArray new];
      internal->starting = [NSMutableArray new];
      internal->waiting = [NSMutableArray new];
      internal->lock = [NSRecursiveLock new];
      internal->cond = [[NSConditionLock alloc] initWithCondition: 0];
    }
  return self;
}

- (BOOL) isSuspended
{
  [internal->lock lock];
  BOOL result = internal->suspended;
  [internal->lock unlock];
  return result;
}

- (NSInteger) maxConcurrentOperationCount
{
  [internal->lock lock];
  NSInteger result = internal->count;
  [internal->lock unlock];
  return result;
}

- (NSString*) name
{
  [internal->lock lock];
  if (internal->name == nil)
    {
      internal->name = [[NSString alloc] initWithFormat:@"NSOperation %p", self];
    }
  NSString *result = [internal->name retain];
  [internal->lock unlock];
  return [result autorelease];
}

- (NSUInteger) operationCount
{
  [internal->lock lock];
  NSUInteger result = [internal->operations count];
  [internal->lock unlock];
  return result;
}

- (NSArray *) operations
{
  [internal->lock lock];
  NSArray *result = [NSArray arrayWithArray:internal->operations];
  [internal->lock unlock];
  return result;
}

- (void) setMaxConcurrentOperationCount: (NSInteger)count
{
  GSParameterAssert(count >= 0 || count == NSOperationQueueDefaultMaxConcurrentOperationCount, @"cannot set negative (%ld) count", count);

  [self willChangeValueForKey:@"maxConcurrentOperationCount"];
  [internal->lock lock];
  internal->count = count;
  [internal->lock unlock];
  [self didChangeValueForKey:@"maxConcurrentOperationCount"];

  [self _execute];
}

- (void) setName: (NSString*)aName
{
  aName = aName ? aName : @"";

  [self willChangeValueForKey:@"name"];
  [internal->lock lock];
  if (NO == [internal->name isEqual:aName])
    {
      [internal->name release];
      internal->name = [aName copy];
    }
  [internal->lock unlock];
  [self didChangeValueForKey:@"name"];
}

- (void) setSuspended: (BOOL)suspend
{
  [self willChangeValueForKey:@"suspended"];
  [internal->lock lock];
  internal->suspended = suspend;
  [internal->lock unlock];
  [self didChangeValueForKey:@"suspended"];

  [self _execute];
}

- (void) waitUntilAllOperationsAreFinished
{
  NSOperation	*op;

  [internal->lock lock];
  while ((op = [internal->operations lastObject]) != nil)
    {
      [op retain];
      [internal->lock unlock];
      [op waitUntilFinished];
      [op release];
      [internal->lock lock];
    }
  [internal->lock unlock];
}
@end

@implementation	NSOperationQueue (Private)

+ (void) _mainQueue
{
  if (mainQueue == nil)
    {
      mainQueue = [self new];
      [[[NSThread currentThread] threadDictionary] setObject: mainQueue
						      forKey: threadKey];
    }
}

- (void) observeValueForKeyPath: (NSString *)keyPath
		       ofObject: (id)object
                         change: (NSDictionary *)change
                        context: (void *)context
{
  if (YES == [object isFinished])
    {
      [object removeObserver:self forKeyPath:@"isFinished"];
      [object removeObserver:self forKeyPath:@"isReady"];

      [self willChangeValueForKey:@"operations"];
      [self willChangeValueForKey:@"operationCount"];
      [internal->lock lock];
      internal->executing--;
      [internal->operations removeObjectIdenticalTo:object];
      [internal->lock unlock];
      [self didChangeValueForKey:@"operationCount"];
      [self didChangeValueForKey:@"operations"];
    }
  else
    {
        /* 
         * If we got up to this point, keyPath equals @"isReady", because
         * isFinished changes only one way (NO->YES). Now we should check if
         * this is actually the first change.
         */
        BOOL oldValue = [[change valueForKey:NSKeyValueChangeOldKey] boolValue];
        BOOL newValue = [[change valueForKey:NSKeyValueChangeNewKey] boolValue];
        if (newValue && !oldValue)
          {
            [internal->lock lock];
            [internal->waiting addObject:object];
            [internal->lock unlock];
          }
    }

  [self _execute];
}

- (void) _thread
{
  NSAutoreleasePool	*pool = [NSAutoreleasePool new];

  for (;;)
    {
      NSAutoreleasePool	*opPool = [NSAutoreleasePool new];
      NSOperation	*op;
      NSDate		*when;
      BOOL		found;

      when = [[NSDate alloc] initWithTimeIntervalSinceNow: 5.0];
      found = [internal->cond lockWhenCondition: 1 beforeDate: when];
      [when release];
      if (NO == found)
	{
          [opPool release];
	  break; /* idle for 5 seconds, exit thread */
	}

      if ([internal->starting count] > 0)
	{
          op = [internal->starting objectAtIndex: 0];
	  [internal->starting removeObjectAtIndex: 0];
	}
      else
	{
	  op = nil;
	}

      if ([internal->starting count] > 0)
	{
          /* signal any other idle threads */
          [internal->cond unlockWithCondition: 1];
	}
      else
	{
	  /* there are no more operations starting */
          [internal->cond unlockWithCondition: 0];
	}

      if (nil != op)
	{
          NS_DURING
	    {
              [op start];
	    }
          NS_HANDLER
	    {
	      NSLog(@"Problem running operation %@ ... %@", op, localException);
	    }
          NS_ENDHANDLER
	}
      [opPool release];
    }

  [internal->lock lock];
  internal->threadCount--;
  [internal->lock unlock];
  [pool release];
  [NSThread exit];
}

/* 
 * Checks for operations which can be executed and starts them
 */
- (void) _execute
{
  NSInteger max = [self maxConcurrentOperationCount];
  if (NSOperationQueueDefaultMaxConcurrentOperationCount == max)
    {
      max = maxConcurrent;
    }

  for (;;)
    {
      [internal->lock lock];
      if (internal->suspended || internal->executing >= max || ![internal->waiting count])
        {
          [internal->lock unlock];
          break;
        }
      NSOperation	*op;

      /* Make sure we have a sorted queue of operations waiting to execute.
       */
      [internal->waiting sortUsingFunction: sortFunc context: 0];

      /* Take the first operation from the queue and start it executing.
       * We set ourselves up as an observer for the operating finishing
       * and we keep track of the count of operations we have started,
       * but the actual startup is left to the NSOperation -start method.
       */
      op = [internal->waiting objectAtIndex: 0];
      [internal->waiting removeObjectAtIndex: 0];
      internal->executing++;

      [op addObserver: self
           forKeyPath: @"isFinished"
              options: NSKeyValueObservingOptionNew
              context: NULL];

      if (![op isConcurrent])
	{
          [internal->cond lock];
          NSUInteger pending = [internal->starting count];
          [internal->starting addObject: op];
            
          /*
           * Create a new thread if all existing threads are busy and
           * we haven't reached the pool limit.
           */
          if (!internal->threadCount || (pending > 0 && internal->threadCount < POOL))
	    {
                internal->threadCount++;
                [NSThread detachNewThreadSelector: @selector(_thread)
                                         toTarget: self
                                       withObject: nil];
	    }
          /* tell the thread pool that there is an operation to start */
          [internal->cond unlockWithCondition: 1];
          [internal->lock unlock];
	}
      else
	{
          [internal->lock unlock];
          [op start];
	}
    }
}

@end