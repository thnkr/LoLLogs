module Yesod.Widget.Pager ( paginateSelectList
                          , pager
                          ) where


import Prelude hiding (writeFile, readFile)
import Yesod
import Data.Text (Text)
import Data.Maybe (fromMaybe)
import Control.Applicative ((<$>), (<*>), pure)

data PagerOptions = PagerOptions
    { showNext :: Bool
    , showPrev :: Bool
    , showFirst :: Bool
    , showLast :: Bool
    , showPages :: Bool
    , pageContext :: Maybe Int
    , cssClass :: Text
    , currentPage :: Int
    , maxPage :: Int
    , pageSize :: Int
    , urlGenerator :: Int -> Html
    }

defaultPagerOptions :: PagerOptions
defaultPagerOptions = PagerOptions
    { showNext  = True
    , showPrev  = True
    , showFirst = True
    , showLast  = True
    , showPages = True
    , pageContext = Nothing
    , cssClass = "pagination"
    , currentPage = 0
    , maxPage = 0
    , pageSize = 10
    , urlGenerator = defaultUrlGenerator
    }

defaultUrlGenerator :: Int -> Html
defaultUrlGenerator i = toHtml $ "?p=" ++ show i

paginateSelectList pSize filters opts = do
    page <- fromMaybe 1 <$> (runInputGet $ iopt intField "p")
    let offset = max ((page - 1) * pSize) 0
    (results, totalCount) <- runDB $ do -- Single transaction by using one runDB call.
        results    <- selectList filters (LimitTo pSize : OffsetBy offset : opts)
        totalCount <- count filters
        return (results, totalCount)
    let pagerOpts = defaultPagerOptions { pageSize = pSize, currentPage = page, maxPage = totalCount `div` pSize + 1}
    return (results, pagerOpts)

pager :: PagerOptions -> GWidget sub master ()
pager opts = 
    let p = currentPage opts
        m = maxPage opts
        minP= maybe 1 (\context -> max 1 (currentPage opts - context)) $ pageContext opts
        maxP = maybe m (\context -> min m (currentPage opts + context)) $ pageContext opts
        prevP = max 0 (p - 1)
        nextP = min m (p + 1)
        pageNums = [minP .. maxP]
    in [whamlet|
$if (m > 1)
    <div class=#{cssClass opts}>
        <ul>
            $if showFirst opts
                <li.first.prev :p <= 1:.disabled>
                    <a href=#{urlGenerator opts 0}>
                        First
            $if showPrev opts
                <li.prev :p <= 1:.disabled>
                    <a href=#{urlGenerator opts prevP}>
                        Prev
            $forall n <- pageNums
                <li :n == p:.active>
                    <a href=#{urlGenerator opts n}
                        #{n}
            $if showNext opts
                <li.next :p >= m:.disabled>
                    <a href=#{urlGenerator opts nextP}>
                        Next
            $if showLast opts
                <li.last.next :p >= m:.disabled>
                    <a href=#{urlGenerator opts m}>
                        Last
|]