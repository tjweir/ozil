module Help.Ozil where

import Commons

import Help.Ozil.Cmd
import Help.Ozil.Core

import Help.Page.Lenses (indents, anchors, tableIxs, helpPage)
import Help.Ozil.Config (FSEvent, toReactOrNotToReact)
import Help.Ozil.KeyBinding (matchesKeyPress, Action (..))
import Help.Ozil.Startup (finishStartup)

import qualified Help.Page as Page
import qualified Help.Ozil.Config.Default as Default

import Brick (App (..))
import Data.Foldable (any)
import System.Directory (doesDirectoryExist)

import qualified Brick
import qualified Brick.BChan as BChan
import qualified Brick.Widgets.Border as Border
import qualified Data.HashMap.Strict as H
import qualified Data.Text as T
import qualified Graphics.Vty as Vty
import qualified System.FSNotify as FSNotify

main :: IO ()
main = defaultMain $ \opts -> do
  (dp, cfg) <- finishStartup opts
  FSNotify.withManager $ \wm -> do
    chan <- BChan.newBChan maxChanSize
    saveConfig $
      Brick.customMain gui (Just chan) oapp (newOState opts wm chan dp cfg)
  where
    gui = Vty.mkVty Vty.defaultConfig
    maxChanSize = 20
    saveConfig = void

oapp :: OApp
oapp = Brick.App
  { appDraw = viewerUI
  , appChooseCursor = Brick.showFirstCursor
  , appHandleEvent = handleEvent
  , appStartEvent = ozilStartEvent
  , appAttrMap = const $ Brick.attrMap Vty.defAttr
      [ ("subc-link", subc_attr)
      , ("subc-highlight", Vty.withStyle subc_attr Vty.standout)
      , ("sec-heading", plain_bold)
      , ("man-B", plain_bold)
      , ("man-default", Vty.defAttr)
      , ("man-I", plain_underline)
      ]
  }
  where
    plain_bold = Vty.withStyle Vty.defAttr Vty.bold
    plain_underline = Vty.withStyle Vty.defAttr Vty.underline
    subc_attr = plain_underline

ozilStartEvent :: OState -> Brick.EventM OResource OState
ozilStartEvent s = case s ^. watch of
  NoWatch -> pure s
  Running _ -> pure s
  Uninitialized wm -> do
    sw <- liftIO $
      doesDirectoryExist ozilDir >>= \case
        False -> pure NoWatch
        True -> Running
          <$> FSNotify.watchDir wm ozilDir toReactOrNotToReact forwardEvent
    pure (set watch sw s)
  where
    ozilDir = Default.configDir
    forwardEvent :: FSEvent -> IO ()
    forwardEvent = BChan.writeBChan (getBChan s) . OEvent

handleEvent
  :: OState
  -> Brick.BrickEvent n OEvent
  -> Brick.EventM OResource (Brick.Next OState)
handleEvent s = \case
  KeyPress Vty.KEsc        -> stopProgram
  KeyPress (Vty.KChar 'q') -> stopProgram
  ev -> do
    scrollAmt <- if
      | ev `isKeyFor` ScrollUp -> pure (-1)
      | ev `isKeyFor` ScrollDown -> pure 1
      | ev `isKeyFor` ScrollUpHalfPage -> ((-1) *) <$> halfHeight
      | ev `isKeyFor` ScrollDownHalfPage -> halfHeight
      | otherwise -> pure 0
    when (scrollAmt /= 0)
      $ Brick.vScrollBy (Brick.viewportScroll TextViewport) scrollAmt
    let changeLinkState = if
          | ev `isKeyFor` ToggleLinks -> Page.flipLinkState
          | ev `isKeyFor` LinkJumpNext -> Page.mapLinkState (+1)
          | ev `isKeyFor` LinkJumpPrevious -> Page.mapLinkState (subtract 1)
          | otherwise -> id
    let changeDocState = if
          | ev `isKeyFor` LinkFollow -> pushDoc
          | ev `isKeyFor` LinkGoBack -> pure . popDoc
          | otherwise -> pure
    s' <- liftIO (changeDocState (over linkState changeLinkState s))
    Brick.continue s'
  where
    isKeyFor (Brick.VtyEvent (Vty.EvKey k mods)) action =
      any (matchesKeyPress k mods) ((s ^. keyBindings) H.! action)
    isKeyFor _ _ = False
    stopProgram = do
      case s ^. watch of
        Running stopWatch -> liftIO stopWatch
        Uninitialized _ -> pure ()
        NoWatch -> pure ()
      Brick.halt s
    halfHeight :: Brick.EventM OResource Int
    halfHeight = do
      mvp <- Brick.lookupViewport TextViewport
      mvp & fromMaybe (error "Viewport missing. Wat.")
          & view Brick.vpSize
          & Vty.regionHeight
          & \h -> pure (h `div` 2)


-- The UI should look like
--
-- +------  heading  ------+
-- |                       |
-- | blah                  |
-- |                       |
-- | blah                  |
-- |                       |
-- | blah                  |
-- |                       |
-- +-----------------------+
-- | Esc/q = Exit ...      |
-- +-----------------------+
--
-- ui :: (Show n, Ord n) => Brick.Widget n
viewerUI
  :: ( HasDoc s Page.DocPage
     , HasHeading s Text
     , HasLinkState s Page.LinkState
     , HasDebugMode s Bool)
  => s
  -> [Brick.Widget OResource]
viewerUI s =
  (\x -> if s ^. debugMode then [Brick.vBox [debugWidget, x]] else [x])
  $ Border.borderWithLabel (Brick.txt header)
    $ mainstuff
      ===
      Border.hBorder
      ===
      Brick.txtWrap keyBindingTxt
  where
    debugWidget =
      Brick.strWrap (s ^. doc & Page.displayDocPageSummary)
      ===
      Brick.strWrap (("Anchors: " <>) . show $ s ^? doc . helpPage . anchors)
      ===
      Brick.strWrap (("TableIxs: " <>) . show $ s ^? doc . helpPage . tableIxs)
      ===
      Brick.strWrap (("Indents: " <>) . show $ s ^? doc . helpPage . indents)
    keyBindingTxt = keyBindings1 <> "\n" <> keyBindings2
    keyBindings1 = "Esc/q = Exit  k/↑ = Up  C-u = Up!  j/↓ = Down  C-d = Down!"
    keyBindings2 =
      if s ^. linkState & Page.isOn then
        "f = Turn off hints   n = Next hint   p = Previous hint\n\
        \                 C-n/↵ = Follow  C-p/← = Go back"
      else
        "f = Turn on hints"
    header = T.snoc (T.cons ' ' (s ^. heading)) ' '
    mainstuff = Page.render (s ^. linkState) (s ^. doc)
      & Brick.viewport TextViewport Brick.Vertical