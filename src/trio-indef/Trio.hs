{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}

module Trio
  ( withScope,
    joinScope,
    closeScope,
    async,
    async_,
    asyncMasked,
    asyncMasked_,
    await,
    cancel,
    Scope,
    Async,
    ChildDied (..),
    ScopeClosed (..),
  )
where

import Control.Exception (AsyncException (ThreadKilled), Exception (..), SomeException, asyncExceptionFromException, asyncExceptionToException)
import Control.Monad
import Data.Foldable
import Data.Set (Set)
import qualified Data.Set as Set
import Trio.Internal.Conc (blockUntilTVar, retryingUntilSuccess, pattern NotThreadKilled)
import Trio.Sig
import Prelude hiding (IO)

-- import Trio.Internal.Debug

data Scope = Scope
  { -- | Running children.
    runningVar :: TVar (Set ThreadId),
    -- | Number of children that are just about to start.
    startingVar :: TVar Int
  }

data ScopeClosed
  = ScopeClosed
  deriving stock (Show)
  deriving anyclass (Exception)

type Restore =
  forall x. IO x -> IO x

newScope :: IO (TMVar Scope)
newScope = do
  runningVar <- newTVarIO Set.empty
  startingVar <- newTVarIO 0
  newTMVarIO Scope {runningVar, startingVar}

withScope :: (TMVar Scope -> IO a) -> IO a
withScope f = do
  scopeVar <- newScope

  let action = do
        result <- f scopeVar
        atomically (joinScope scopeVar)
        pure result

  uninterruptibleMask \restore ->
    restore action `catch` \exception -> do
      closeWhileUninterruptiblyMasked scopeVar
      throwIO (translateAsyncChildDied exception)

joinScope :: TMVar Scope -> STM ()
joinScope scopeVar =
  tryTakeTMVar scopeVar >>= \case
    Nothing -> pure ()
    Just Scope {runningVar, startingVar} -> do
      blockUntilTVar runningVar Set.null
      blockUntilTVar startingVar (== 0)

closeScope :: TMVar Scope -> IO ()
closeScope scopeVar =
  uninterruptibleMask_ (closeWhileUninterruptiblyMasked scopeVar)

closeWhileUninterruptiblyMasked :: TMVar Scope -> IO ()
closeWhileUninterruptiblyMasked scopeVar =
  (join . atomically) do
    tryTakeTMVar scopeVar >>= \case
      Nothing -> pure (pure ())
      Just Scope {runningVar, startingVar} -> do
        blockUntilTVar startingVar (== 0)
        pure do
          children <- atomically (readTVar runningVar)
          for_ children \child ->
            -- Kill the child with asynchronous exceptions unmasked, because we
            -- don't want to deadlock with a child concurrently trying to throw
            -- an 'AsyncChildDied' back to us. But if any exceptions are thrown
            -- to us during this time, whether they are 'AsyncChildDied' or not,
            -- just ignore them. We already have an exception to throw, and we
            -- prefer it because it was delivered first.
            retryingUntilSuccess (unsafeUnmask (throwTo child ThreadKilled))

          atomically (blockUntilTVar runningVar Set.null)

data Async a = Async
  { threadId :: ThreadId,
    action :: STM (Either SomeException a)
  }

async :: TMVar Scope -> IO a -> IO (Async a)
async scope action =
  asyncMasked scope \unmask -> unmask action

async_ :: TMVar Scope -> IO a -> IO ()
async_ scope action =
  void (async scope action)

asyncMasked :: TMVar Scope -> (Restore -> IO a) -> IO (Async a)
asyncMasked scopeVar action = do
  resultVar <- atomically newEmptyTMVar

  uninterruptibleMask_ do
    Scope {runningVar, startingVar} <-
      atomically do
        tryReadTMVar scopeVar >>= \case
          Nothing -> throwSTM ScopeClosed
          Just scope -> do
            modifyTVar' (startingVar scope) (+ 1)
            pure scope

    parentThreadId <- myThreadId

    childThreadId <-
      forkIOWithUnmask \unmask -> do
        childThreadId <- myThreadId
        result <- try (action unmask)
        case result of
          Left (NotThreadKilled exception) ->
            throwTo parentThreadId (AsyncChildDied childThreadId exception)
          _ -> pure ()
        atomically do
          running <- readTVar runningVar
          if Set.member childThreadId running
            then do
              putTMVar resultVar result
              writeTVar runningVar $! Set.delete childThreadId running
            else retry

    atomically do
      modifyTVar' startingVar (subtract 1)
      modifyTVar' runningVar (Set.insert childThreadId)

    pure
      Async
        { threadId = childThreadId,
          action = readTMVar resultVar
        }

asyncMasked_ :: TMVar Scope -> ((forall x. IO x -> IO x) -> IO a) -> IO ()
asyncMasked_ scope action =
  void (asyncMasked scope action)

await :: Async a -> STM a
await Async {threadId, action} =
  action >>= \case
    Left exception -> throwSTM (ChildDied threadId exception)
    Right result -> pure result

cancel :: Async a -> IO ()
cancel Async {threadId, action} = do
  throwTo threadId ThreadKilled
  void (atomically action)

--------------------------------------------------------------------------------
-- ChildDied

data ChildDied = ChildDied
  { threadId :: ThreadId,
    exception :: SomeException
  }
  deriving stock (Show)
  deriving anyclass (Exception)

data AsyncChildDied = AsyncChildDied
  { threadId :: ThreadId,
    exception :: SomeException
  }
  deriving stock (Show)

instance Exception AsyncChildDied where
  fromException = asyncExceptionFromException
  toException = asyncExceptionToException

translateAsyncChildDied :: SomeException -> SomeException
translateAsyncChildDied ex =
  case fromException ex of
    Just AsyncChildDied {threadId, exception} ->
      toException ChildDied {threadId, exception}
    _ -> ex