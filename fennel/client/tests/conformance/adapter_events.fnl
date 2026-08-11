;; Exact adapter protocol v1 shapes. Optional fields are omitted, never null.
(local Events {})

(fn Events.error [id err]
  (let [event {:type :error
               :error {:name (or err.name :Error)
                       :message (or err.message (tostring err))}}]
    (if (and id (not (= id ""))) (set event.id id))
    (if (not (= err.data nil)) (set event.error.data err.data))
    (if (and err.logs (> (length err.logs) 0)) (set event.logs err.logs))
    event))

(fn Events.result [id result]
  (let [event {: id :type :result :value result.value}]
    (if (and result.logs (> (length result.logs) 0))
        (set event.logs result.logs))
    event))

(fn Events.subscription [subscription-id update]
  (let [event {:type :subscription
               :subscriptionId subscription-id
               :value update.value}]
    (if (and update.logs (> (length update.logs) 0))
        (set event.logs update.logs))
    event))

Events
