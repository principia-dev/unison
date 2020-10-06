{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE KindSignatures #-}

module Unison.Server.CodebaseServer where

import           Control.Monad.IO.Class         ( liftIO )
import           Control.Monad.Except           ( runExceptT )
import           Data.Aeson
import qualified Data.ByteString.Lazy          as LZ
import           Data.Maybe                     ( fromMaybe )
import           Data.Proxy
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import qualified Data.Text.Encoding            as Text
import           GHC.Generics
import           Network.Wai.Handler.Warp       ( run )
import           Servant.API
import           Servant.Server
import           Servant                        ( throwError )
import qualified Unison.Codebase               as Codebase
import           Unison.Codebase                ( Codebase )
import qualified Unison.Codebase.Causal        as Causal
import qualified Unison.Hash                   as Hash
import qualified Unison.HashQualified          as HQ
import qualified Unison.HashQualified'         as HQ'
import qualified Unison.Codebase.Path          as Path
import qualified Unison.Codebase.Branch        as Branch
import           Unison.ConstructorType         ( ConstructorType )
import           Unison.Name                    ( Name(..) )
import qualified Unison.Name                   as Name
import qualified Unison.NameSegment            as NameSegment
import           Unison.Parser                  ( Ann )
import           Unison.Pattern                 ( SeqOp )
import qualified Unison.PrettyPrintEnv         as PPE
import qualified Unison.Reference              as Reference
import qualified Unison.Referent               as Referent
import qualified Unison.Server.Backend         as Backend
import           Unison.ShortHash               ( ShortHash )
import           Unison.Type                    ( Type )
import           Unison.Util.Pretty             ( render
                                                , Width
                                                )
import           Unison.Util.SyntaxText         ( SyntaxText' )
import qualified Unison.Util.SyntaxText        as SyntaxText
import           Unison.Var                     ( Var )
import qualified Unison.TypePrinter            as TypePrinter


--import GHC.TypeLits
--import Network.Wai.Handler.Warp

type HashQualifiedName = Text

type Size = Int

type UnisonName = Text

type UnisonHash = Text

type NamespaceAPI
  = "list" :> QueryParam "namespace" HashQualifiedName :> Get '[JSON] NamespaceListing

type FooAPI = "foo" :> Get '[JSON] ()

type API = NamespaceAPI :<|> FooAPI

data NamespaceListing = NamespaceListing
  { namespaceListingName :: UnisonName
  , namespaceListingHash :: UnisonHash
  , namespaceListingChildren :: [NamespaceObject]
  } deriving Generic

instance ToJSON NamespaceListing

data NamespaceObject
  = Subnamespace NamedNamespace
  | TermObject NamedTerm
  | TypeObject NamedType
  | PatchObject NamedPatch
  deriving Generic

instance ToJSON NamespaceObject

data NamedNamespace = NamedNamespace
  { namespaceName :: UnisonName
  , namespaceSize :: Size
  } deriving Generic

instance ToJSON NamedNamespace

data NamedTerm = NamedTerm
  { termName :: HashQualifiedName
  , termHash :: UnisonHash
  , termType :: Maybe (SyntaxText' ShortHash)
  } deriving Generic

instance ToJSON NamedTerm

data NamedType = NamedType
  { typeName :: HashQualifiedName
  , typeHash :: UnisonHash
  } deriving Generic

instance ToJSON NamedType

data NamedPatch = NamedPatch
  { patchName :: HashQualifiedName
  } deriving Generic

instance ToJSON NamedPatch

newtype KindExpression = KindExpression { kindExpressionText :: Text }
  deriving Generic

instance ToJSON KindExpression

formatType
  :: Var v => PPE.PrettyPrintEnv -> Width -> Type v a -> SyntaxText' ShortHash
formatType ppe w =
  fmap (fmap Reference.toShortHash) . render w . TypePrinter.pretty0 ppe
                                                                     mempty
                                                                     (-1)

defaultWidth :: Width
defaultWidth = 80

mayDefault :: Maybe Width -> Width
mayDefault = fromMaybe defaultWidth

instance ToJSON Name
instance ToJSON ShortHash
instance ToJSON HQ.HashQualified
instance ToJSON ConstructorType
instance ToJSON SeqOp
instance ToJSON r => ToJSON (Referent.Referent' r)
instance ToJSON r => ToJSON (SyntaxText.Element r)
instance ToJSON r => ToJSON (SyntaxText' r)

backendListEntryToNamespaceObject
  :: Var v
  => PPE.PrettyPrintEnv
  -> Maybe Width
  -> Backend.ShallowListEntry v a
  -> NamespaceObject
backendListEntryToNamespaceObject ppe typeWidth = \case
  Backend.ShallowTermEntry r name mayType -> TermObject $ NamedTerm
    { termName = HQ'.toText name
    , termHash = Referent.toText r
    , termType = formatType ppe (mayDefault typeWidth) <$> mayType
    }
  Backend.ShallowTypeEntry r name -> TypeObject $ NamedType
    { typeName = HQ'.toText name
    , typeHash = Reference.toText r
    }
  Backend.ShallowBranchEntry name size -> Subnamespace $ NamedNamespace
    { namespaceName = NameSegment.toText name
    , namespaceSize = size
    }
  Backend.ShallowPatchEntry name ->
    PatchObject . NamedPatch $ NameSegment.toText name

munge :: Text -> LZ.ByteString
munge = LZ.fromStrict . Text.encodeUtf8

mungeShow :: Show s => s -> LZ.ByteString
mungeShow = mungeString . show

mungeString :: String -> LZ.ByteString
mungeString = munge . Text.pack

badHQN :: HashQualifiedName -> ServerError
badHQN hqn = err400
  { errBody = munge hqn
              <> " is not a well-formed name, hash, or hash-qualified name. "
              <> "I expected something like `foo`, `#abc123`, or `foo#abc123`."
  }

backendError :: Backend.BackendError -> ServerError
backendError = \case
  Backend.NoSuchNamespace n -> noSuchNamespace . Path.toText $ Path.unabsolute n
  Backend.BadRootBranch e -> rootBranchError e

rootBranchError :: Codebase.GetRootBranchError -> ServerError
rootBranchError rbe = err500
  { errBody = case rbe of
                Codebase.NoRootBranch -> "Couldn't identify a root namespace."
                Codebase.CouldntLoadRootBranch h ->
                  "Couldn't load root branch " <> mungeShow h
                Codebase.CouldntParseRootBranch h ->
                  "Couldn't parse root branch head " <> mungeShow h
  }

badNamespace :: String -> String -> ServerError
badNamespace err namespace = err400
  { errBody = "Malformed namespace: "
              <> mungeString namespace
              <> ". "
              <> mungeString err
  }

noSuchNamespace :: HashQualifiedName -> ServerError
noSuchNamespace namespace =
  err404 { errBody = "The namespace " <> munge namespace <> " does not exist." }

api :: Proxy API
api = Proxy

app :: Var v => Codebase IO v Ann -> Application
app codebase = serve api $ server codebase

start :: Var v => Codebase IO v Ann -> Int -> IO ()
start codebase port = run port $ app codebase

server :: Var v => Codebase IO v Ann -> Server API
server codebase = serveNamespace codebase :<|> foo
 where
  foo = pure ()

discard :: Applicative m => a -> m ()
discard = const $ pure ()

serveNamespace
  :: Var v
  => Codebase IO v Ann
  -> Maybe HashQualifiedName
  -> Handler NamespaceListing
serveNamespace codebase mayHQN = case mayHQN of
  Nothing  -> serveNamespace codebase $ Just "."
  Just hqn -> do
    parsedName <- parseHQN hqn
    case parsedName of
      HQ.NameOnly n -> do
        path'      <- parsePath $ Name.toString n
        gotRoot    <- liftIO $ Codebase.getRootBranch codebase
        root       <- errFromEither rootBranchError gotRoot
        hashLength <- liftIO $ Codebase.hashLength codebase
        let
          p = either id (Path.Absolute . Path.unrelative) $ Path.unPath' path'
          ppe =
            Backend.basicSuffixifiedNames hashLength root $ Path.fromPath' path'
        entries <- findShallow p
        pure
          . NamespaceListing
              (Name.toText n)
              (Hash.base32Hex . Causal.unRawHash $ Branch.headHash root)
          $ fmap (backendListEntryToNamespaceObject ppe Nothing) entries
      HQ.HashOnly h        -> undefined h
          -- if hash present, look up branch by hash in codebase
      HQ.HashQualified _ h -> undefined h
            -- if hash present, look up branch by hash in codebase

 where
  errFromMaybe e = maybe (throwError e) pure
  errFromEither f = either (throwError . f) pure
  parseHQN hqn = errFromMaybe (badHQN hqn) $ HQ.fromText hqn
  parsePath p = errFromEither (flip badNamespace p) $ Path.parsePath' p
  findShallow p = do
    ea <- liftIO . runExceptT $ Backend.findShallow codebase p
    errFromEither backendError ea

