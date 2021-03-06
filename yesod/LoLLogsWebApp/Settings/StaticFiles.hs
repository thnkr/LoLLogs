module Settings.StaticFiles where

import Prelude
import Yesod.Static
import Settings (staticDir)

staticSite :: IO Static
staticSite =
#ifdef DEVELOPMENT
    staticDevel staticDir
#else
    static staticDir
#endif

-- | This generates easy references to files in the static directory at compile time.
--   The upside to this is that you have compile-time verification that referenced files
--   exist. However, any files added to your static directory during run-time can't be
--   accessed this way. You'll have to use their FilePath or URL to access them.
$(staticFiles "static")
