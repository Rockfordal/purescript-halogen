-- | This module defines a type of composable _components_, built from
-- | the types provided by this library - signal functions and HTML documents.

module Halogen.Component 
  ( Component()
  
  , install
  , combine
  
  , widget
  
  , mapP
  , hoistComponent
  ) where

import Data.DOM.Simple.Types

import Data.Int
import Data.Maybe
import Data.Either
import Data.Bifunctor (lmap, rmap)

import Control.Monad.Eff

import Halogen.HTML (HTML(), placeholder, graft)
import Halogen.Signal (SF(), SF1(), mergeWith, stateful, startingAt, input, tail)
import Halogen.Internal.VirtualDOM (Widget())

import qualified Halogen.HTML.Widget as W
      
-- | A component.
-- | 
-- | The type parameters are, in order:
-- |
-- | - `p`, the type of _placeholders_
-- | - `m`, the monad used to track effects required by external requests
-- | - `req`, the type of external requests
-- | - `res`, the type of external responses
-- | 
-- | Request and response types are public, but the component may also use an _internal_ type
-- | of messages, as illustrated by the type of the `component` function.
-- |
-- | The main interface to Halogen is the `runUI` function, which takes a component as an argument,
-- | with certain constraints between the type arguments. This module leaves the type arguments
-- | unrestricted, allowing components to be composed in various ways.
-- |
-- | If you do not use a particular feature (e.g. placeholders, requests), you might like to leave 
-- | the corresponding type parameter unconstrained in the declaration of your component. 
type Component p m req res = SF1 req (HTML p (m res))

-- | Construct a `Component` from a third-party widget.
-- |
-- | The function argument is a record with the following properties:
-- |
-- | - `name` - the type of the widget, required by `virtual-dom` to distinguish different
-- |   types of widget.
-- | - `id` - a unique ID which belongs to this instance of the widget type, required by 
-- |   `virtual-dom` to distinguish widgets from each other.
-- | - `init` - an action which initializes the component and returns the `HTMLElement` it corresponds
-- |   to in the DOM. This action receives the driver function for the component so that it can
-- |   generate events. It can also create a piece of state of type `s` which is shared with the
-- |   other lifecycle functions.
-- | - `update` - Update the widget based on an input message.
-- | - `destroy` - Release any resources associated with the widget as it is about to be removed
-- |   from the DOM.
widget :: forall eff req res ctx m. 
  (Functor m) => 
  { name    :: String
  , id      :: String
  , init    :: (res -> Eff eff Unit) -> Eff eff { context :: ctx, node :: HTMLElement }
  , update  :: req -> ctx -> HTMLElement -> Eff eff (Maybe HTMLElement)
  , destroy :: ctx -> HTMLElement -> Eff eff Unit
  } -> 
  Component (Widget eff res) m req res
widget spec = placeholder <$> ((updateWith <$> input <*> version) `startingAt` w0)
  where
  w0 :: Widget eff res
  w0 = buildWidget zero (\_ _ _ _ -> return Nothing)
      
  updateWith :: req -> Int -> Widget eff res
  updateWith i n = buildWidget n updateIfVersionChanged
    where
    updateIfVersionChanged :: Int -> Int -> ctx -> HTMLElement -> Eff eff (Maybe HTMLElement)
    updateIfVersionChanged new old 
      | new > old = spec.update i
      | otherwise = \_ _ -> return Nothing
  
  buildWidget :: Int -> (Int -> Int -> ctx -> HTMLElement -> Eff eff (Maybe HTMLElement)) -> Widget eff res
  buildWidget ver update = W.widget
    { value: ver
    , name: spec.name
    , id: spec.id
    , init: spec.init
    , update: update
    , destroy: spec.destroy 
    } 
    
  version :: forall i. SF i Int
  version = tail $ stateful zero (\i _ -> i + one)
  
-- | Map a function over the placeholders in a component          
mapP :: forall p q m req res. (p -> q) -> Component p m req res -> Component q m req res
mapP f sf = lmap f <$> sf

-- | Map a natural transformation over the monad type argument of a `Component`.
-- |
-- | This function may be useful during testing, to mock requests with a different monad.
hoistComponent :: forall p m n req res. (forall a. m a -> n a) -> Component p m req res -> Component p n req res
hoistComponent f sf = rmap f <$> sf

-- | Install a component inside another, by replacing a placeholder.
install :: forall a b m req res. (Functor m) => Component a m req res -> (a -> HTML b (m res)) -> Component b m req res
install c f = (`graft` f) <$> c

-- | Combine two components into a single component.
-- |
-- | The first argument is a function which combines the two rendered HTML documents into a single document.
-- |
-- | This function works on request and response types by taking the _sum_ in each component. The left summand
-- | gets dispatched to (resp. is generated by) the first component, and the right summand to the second component.
combine :: forall p q r m req1 req2 res1 res2. 
             (Functor m) =>
             (forall a. HTML p a -> HTML q a -> HTML r a) -> 
             Component p m req1 res1 -> 
             Component q m req2 res2 -> 
             Component r m (Either req1 req2) (Either res1 res2)
combine f = mergeWith f1
  where
  f1 :: HTML p (m res1) -> HTML q (m res2) -> HTML r (m (Either res1 res2))
  f1 n1 n2 = f (rmap (Left <$>) n1) (rmap (Right <$>) n2)