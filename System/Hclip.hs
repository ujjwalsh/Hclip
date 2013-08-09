
{-# LANGUAGE CPP #-}

--------------------------------------------------------------------
-- |
-- Module : System.Hclip
-- Copyright : (c) Jens Thomas
-- License : BSD3
--
-- Maintainer: Jens Thomas <jetho@gmx.de>
-- Stability : experimental
-- Portability: 
--
-- A small cross-platform library for reading and modifying the 
-- system clipboard. 
-- 
--------------------------------------------------------------------

module System.Hclip (
        getClipboard, 
        setClipboard, 
        modifyClipboard,
        ClipboardError(..)
  ) where

import System.Process (runInteractiveCommand, readProcessWithExitCode) 
import System.Info (os)
import System.IO (Handle, hPutStr, hClose)
import Data.Monoid 
import Control.Exception (bracket, bracket_)
import System.IO.Strict (hGetContents) -- see http://hackage.haskell.org/package/strict
import System.Exit 
import Control.Monad.Error
import Data.List (intercalate, genericLength)

-- | for Windows support
#if defined(mingw32_HOST_OS) || defined(__MINGW32__)
import System.Win32.Mem (globalAlloc, globalLock, globalUnlock, copyMemory, gHND)
import Graphics.Win32.GDI.Clip (openClipboard, closeClipboard, emptyClipboard, getClipboardData, 
                                setClipboardData, ClipboardFormat, isClipboardFormatAvailable, cF_TEXT)
import Foreign.C (withCAString, peekCAString)
import Foreign.Ptr (castPtr, nullPtr)
#endif


-- | Clipboard Actions
data Command = GetClipboard 
             | SetClipboard String 


-- | Supported Operating Systems
data Platform = Linux
              | Darwin
              | Windows
                deriving (Show)


-- | Error Types
data ClipboardError = UnsupportedOS String
                    | NoTextualData
                    | MissingCommands [String]
                    | MiscError String
                      deriving (Eq)

instance Show ClipboardError where
  show (UnsupportedOS os) = "Unsupported Operating System: " ++ os
  show NoTextualData = "Clipboard doesn't contain textual data."
  show (MissingCommands cmds) = "Hclip requires " ++ apps ++ " installed."
    where apps = intercalate " or " cmds
  show (MiscError str) = str

instance Error ClipboardError where
  noMsg = MiscError "Unknown error"
  strMsg = MiscError


-- | Monad Transformer combining Error and IO
type ErrorWithIO = ErrorT ClipboardError IO


-- | Read clipboard contents.
getClipboard :: IO (Either ClipboardError String)
getClipboard = dispatchCommand GetClipboard


-- | Set clipboard contents.
setClipboard :: String -> IO (Either ClipboardError String)
setClipboard = dispatchCommand . SetClipboard


-- | Apply function to clipboard and return its new contents.
modifyClipboard :: (String -> String) -> IO (Either ClipboardError String)
modifyClipboard = flip (liftM . liftM) getClipboard >=> either (return . throwError) setClipboard


-- | Select the supported operating system.
dispatchCommand :: Command -> IO (Either ClipboardError String)
dispatchCommand = case os of
  "linux" -> clipboard Linux
  "darwin" -> clipboard Darwin
#if defined(mingw32_HOST_OS) || defined(__MINGW32__)
  "mingw32" -> clipboard Windows 
#endif
  unknownOS -> const $ return . throwError $ UnsupportedOS unknownOS


-- | MAC OS: use pbcopy and pbpaste    
clipboard Darwin command = Right `fmap` withExternalCommand extCmd command
  where extCmd = case command of
                   GetClipboard   -> "pbcopy"
                   SetClipboard _ -> "pbpaste"


-- | Linux: use xsel or xclip
clipboard Linux command = runErrorT $ do
  prog <- chooseFirstCommand ["xsel", "xclip"]
  liftIO $ withExternalCommand (decode prog command) command
  where
    decode "xsel" GetClipboard = "xsel -o"
    decode "xsel" (SetClipboard _) = "xsel -i"
    decode "xclip" GetClipboard = "xclip -selection c -o"
    decode "xclip" (SetClipboard _) = "xclip -selection c"
    

-- | Windows: use WinAPI
#if defined(mingw32_HOST_OS) || defined(__MINGW32__)
clipboard Windows GetClipboard = 
  bracket_ (openClipboard nullPtr) closeClipboard $ do
    isText <- isClipboardFormatAvailable cF_TEXT
    if isText
      then do 
        h <- getClipboardData cF_TEXT
        bracket (globalLock h) globalUnlock $ liftM Right . peekCAString . castPtr
      else return $ throwError NoTextualData

clipboard Windows (SetClipboard s) = 
  withCAString s $ \cstr -> do
    mem <- globalAlloc gHND memSize
    bracket (globalLock mem) globalUnlock $ \space -> do
      copyMemory space (castPtr cstr) memSize
      bracket_ (openClipboard nullPtr) closeClipboard $ do
        emptyClipboard
        setClipboardData cF_TEXT space
        return $ Right s
  where
    memSize = genericLength s + 1
#endif


-- | Run external command for accessing the system clipboard.
withExternalCommand :: String -> Command -> IO String
withExternalCommand prog command = 
  bracket (runInteractiveCommand prog)
          (\(inp, outp, stderr, _) -> mapM_ hClose [inp, outp, stderr])
          (\(inp, outp, _, _) -> action command (inp, outp))
  where
    action GetClipboard = hGetContents . stdout
    action (SetClipboard text) = (flip hPutStr text >=> const (return text)) . stdin
    stdin = fst
    stdout = snd


-- | Search for installed programs and return the first match.
chooseFirstCommand :: [String] -> ErrorWithIO String
chooseFirstCommand cmds = do
  results <- liftIO $ mapM whichCommand cmds
  maybe (throwError $ MissingCommands cmds)
        return
        (getFirst . mconcat $ map First results)


-- | Check if cmd is installed using the which command.
whichCommand :: String -> IO (Maybe String)
whichCommand cmd = do
  (exitCode,_,_) <- readProcessWithExitCode "which" [cmd] ""
  case exitCode of
    ExitSuccess -> return $ Just cmd
    ExitFailure _ -> return Nothing
