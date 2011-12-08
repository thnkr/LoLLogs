{-# LANGUAGE ExistentialQuantification, ScopedTypeVariables, PatternGuards #-}
module Model.Helper.MapReduce ( execute
                              , Queryable(..)
                              , simpleKey
                              , simpleMap
                              , simpleReduce
                              , simpleFinalize
                              , simpleFinalizeAvg
                              , simpleFilter
                              , GroupOp(..)
                              , buildQuery
                              , QuerySelect(..)
                              , (.==)
                              , (.<)
                              , (.>)
                              , (.<=)
                              , (.>=)
                              , exists
                              , t2u
                              , u2t
                              , unJS
                              , wrapJS
                              ) where

import Database.MongoDB as Mongo

import Prelude
import Data.Int
import Data.List (union, intercalate)
import Data.UString as S (UString, pack, unpack, concat)
import Database.Persist.Base
import Data.Text as T (Text, unpack, pack)
import Data.String
import qualified Data.Map as M

import Control.Monad.State as St

t2u = S.pack . T.unpack
u2t = T.pack . S.unpack
catJS = S.concat . map unJS
unJS (Javascript _ code) = code
wrapJS = Javascript []

instance Val Text where
    val = String . S.pack . T.unpack
    cast' v = case v of
        String str -> Just . T.pack . S.unpack $ str
        _          -> Nothing

instance IsString Javascript where
    fromString = Javascript [] . S.pack

class PersistEntity model => Queryable model where
    data QueryColumn model :: * -> *
    -- Minimal definition
    queryKeyCode        :: QueryColumn model typ -> Javascript -- ^ Used to select when used as a key.
    queryColumnName     :: QueryColumn model typ -> UString    -- ^ The column name
    queryMapCode        :: QueryColumn model typ -> Javascript -- ^ Should set fields on "result" from "this".  Run once for each document.
    queryFilter         :: QueryColumn model typ -> Value -> Document  -- ^ Produce the document to be used as a filter when given a value.

    -- Optional
    queryReduceCode     :: QueryColumn model typ -> Javascript -- ^ Used to merge fields from the map set.  Should merge "v" into "result", touching only its fields.
    queryReduceCode = simpleReduce GroupTotal

    queryFinalizeCode   :: QueryColumn model typ -> Javascript -- ^ Used to finalize the result.  Should work on "result" and "v".  The value assigned
                                                               -- to "result" will be what is returned.  It can make use of multiple fields
                                                               -- or the built-in _count field.
    queryFinalizeCode = simpleFinalize


    queryCastResult     :: (Val typ) => QueryColumn model typ -> Value -> Maybe typ -- ^ Cast a result of type Value into the type for this column.
    queryCastResult _ v = cast' v

    queryCollection     :: QueryColumn model typ -> UString
    queryCollection _ = S.pack . entityName $ entityDef (undefined :: model)

{- | Execute a map-reduce query, returning a either a list of results as touples from values to maps of data, or an error.
 -}
execute :: MapReduce -> IO (Either Failure [(Label, M.Map Label Value)])
execute query = do
    conn <- runIOE . connect $ host "localhost"
    result <- access conn UnconfirmedWrites "LoLLogsWebApp" . runMR' $ query
    case result of
        Left err -> return $ Left err
        Right doc -> return $ do
            results <- Mongo.lookup "results" doc
            let makeRecord doc = do
                id <- Mongo.lookup "_id" doc
                values <- Mongo.lookup "value" doc
                return (id, M.fromList $ map (\(l := v) -> (l,v)) values) :: Either Failure (Label, M.Map Label Value)
            mapM makeRecord results

{- | Reduce operators.
 -}
data GroupOp = GroupAvg
             | GroupTotal
             | GroupFirst
             deriving (Show, Eq)
{- | Return an group opperations aggregation funciton.
 -}
groupAggregator :: GroupOp -> UString
groupAggregator (GroupAvg) = "+";
groupAggregator (GroupTotal) = "+";
groupAggregator (GroupFirst) = "||";

simpleKey :: Queryable model => UString -> QueryColumn model typ -> Javascript
simpleKey selector _ = wrapJS $ S.concat ["this.", selector]

simpleMap :: Queryable model => UString -> QueryColumn model typ -> Javascript
simpleMap selector col =
    let field = queryColumnName col
     in Javascript [] $ S.concat ["result.", field, " = this.", selector, ";"]

{- | Create a simple grouping function based on an operator and a selector.
 -}
simpleReduce :: Queryable model => GroupOp -> QueryColumn model typ -> Javascript
simpleReduce op col =
    let field = queryColumnName col
     in Javascript [] $ S.concat ["result.", field, " = result.", field, groupAggregator op, "v.", field, ";"]

simpleFinalize :: Queryable model => QueryColumn model typ -> Javascript
simpleFinalize col =
    let field = queryColumnName col
     in Javascript [] $ S.concat ["result.", field, " = v.", field, ";"]

simpleFinalizeAvg :: Queryable model => QueryColumn model typ -> Javascript
simpleFinalizeAvg col =
    let field = queryColumnName col
     in Javascript [] $ S.concat ["result.", field, " = v.", field, " / v._count;"]

simpleFilter :: Queryable model => UString -> QueryColumn model typ -> Value -> Document
simpleFilter selector col v = [ selector := v ]

data QueryFilter model = forall typ. Val typ => QueryFilter FilterOp (QueryColumn model typ) typ
                 | QueryAll [QueryFilter model]
                 | QueryAny [QueryFilter model]

data QuerySelect model = forall typ. QuerySelect (QueryColumn model typ)

data FilterOp = FilterEQ
              | FilterLT
              | FilterGT
              | FilterLE
              | FilterGE
              | FilterExists

parseFilters :: Queryable model => [QueryFilter model] -> Document
parseFilters []     = []
parseFilters fs | (f:[]) <- fs = convertFilter f
                | otherwise    = convertFilter . QueryAll $ fs
    where
        convertFilter f | (QueryAll fs) <- f = ["$and" =: map convertFilter fs]
                        | (QueryAny fs) <- f = ["$or"  =: map convertFilter fs]
                        | (QueryFilter FilterEQ col v) <- f = queryFilter col $ val v
                        | (QueryFilter FilterLT col v) <- f = queryFilter col $ Doc ["$lt" =: v]
                        | (QueryFilter FilterGT col v) <- f = queryFilter col $ Doc ["$gt" =: v]
                        | (QueryFilter FilterLE col v) <- f = queryFilter col $ Doc ["$le" =: v]
                        | (QueryFilter FilterGE col v) <- f = queryFilter col $ Doc ["$ge" =: v]
                        | (QueryFilter FilterExists col v) <- f = queryFilter col $ Doc ["$exists" =: True]

(.==) :: (Eq typ, Val typ, Queryable model) => QueryColumn model typ -> typ -> QueryFilter model
(.==) = QueryFilter FilterEQ
(.<), (.>), (.<=), (.>=) :: (Ord typ, Val typ, Queryable model) => QueryColumn model typ -> typ -> QueryFilter model
(.<)  = QueryFilter FilterLT
(.>)  = QueryFilter FilterGT
(.<=) = QueryFilter FilterLE
(.>=) = QueryFilter FilterGE
exists col = QueryFilter FilterExists col undefined

{-
newtype MRQuery a = Q {
    runQuery :: State QueryState a
} deriving(Monad, Functor, MonadState QueryState)

data QueryState = QueryState
    { keyField :: UString
    , fields   :: M.Map UString (Javascript, Javascript, Javascript) -- ^ The map from field names to map, reduce, and filter javascript for them.
    } deriving (Show)
-}

{- | Build a MapReduce query. -}
buildQuery :: Queryable model => QueryColumn model typ -- ^ The column to use a key.
           -> [QueryFilter model]         -- ^ A list of filters.
           -> forall typ. [QueryColumn model typ]         -- ^ A list of columns to select for the output.
           -> MapReduce
buildQuery keyCol filters fields =
    let collection = queryCollection keyCol

        key = unJS $ queryKeyCode keyCol
        mapCode      = catJS . map (queryMapCode) $ fields
        reduceCode   = catJS . map (queryReduceCode) $ fields
        finalizeCode = catJS . map (queryFinalizeCode) $ fields

        mapFunc = Javascript [] $ S.concat ["function () { var key = ", key, "; var result = {_count: 1};", mapCode, "emit(key, result); }"]
        reduceFunc = Javascript [] $ S.concat ["function (key, vals) { var result = vals[0]; for (var i = 1; i < vals.length; i++) { var v = vals[i]; result._count = result._count + v._count; ", reduceCode, "}; return result; }"]
        finalizeFunc = Javascript [] $ S.concat ["function (key, v) { var result = {_count: v._count}; ", finalizeCode, "return result; }"]

     in MapReduce collection mapFunc reduceFunc (parseFilters filters) [] 0 Inline (Just finalizeFunc) [] False
{-
addColumn :: QueryColumn column typ => column -> MRQuery ()
addColumn column = do
    let col    = queryColumnName column
        select = querySelector column
        op     = queryReduceOp column
    addField col (select, op)
    where
        addField col dat = St.modify $ \s@(QueryState _ fields) -> s { fields = M.insert col dat fields }

setKey :: QueryColumn model typ -> MRQuery ()
setKey column = do
    let select = querySelector column
    St.modify $ (\s -> s { keyField = select })

showDocument :: Document -> String
showDocument ls = "{" ++ (intercalate ", " $ map (\(l := v) -> show l ++ ": " ++ showDocumentR v) ls) ++ "}"
    where
        showDocumentR :: Value -> String
        showDocumentR (Doc ls) = showDocument ls
        showDocumentR (Array as) = "[" ++ (intercalate ", " $ map show as) ++ "]"
        showDocumentR other = show other
-}