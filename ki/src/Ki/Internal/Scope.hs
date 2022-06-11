module Ki.Internal.Scope
  ( Scope,
    scoped,
    wait,
    fork,
    forkWith,
    forkWith_,
    fork_,
    forkTry,
    forkTryWith,
  )
where

import Control.Exception
  ( Exception (fromException, toException),
    MaskingState (..),
    SomeAsyncException,
    asyncExceptionFromException,
    asyncExceptionToException,
    catch,
    getMaskingState,
    pattern ErrorCall,
  )
import qualified Data.IntMap.Lazy as IntMap
import Data.Void (Void)
import GHC.Conc
  ( STM,
    TVar,
    atomically,
    enableAllocationLimit,
    labelThread,
    newTVarIO,
    readTVar,
    retry,
    setAllocationCounter,
    throwSTM,
    writeTVar,
  )
import GHC.IO (unsafeUnmask)
import Ki.Internal.ByteCount
import Ki.Internal.Counter
import Ki.Internal.Prelude
import Ki.Internal.Thread

-- | A thread scope.
--
-- ==== __👉 Details__
--
-- * A child thread cannot outlive the scope in which it was created.
--
--     * Just before a call to 'scoped' returns, the parent thread raises an exception in all living child threads
--     created within the scope, then blocks until they terminate.
--
-- * The thread that creates a scope is considered the parent of all threads that are created within it.
--
-- * Child threads created within a scope can be awaited individually (see 'await'), or as a collection (see 'wait').
data Scope = Scope
  { -- The MVar that a child puts to before propagating the exception to the parent because the delivery is not
    -- guaranteed. This is because the parent must kill its children with asynchronous exceptions uninterruptibly masked
    -- for correctness.
    childExceptionVar :: {-# UNPACK #-} !(MVar SomeException),
    -- The set of child threads that are currently running, each keyed by a monotonically increasing int.
    childrenVar :: {-# UNPACK #-} !(TVar (IntMap ThreadId)),
    -- The counter that holds the (int) key to use for the next child thread.
    nextChildIdCounter :: {-# UNPACK #-} !Counter,
    -- The number of child threads that are guaranteed to be about to start, in the sense that only the GHC scheduler
    -- can continue to delay; no async exception can strike here and prevent one of these threads from starting.
    --
    -- Sentinel value: -1 means the scope is closed.
    startingVar :: {-# UNPACK #-} !(TVar Int),
    -- The id of the thread that created the scope.
    threadId :: {-# UNPACK #-} !ThreadId
  }

-- Exception thrown by a parent thread to its children when its scope is closing.
data ScopeClosing
  = ScopeClosing

instance Show ScopeClosing where
  show _ = "ScopeClosing"

instance Exception ScopeClosing where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

-- Trust without verifying that any 'ScopeClosed' exception, which is not exported by this module, was indeed thrown to
-- a thread by this library, and not randomly caught by a user and propagated to some thread.
isScopeClosingException :: SomeException -> Bool
isScopeClosingException exception =
  case fromException exception of
    Just ScopeClosing -> True
    _ -> False

pattern IsScopeClosingException :: SomeException
pattern IsScopeClosingException <- (isScopeClosingException -> True)

-- | Execute an action in a new scope.
--
-- ==== Structured concurrency
--
-- Just before the action returns, whether with a value or an exception:
--
-- * The parent thread raises an exception in all living child threads that were created within the scope.
-- * The parent thread blocks until those threads terminate.
--
-- A child thread therefore cannot outlive its parent, nor the scope in which it was created.
--
-- ==== Exception propagation
--
-- * If an exception is raised in a child thread, the child thread propagates the exception to its parent.
-- * If an exception is raised in a parent thread, the parent thread raises an exception in all of its children.
scoped ::
  -- |
  (Scope -> IO a) ->
  IO a
scoped action = do
  childExceptionVar <- newEmptyMVar
  childrenVar <- newTVarIO IntMap.empty
  nextChildIdCounter <- newCounter
  startingVar <- newTVarIO 0
  threadId <- myThreadId
  let scope = Scope {childExceptionVar, childrenVar, nextChildIdCounter, startingVar, threadId}

  uninterruptibleMask \restore -> do
    result <- try (restore (action scope))

    children <-
      atomically do
        -- Block until we haven't committed to starting any threads. Without this, we may create a thread concurrently
        -- with closing its scope, and not grab its thread id to throw an exception to.
        blockUntil0 startingVar
        -- Write the sentinel value indicating that this scope is closed, and it is an error to try to create a thread
        -- within it.
        writeTVar startingVar (-1)
        -- Return the list of currently-running children to kill. Some of them may have *just* started (e.g. if we
        -- initially retried in `blockUntil0` above). That's fine - kill them all!
        readTVar childrenVar

    -- Deliver an async exception to every child in the order they were created.
    -- FIXME I think we decided this feature isn't very useful in practice, so maybe we should simplify the internals
    -- and just keep a set of children.
    traverse_ (flip throwTo ScopeClosing) (IntMap.elems children)

    -- Block until all children have terminated; this relies on children respecting the async exception, which they
    -- must, for correctness. Otherwise, a thread could indeed outlive the scope in which it's created, which is
    -- definitely not structured concurrency!
    atomically (blockUntilEmpty childrenVar)

    -- By now there are three sources of exception:
    --
    --   1) A sync or async exception thrown during the callback, captured in `result`. If applicable, we want to unwrap
    --      the `ThreadFailed` off of this, which was only used to indicate it came from one of our children.
    --   2) A sync or async exception left for us in `childExceptionVar` by a child that tried to propagate it to us
    --      directly, but failed (because we killed it concurrently).
    --   3) An async exception waiting in our exception queue, because we still have async exceptions uninterruptibly
    --      masked.
    --
    -- We cannot throw more than one, so throw them in that priority order.
    case result of
      Left exception -> throwIO (unwrapThreadFailed exception)
      Right value ->
        tryTakeMVar childExceptionVar >>= \case
          Nothing -> pure value
          Just exception -> throwIO exception

-- Spawn a thread in a scope, providing it a function that sets the masking state to the requested masking state. The
-- given action is called with async exceptions at least interruptibly masked, but maybe uninterruptibly, if spawn
-- itself was called with async exceptions uninterruptible masked. The given action must not throw an exception.
spawn :: Scope -> ThreadOptions -> ((forall x. IO x -> IO x) -> IO ()) -> IO ThreadId
spawn
  Scope {childrenVar, nextChildIdCounter, startingVar}
  ThreadOptions {affinity, allocationLimit, label, maskingState = requestedChildMaskingState}
  action = do
    parentMaskingState <- getMaskingState

    let atLeastInterruptiblyMasked :: IO a -> IO a
        atLeastInterruptiblyMasked =
          case parentMaskingState of
            Unmasked -> interruptiblyMasked
            MaskedInterruptible -> id
            MaskedUninterruptible -> id

    -- Interruptible mask is enough so long as none of the STM operations below block
    atLeastInterruptiblyMasked do
      -- Record the thread as being about to start.
      atomically do
        n <- readTVar startingVar
        if n < 0
          then throwSTM (ErrorCall "ki: scope closed")
          else writeTVar startingVar $! n + 1

      childId <- incrCounter nextChildIdCounter

      childThreadId <-
        forkWithAffinity affinity do
          when (not (null label)) do
            childThreadId <- myThreadId
            labelThread childThreadId label

          case allocationLimit of
            Nothing -> pure ()
            Just bytes -> do
              setAllocationCounter (byteCountToInt64 bytes)
              enableAllocationLimit

          let -- Action that sets the masking state from the current (either MaskedInterruptible or
              -- MaskedUninterruptible) to the requested masking state
              masking :: IO a -> IO a
              masking =
                case requestedChildMaskingState of
                  Unmasked -> unsafeUnmask
                  MaskedInterruptible ->
                    case parentMaskingState of
                      Unmasked -> id
                      MaskedInterruptible -> id
                      MaskedUninterruptible -> interruptiblyMasked -- downgrade
                  MaskedUninterruptible ->
                    case parentMaskingState of
                      Unmasked -> uninterruptiblyMasked
                      MaskedInterruptible -> uninterruptiblyMasked
                      MaskedUninterruptible -> id

          action masking

          atomically (unrecordChild childrenVar childId)

      -- Record the child as having started
      atomically do
        n <- readTVar startingVar
        writeTVar startingVar $! n -1 -- it's actually ok to go from e.g. -1 to -2 here (very unlikely)
        recordChild childrenVar childId childThreadId

      pure childThreadId

-- Record our child by either:
--
--   * Flipping `Nothing` to `Just childThreadId` (common case: we record child before it unrecords itself)
--   * Flipping `Just _` to `Nothing` (uncommon case: we observe that a child already unrecorded itself)
--
-- Never retries.
recordChild :: TVar (IntMap ThreadId) -> Int -> ThreadId -> STM ()
recordChild childrenVar childId childThreadId = do
  children <- readTVar childrenVar
  writeTVar childrenVar $! IntMap.alter (maybe (Just childThreadId) (const Nothing)) childId children

-- Unrecord a child (ourselves) by either:
--
--   * Flipping `Just childThreadId` to `Nothing` (common case: parent recorded us first)
--   * Flipping `Nothing` to `Just undefined` (uncommon case: we die and unrecord before parent can record us).
--
-- Never retries.
unrecordChild :: TVar (IntMap ThreadId) -> Int -> STM ()
unrecordChild childrenVar childId = do
  children <- readTVar childrenVar
  writeTVar childrenVar $! IntMap.alter (maybe (Just undefined) (const Nothing)) childId children

-- forkIO/forkOn/forkOS, switching on affinity
forkWithAffinity :: ThreadAffinity -> IO () -> IO ThreadId
forkWithAffinity = \case
  Unbound -> forkIO
  Capability n -> forkOn n
  OsThread -> forkOS

-- | Wait until all threads created within a scope terminate.
wait ::
  -- |
  Scope ->
  STM ()
wait Scope {childrenVar, startingVar} = do
  blockUntilEmpty childrenVar
  blockUntil0 startingVar

-- Block until an IntMap becomes empty.
blockUntilEmpty :: TVar (IntMap a) -> STM ()
blockUntilEmpty var = do
  x <- readTVar var
  if IntMap.null x then pure () else retry

-- Block until a TVar becomes 0.
blockUntil0 :: TVar Int -> STM ()
blockUntil0 var = do
  x <- readTVar var
  if x == 0 then pure () else retry

-- | Create a child thread to execute an action within a scope.
--
-- ==== Masking state
--
-- The child thread does not mask asynchronous exceptions, regardless of the parent thread's masking state.
--
-- To create a child thread with a different initial masking state, use 'Ki.forkWith'.
fork ::
  -- |
  Scope ->
  -- |
  IO a ->
  IO (Thread a)
fork scope =
  forkWith scope defaultThreadOptions

-- | Variant of 'Ki.fork' for threads that never return.
fork_ ::
  -- |
  Scope ->
  -- |
  IO Void ->
  IO ()
fork_ scope =
  forkWith_ scope defaultThreadOptions

-- | Variant of 'Ki.fork' that takes an additional options argument.
forkWith ::
  -- |
  Scope ->
  -- |
  ThreadOptions ->
  -- |
  IO a ->
  IO (Thread a)
forkWith scope@Scope {threadId = parentThreadId} opts action = do
  resultVar <- newTVarIO Nothing
  ident <-
    spawn scope opts \masking -> do
      result <- try (masking action)
      case result of
        Left exception ->
          when
            (not (isScopeClosingException exception))
            (propagateException parentThreadId exception (childExceptionVar scope))
        Right _ -> pure ()
      -- even put async exceptions that we propagated. this isn't totally ideal because a caller awaiting this thread
      -- would not be able to distinguish between async exceptions delivered to this thread, or itself
      atomically (writeTVar resultVar (Just result))
  let doAwait =
        readTVar resultVar >>= \case
          Nothing -> retry
          Just (Left exception) -> throwSTM exception
          Just (Right value) -> pure value
  pure (makeThread ident doAwait)

-- | Variant of 'Ki.forkWith' for threads that never return.
forkWith_ ::
  -- |
  Scope ->
  -- |
  ThreadOptions ->
  -- |
  IO Void ->
  IO ()
forkWith_ scope@Scope {threadId = parentThreadId} opts action = do
  _childThreadId <-
    spawn scope opts \masking ->
      tryEither
        ( \exception ->
            when
              (not (isScopeClosingException exception))
              (propagateException parentThreadId exception (childExceptionVar scope))
        )
        (\_unit -> pure ())
        (masking action)
  pure ()

-- | Like 'Ki.fork', but the child thread does not propagate exceptions that both:
--
-- * Synchronous.
-- * An an instance of __@e@__.
forkTry ::
  Exception e =>
  -- |
  Scope ->
  -- |
  IO a ->
  -- |
  IO (Thread (Either e a))
forkTry scope =
  forkTryWith scope defaultThreadOptions

-- | Variant of 'Ki.forkTry' that takes an additional options argument.
forkTryWith ::
  Exception e =>
  -- |
  Scope ->
  -- |
  ThreadOptions ->
  -- |
  IO a ->
  IO (Thread (Either e a))
forkTryWith = forkTryWith' -- cleaner haddocks :/

forkTryWith' :: forall e a. Exception e => Scope -> ThreadOptions -> IO a -> IO (Thread (Either e a))
forkTryWith' scope@Scope {threadId = parentThreadId} opts action = do
  resultVar <- newTVarIO Nothing
  childThreadId <-
    spawn scope opts \masking -> do
      result <- try (masking action)
      case result of
        Left exception -> do
          let shouldPropagate =
                case fromException @e exception of
                  Nothing -> not (isScopeClosingException exception)
                  -- if the user calls `forkTry @MyAsyncException`, we still want to propagate the async exception
                  Just _ -> not (isScopeClosingException exception) && isAsyncException exception
          when shouldPropagate (propagateException parentThreadId exception (childExceptionVar scope))
        Right _value -> pure ()
      atomically (writeTVar resultVar (Just result))
  let doAwait =
        readTVar resultVar >>= \case
          Nothing -> retry
          Just (Left exception) ->
            case fromException @e exception of
              Nothing -> throwSTM exception
              Just exception' -> pure (Left exception')
          Just (Right value) -> pure (Right value)
  pure (makeThread childThreadId doAwait)
  where
    isAsyncException :: SomeException -> Bool
    isAsyncException exception =
      case fromException @SomeAsyncException exception of
        Nothing -> False
        Just _ -> True

-- TODO more docs
-- No precondition on masking state
propagateException :: ThreadId -> SomeException -> MVar SomeException -> IO ()
propagateException parentThreadId exception childExceptionVar =
  -- `throwTo` cannot be called with async exceptions uninterruptibly masked, because that may deadlock with our parent
  -- throwing to us
  interruptiblyMasked do
    fix \again ->
      try (throwTo parentThreadId (ThreadFailed exception)) >>= \case
        Left IsScopeClosingException -> void (tryPutMVar childExceptionVar exception)
        -- while blocking on notifying the parent of this exception, we got hit by a random async exception from
        -- elsewhere. that's weird and unexpected, but we already have an exception to deliver, so it just gets tossed
        -- to the void...
        Left _ -> again
        Right _ -> pure ()

-- Like try, but with continuations
tryEither :: Exception e => (e -> IO b) -> (a -> IO b) -> IO a -> IO b
tryEither onFailure onSuccess action =
  join (catch (onSuccess <$> action) (pure . onFailure))
