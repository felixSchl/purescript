{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DoAndIfThenElse #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Main (main) where

import           Prelude ()
import           Prelude.Compat

import           Data.Monoid ((<>))
import           Data.String (IsString(..))
import           Data.Traversable (for)
import           Data.Version (showVersion)

import           Control.Applicative (many)
import           Control.Concurrent (forkIO)
import           Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import           Control.Monad
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Except (ExceptT(..), runExceptT)
import           Control.Monad.Trans.State.Strict (StateT, evalStateT)
import           Control.Monad.Trans.Reader (ReaderT, runReaderT)

import qualified Language.PureScript as P
import qualified Language.PureScript.Bundle as Bundle
import           Language.PureScript.Interactive

import           Network.HTTP.Types.Header (hContentType)
import           Network.HTTP.Types.Status (status200, status404)
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import qualified Network.Wai.Handler.WebSockets as WS
import qualified Network.WebSockets as WS

import qualified Options.Applicative as Opts

import qualified Paths_purescript as Paths

import           System.Console.Haskeline
import           System.IO.UTF8 (readUTF8File)
import           System.Exit
import           System.FilePath ((</>))
import           System.FilePath.Glob (glob)

-- | Command line options
data PSCiOptions = PSCiOptions
  { psciMultiLineMode     :: Bool
  , psciInputFile         :: [FilePath]
  , psciInputNodeFlags    :: [String]
  }

multiLineMode :: Opts.Parser Bool
multiLineMode = Opts.switch $
     Opts.long "multi-line-mode"
  <> Opts.short 'm'
  <> Opts.help "Run in multi-line mode (use ^D to terminate commands)"

inputFile :: Opts.Parser FilePath
inputFile = Opts.strArgument $
     Opts.metavar "FILE"
  <> Opts.help "Optional .purs files to load on start"

nodeFlagsFlag :: Opts.Parser [String]
nodeFlagsFlag = Opts.option parser $
     Opts.long "node-opts"
  <> Opts.metavar "NODE_OPTS"
  <> Opts.value []
  <> Opts.help "Flags to pass to node, separated by spaces"
  where
    parser = words <$> Opts.str

psciOptions :: Opts.Parser PSCiOptions
psciOptions = PSCiOptions <$> multiLineMode
                          <*> many inputFile
                          <*> nodeFlagsFlag

version :: Opts.Parser (a -> a)
version = Opts.abortOption (Opts.InfoMsg (showVersion Paths.version)) $
            Opts.long "version" <>
            Opts.help "Show the version number" <>
            Opts.hidden

getOpt :: IO PSCiOptions
getOpt = Opts.execParser opts
    where
      opts        = Opts.info (version <*> Opts.helper <*> psciOptions) infoModList
      infoModList = Opts.fullDesc <> headerInfo <> footerInfo
      headerInfo  = Opts.header   "psci - Interactive mode for PureScript"
      footerInfo  = Opts.footer $ "psci " ++ showVersion Paths.version

-- | Parses the input and returns either a command, or an error as a 'String'.
getCommand :: forall m. MonadException m => Bool -> InputT m (Either String (Maybe Command))
getCommand singleLineMode = handleInterrupt (return (Right Nothing)) $ do
  firstLine <- withInterrupt $ getInputLine "> "
  case firstLine of
    Nothing -> return (Right (Just QuitPSCi)) -- Ctrl-D when input is empty
    Just "" -> return (Right Nothing)
    Just s | singleLineMode || head s == ':' -> return . fmap Just $ parseCommand s
    Just s -> fmap Just . parseCommand <$> go [s]
  where
    go :: [String] -> InputT m String
    go ls = maybe (return . unlines $ reverse ls) (go . (:ls)) =<< getInputLine "  "

-- | Make a JavaScript bundle for the browser.
bundle :: IO (Either Bundle.ErrorMessage String)
bundle = runExceptT $ do
  inputFiles <- liftIO (glob (".psci_modules" </> "node_modules" </> "*" </> "*.js"))
  input <- for inputFiles $ \filename -> do
    js <- liftIO (readUTF8File filename)
    mid <- Bundle.guessModuleIdentifier filename
    length js `seq` return (mid, js)
  Bundle.bundle input [] Nothing "PSCI"

indexPage :: IsString string => string
indexPage = fromString . unlines $
  [ "<!DOCTYPE html>"
  , "<html>"
  , "  <head>"
  , "    <script src=\"js/bundle.js\"></script>"
  , "    <script>"
  , "      window.onload = function() {"
  , "        var socket = new WebSocket(\"ws://0.0.0.0:9160\");"
  , "        socket.onopen = function () {"
  , "          console.log(\"Connected\");"
  , "          socket.onmessage = function (event) {"
  , "            var replaced = event.data.replace(/require\\(\"[^\"]*\"\\)/g, function(s) {"
  , "              return \"PSCI['\" + s.substring(12, s.length - 2) + \"']\";"
  , "            });"
  , "            var wrapped ="
  , "                [ 'var module = {};'"
  , "                , '(function(module) {'"
  , "                , replaced"
  , "                , '})(module);'"
  , "                , 'return module.exports[\"$main\"] && module.exports[\"$main\"]();'"
  , "                ].join('\\n');"
  , "            var result = new Function(wrapped)();"
  , "            console.log(result);"
  , "            socket.send(JSON.stringify(result));"
  , "          };"
  , "        };"
  , "      };"
  , "    </script>"
  , "  </head>"
  , "  <body>"
  , "  </body>"
  , "</html>"
  ]

-- | Get command line options and drop into the REPL
main :: IO ()
main = getOpt >>= loop
  where
    loop :: PSCiOptions -> IO ()
    loop PSCiOptions{..} = do
        inputFiles <- concat <$> traverse glob psciInputFile
        e <- runExceptT $ do
          modules <- ExceptT (loadAllModules inputFiles)
          unless (supportModuleIsDefined (map snd modules)) . liftIO $ do
            putStrLn supportModuleMessage
            exitFailure
          (externs, env) <- ExceptT . runMake . make $ modules
          return (modules, externs, env)
        case e of
          Left errs -> putStrLn (P.prettyPrintMultipleErrors P.defaultPPEOptions errs) >> exitFailure
          Right (modules, externs, env) -> do
            historyFilename <- getHistoryFilename
            shutdown <- newEmptyMVar
            let settings = defaultSettings { historyFile = Just historyFilename }
                initialState = PSCiState [] [] (zip (map snd modules) externs)
                config = PSCiConfig inputFiles psciInputNodeFlags env
                runner = flip runReaderT config
                         . flip evalStateT initialState
                         . runInputT (setComplete completion settings)

                handleWebsocket :: WS.PendingConnection -> IO ()
                handleWebsocket pending = do
                  putStrLn "Browser is connected."
                  conn <- WS.acceptRequest pending
                  runner (go conn)

                shutdownHandler :: IO () -> IO ()
                shutdownHandler stopServer = void . forkIO $ do
                  () <- takeMVar shutdown
                  stopServer

                go :: WS.Connection -> InputT (StateT PSCiState (ReaderT PSCiConfig IO)) ()
                go conn = do
                  c <- getCommand (not psciMultiLineMode)
                  case c of
                    Left err -> outputStrLn err >> go conn
                    Right Nothing -> go conn
                    Right (Just QuitPSCi) -> do
                      outputStrLn quitMessage
                      liftIO $ putMVar shutdown ()
                    Right (Just c') -> do
                      handleInterrupt (outputStrLn "Interrupted.")
                                      (withInterrupt (lift (handleCommand conn c')))
                      go conn

                staticServer :: String -> Wai.Application
                staticServer js req respond
                  | [] <- Wai.pathInfo req =
                      respond $ Wai.responseLBS status200
                                                [(hContentType, "text/html")]
                                                indexPage
                  | ["js", "bundle.js"] <- Wai.pathInfo req =
                      respond $ Wai.responseLBS status200
                                                [(hContentType, "application/javascript")]
                                                (fromString js)
                  | otherwise =
                      respond $ Wai.responseLBS status404 [] "Not found"
            putStrLn prologueMessage
            putStrLn "Bundling Javascript..."
            ejs <- bundle
            case ejs of
              Left err -> do
                putStrLn (unlines (Bundle.printErrorMessage err))
                exitFailure
              Right js -> do
                putStrLn "Listening on port 9160. Waiting for connection..."
                Warp.runSettings ( Warp.setInstallShutdownHandler shutdownHandler
                                 . Warp.setPort 9160
                                 $ Warp.defaultSettings
                                 ) $
                  WS.websocketsOr WS.defaultConnectionOptions
                                  handleWebsocket
                                  (staticServer js)
