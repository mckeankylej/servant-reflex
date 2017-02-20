{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveDataTypeable  #-}
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections       #-}

{-# LANGUAGE EmptyCase           #-}
module Servant.Common.Req where

-------------------------------------------------------------------------------
import           Control.Concurrent
import           Control.Applicative        (liftA2, liftA3)
import           Control.Arrow              (second)
import           Control.Monad.IO.Class     (MonadIO, liftIO)
import qualified Data.ByteString.Lazy.Char8 as BL
import qualified Data.Map                   as Map
import           Data.Maybe                 (catMaybes)
import           Data.Functor.Compose
import           Data.Monoid                ((<>))
import           Data.Proxy                 (Proxy(..))
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as TE
import           Data.Traversable
import           Reflex.Dom
import           Servant.Common.BaseUrl     (BaseUrl, showBaseUrl, SupportsServantReflex)
import           Servant.API.ContentTypes   (MimeUnrender(..), NoContent(..))
import           Web.HttpApiData            (ToHttpApiData(..))
-------------------------------------------------------------------------------
import           Servant.API.BasicAuth



data ReqResult a = ResponseSuccess a XhrResponse
                 | ResponseFailure Text XhrResponse
                 | RequestFailure Text

instance Functor ReqResult where
  fmap f (ResponseSuccess a xhr) = ResponseSuccess (f a) xhr
  fmap _ (ResponseFailure r x)   = ResponseFailure r x
  fmap _ (RequestFailure r)      = RequestFailure r

reqSuccess :: ReqResult a -> Maybe a
reqSuccess (ResponseSuccess x _) = Just x
reqSuccess _                     = Nothing

reqFailure :: ReqResult a -> Maybe Text
reqFailure (ResponseFailure s _) = Just s
reqFailure (RequestFailure s)    = Just s
reqFailure _                     = Nothing

response :: ReqResult a -> Maybe XhrResponse
response (ResponseSuccess _ x) = Just x
response (ResponseFailure _ x) = Just x
response _                     = Nothing


-------------------------------------------------------------------------------
-- | You must wrap the parameter of a QueryParam endpoint with 'QParam' to
-- indicate whether the parameter is valid and present, validly absent, or
-- invalid
data QParam a = QParamSome a
              -- ^ A valid query parameter
              | QNone
              -- ^ Indication that the parameter is intentionally absent (the request is valid)
              | QParamInvalid Text
              -- ^ Indication that your validation failed (the request isn't valid)

qParamToQueryPart :: ToHttpApiData a => QParam a -> Either Text (Maybe Text)
qParamToQueryPart (QParamSome a)    = Right (Just $ toQueryParam a)
qParamToQueryPart QNone             = Right Nothing
qParamToQueryPart (QParamInvalid e) = Left e

data QueryPart t = QueryPartParam  (Dynamic t (Either Text (Maybe Text)))
                 | QueryPartParams (Dynamic t [Text])
                 | QueryPartFlag   (Dynamic t Bool)


-------------------------------------------------------------------------------
-- The data structure used to build up request information while traversing
-- the shape of a servant API
data Req t = Req
  { reqMethod    :: Text
  , reqPathParts :: [Dynamic t (Either Text Text)]
  , qParams      :: [(Text, QueryPart t)]
  , reqBody      :: Maybe (Dynamic t (Either Text (BL.ByteString, Text)))
  , headers      :: [(Text, Dynamic t (Either Text Text))]
  , respHeaders  :: XhrResponseHeaders
  , authData     :: Maybe (Dynamic t (Maybe BasicAuthData))
  }

defReq :: Req t
defReq = Req "GET" [] [] Nothing [] def Nothing

prependToPathParts :: Dynamic t (Either Text Text) -> Req t -> Req t
prependToPathParts p req =
  req { reqPathParts = p : reqPathParts req }

addHeader :: (ToHttpApiData a, Reflex t) => Text -> Dynamic t (Either Text a) -> Req t -> Req t
addHeader name val req = req { headers = (name, (fmap . fmap) (TE.decodeUtf8 . toHeader) val) : headers req }


reqToReflexRequest
    :: forall t. Reflex t
    => Text
    -> Req t
    -> Dynamic t BaseUrl
    -> (Dynamic t (Either Text (XhrRequest XhrPayload)))
reqToReflexRequest reqMeth req reqHost =
  let t :: Dynamic t [Either Text Text]
      t = sequence $ reverse $ reqPathParts req

      baseUrl :: Dynamic t (Either Text Text)
      baseUrl = Right . showBaseUrl <$> reqHost

      urlParts :: Dynamic t (Either Text [Text])
      urlParts = fmap sequence t

      urlPath :: Dynamic t (Either Text Text)
      urlPath = (fmap.fmap) (T.intercalate "/") urlParts

      queryPartString :: (Text, QueryPart t) -> Dynamic t (Maybe (Either Text Text))
      queryPartString (pName, qp) = case qp of
        QueryPartParam p -> ffor p $ \case
          Left e         -> Just (Left e)
          Right (Just a) -> Just (Right $ pName <> "=" <> a)
          Right Nothing  -> Nothing
        QueryPartParams ps -> ffor ps $ \pStrings ->
          if null pStrings
          then Nothing
          else Just $ Right (T.intercalate "&" (fmap (\p -> pName <> "=" <> p) pStrings))
        QueryPartFlag fl -> ffor fl $ \case
          True ->  Just $ Right pName
          False -> Nothing


      queryPartStrings :: [Dynamic t (Maybe (Either Text Text))]
      queryPartStrings = map queryPartString (qParams req)
      queryPartStrings' = fmap (sequence . catMaybes) $ sequence queryPartStrings :: Dynamic t (Either Text [Text])
      queryString :: Dynamic t (Either Text Text) =
        ffor queryPartStrings' $ \qs -> fmap (T.intercalate "&") qs
      xhrUrl =  (liftA3 . liftA3) (\a p q -> a </> if T.null q then p else p <> "?" <> q)
          baseUrl urlPath queryString
        where
          (</>) :: Text -> Text -> Text
          x </> y | ("/" `T.isSuffixOf` x) || ("/" `T.isPrefixOf` y) = x <> y
                  | otherwise = x <> "/" <> y


      xhrHeaders :: Dynamic t (Either Text [(Text, Text)])
      xhrHeaders = (fmap sequence . sequence . fmap f . headers) req
        where
          f = \(headerName, dynam) ->
                fmap (fmap (\rightVal -> (headerName, rightVal))) dynam

      mkConfigBody :: Either Text [(Text,Text)]
                   -> (Either Text (BL.ByteString, Text))
                   -> Either Text (XhrRequestConfig XhrPayload)
      mkConfigBody ehs rb = case (ehs, rb) of
                  (_, Left e)                     -> Left e
                  (Left e, _)                     -> Left e
                  (Right hs, Right (bBytes, bCT)) ->
                    Right $ XhrRequestConfig
                      { _xhrRequestConfig_sendData = bytesToPayload bBytes
                      , _xhrRequestConfig_headers  =
                                    Map.insert "Content-Type" bCT (Map.fromList hs)
                      , _xhrRequestConfig_user = Nothing
                      , _xhrRequestConfig_password = Nothing
                      , _xhrRequestConfig_responseType = Nothing
                      , _xhrRequestConfig_withCredentials = False
                      , _xhrRequestConfig_responseHeaders = def
                      }

      xhrOpts :: Dynamic t (Either Text (XhrRequestConfig XhrPayload))
      xhrOpts = case reqBody req of
        Nothing    -> ffor xhrHeaders $ \case
                               Left e -> Left e
                               Right hs -> Right $ def { _xhrRequestConfig_headers = Map.fromList hs
                                                       , _xhrRequestConfig_user = Nothing
                                                       , _xhrRequestConfig_password = Nothing
                                                       , _xhrRequestConfig_responseType = Nothing
                                                       , _xhrRequestConfig_sendData = ""
                                                       , _xhrRequestConfig_withCredentials = False
                                                       }
        Just rBody -> liftA2 mkConfigBody xhrHeaders rBody

      mkAuth :: Maybe BasicAuthData -> Either Text (XhrRequestConfig x) -> Either Text (XhrRequestConfig x)
      mkAuth _ (Left e) = Left e
      mkAuth Nothing r  = r
      mkAuth (Just (BasicAuthData u p)) (Right config) = Right $ config
        { _xhrRequestConfig_user     = Just $ TE.decodeUtf8 u
        , _xhrRequestConfig_password = Just $ TE.decodeUtf8 p}

      addAuth :: Dynamic t (Either Text (XhrRequestConfig x))
              -> Dynamic t (Either Text (XhrRequestConfig x))
      addAuth xhr = case authData req of
        Nothing -> xhr
        Just auth -> liftA2 mkAuth auth xhr

      xhrReq = (liftA2 . liftA2) (\p opt -> XhrRequest reqMeth p opt) xhrUrl (addAuth xhrOpts)

  in xhrReq

-- * performing requests

displayHttpRequest :: Text -> Text
displayHttpRequest httpmethod = "HTTP " <> httpmethod <> " request"

-- | This function actually performs the request.
performRequests :: forall t m f tag.(SupportsServantReflex t m, Traversable f)
                => Text
                -> f (Req t)
                -> Dynamic t BaseUrl
                -> Event t tag
                -> m (Event t (tag, f (Either Text XhrResponse)))
performRequests reqMeth rs reqHost trigger = do
  let xhrReqs = sequence $ (\r -> reqToReflexRequest reqMeth r reqHost) <$> rs :: Dynamic t (f (Either Text (XhrRequest XhrPayload)))
  let reqs    = attachPromptlyDynWith (\fxhr t -> Compose (t, fxhr)) xhrReqs trigger
  resps <- performSomeRequestsAsync reqs
  return $ getCompose <$> resps

-- | Issues a collection of requests when the supplied Event fires.  When ALL requests from a given firing complete, the results are collected and returned via the return Event.
performSomeRequestsAsync
    :: (MonadIO (Performable m),
        HasWebView (Performable m),
        PerformEvent t m,
        TriggerEvent t m,
        Traversable f,
        IsXhrPayload a)
    => Event t (f (Either Text (XhrRequest a)))
    -> m (Event t (f (Either Text XhrResponse)))
performSomeRequestsAsync = performSomeRequestsAsync' newXMLHttpRequest . fmap return


------------------------------------------------------------------------------
-- | A modified version or Reflex.Dom.Xhr.performRequestsAsync
-- that accepts 'f (Either e (XhrRequestb))' events
performSomeRequestsAsync'
    :: (MonadIO (Performable m), PerformEvent t m, TriggerEvent t m, Traversable f)
    => (XhrRequest b -> (a -> IO ()) -> Performable m XMLHttpRequest)
    -> Event t (Performable m (f (Either Text (XhrRequest b)))) -> m (Event t (f (Either Text a)))
performSomeRequestsAsync' newXhr req = performEventAsync $ ffor req $ \hrs cb -> do
  rs <- hrs
  resps <- forM rs $ \r -> case r of
      Left e -> do
          resp <- liftIO $ newMVar (Left e)
          return resp
      Right r' -> do
          resp <- liftIO newEmptyMVar
          _ <- newXhr r' $ liftIO . putMVar resp . Right
          return resp
  _ <- liftIO $ forkIO $ cb =<< forM resps takeMVar
  return ()



-- | This function actually performs the request.
performRequest :: forall t m tag .(SupportsServantReflex t m)
               => Text
               -> (Req t)
               -> Dynamic t BaseUrl
               -> Event t tag
               -> m (Event t (tag, XhrResponse), Event t (tag, Text))
performRequest reqMeth req reqHost trigger = do

  let xhrReq  = reqToReflexRequest reqMeth req reqHost
  let reqs    = attachPromptlyDynWith (flip (,)) xhrReq trigger
      okReqs  = fmapMaybe (\(t,e) -> either (const Nothing) (Just . (t,)) e) reqs
      badReqs = fmapMaybe (\(t,e) -> either (Just . (t,)) (const Nothing) e) reqs

  resps <- performRequestsAsync okReqs

  return (resps, badReqs)


#ifdef ghcjs_HOST_OS
type XhrPayload = String
bytesToPayload :: BL.ByteString -> XhrPayload
bytesToPayload = BL.unpack
#else
type XhrPayload = T.Text
bytesToPayload :: BL.ByteString -> XhrPayload
bytesToPayload = T.pack . BL.unpack
#endif

performRequestNoBody :: forall t m tag.(SupportsServantReflex t m)
                     => Text
                     -> Req t
                     -> Dynamic t BaseUrl
                     -> Event t tag -> m (Event t (tag, ReqResult NoContent))
performRequestNoBody reqMeth req reqHost trigger = do
  (resp, badReq) <- performRequest reqMeth req reqHost trigger
  return $ leftmost [ fmap (ResponseSuccess NoContent) <$> resp, fmap RequestFailure <$> badReq]

performRequestsNoBody :: forall t m f tag. (SupportsServantReflex t m, Traversable f)
                     => Text
                     -> f (Req t)
                     -> Dynamic t BaseUrl
                     -> Event t tag -> m (Event t (tag, f (ReqResult NoContent)))
performRequestsNoBody reqMeth reqs reqHost trigger = do
  resp <- performRequests reqMeth reqs reqHost trigger
  return $ (fmap . fmap) aux <$> resp
  where
    aux (Right x) = ResponseSuccess NoContent x
    aux (Left  e) = RequestFailure e
  -- return $ leftmost [ fmap (ResponseSuccess NoContent) resp, fmap RequestFailure badReq]


performRequestCT
    :: (SupportsServantReflex t m,
        MimeUnrender ct a)
    => Proxy ct
    -> Text
    -> Req t
    -> Dynamic t BaseUrl
    -> Event t tag
    -> m (Event t (tag, ReqResult a))
performRequestCT ct reqMeth req reqHost trigger = do
  (resp, badReq) <- performRequest reqMeth req reqHost trigger
  let decodes = ffor resp $ fmap (\xhr ->
        ((mimeUnrender ct . BL.fromStrict . TE.encodeUtf8)
         =<< note "No body text" (_xhrResponse_responseText xhr), xhr))
      reqs = ffor decodes $ fmap (\case
        (Right a, r) -> ResponseSuccess a r
        (Left e,  r) -> ResponseFailure (T.pack e) r)
  return $ leftmost [reqs, fmap RequestFailure <$> badReq]

performRequestsCT
    :: (SupportsServantReflex t m,
        MimeUnrender ct a, Traversable f)
    => Proxy ct
    -> Text
    -> f (Req t)
    -> Dynamic t BaseUrl
    -> Event t tag
    -> m (Event t (tag, f (ReqResult a)))
performRequestsCT ct reqMeth reqs reqHost trigger = do
  resps <- performRequests reqMeth reqs reqHost trigger
  return $ fmap (second (fmap reqToResult)) resps
  where
    reqToResult (Left  e) = RequestFailure e
    reqToResult (Right x) = case _xhrResponse_responseText x of
      Nothing  -> ResponseFailure "No request body" x
      Just bod -> case mimeUnrender ct . BL.fromStrict . TE.encodeUtf8 $ bod of
        Left e  -> ResponseFailure (T.pack e) x
        Right v -> ResponseSuccess v x


note :: e -> Maybe a -> Either e a
note e = maybe (Left e) Right

fmapL :: (e -> e') -> Either e a -> Either e' a
fmapL _ (Right a) = Right a
fmapL f (Left e)  = Left (f e)
