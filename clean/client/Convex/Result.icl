implementation module Convex.Result

isROk :: !(Result a) -> Bool
isROk (ROk _) = True
isROk (RErr _) = False

resultMap :: !(a -> b) !(Result a) -> Result b
resultMap f (ROk a) = ROk (f a)
resultMap f (RErr e) = RErr e
