;; JSON helpers keep the object/array distinction that Convex's API requires.
(local dkjson (require :dkjson))

(local Json {})
(set Json.null dkjson.null)

(fn Json.object [value]
  (setmetatable value {:__jsontype :object})
  value)

(fn Json.array [value]
  (setmetatable value {:__jsontype :array})
  value)

(fn Json.is-array [value]
  (and (= (type value) :table) (= (. (getmetatable value) :__jsontype) :array)))

(fn Json.encode [value]
  (dkjson.encode value))

(fn Json.decode [value]
  (let [(decoded _ err) (dkjson.decode value 1 dkjson.null)]
    (if decoded decoded
        nil err)))

Json
