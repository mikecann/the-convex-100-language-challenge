(ns adapter-test (:require [clojure.test :refer [deftest is]] [adapter]) (:import [java.io ByteArrayInputStream ByteArrayOutputStream]))
(deftest stdin-hello-and-close
  (let [out (ByteArrayOutputStream.)]
    (adapter/run! (ByteArrayInputStream. (.getBytes "{\"protocolVersion\":1,\"id\":\"hello\",\"op\":\"hello\"}\n{\"id\":\"close\",\"op\":\"close\"}\n")) out nil)
    (let [text (.toString out)] (is (.contains text "\"language\":\"clojure\"")) (is (.contains text "\"type\":\"closed\"")))))
