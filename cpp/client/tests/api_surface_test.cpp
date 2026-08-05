#include "convex.hpp"

template <typename T>
concept HasSubscriptionDisconnect = requires(T& value) {
  value.debug_disconnect();
};

template <typename T>
concept HasAdapterDisconnect = requires(T& value) {
  value.debug_disconnect_for_adapter();
};

template <typename T>
concept HasPendingUpdatesTestHook = requires(T& value) {
  value.pending_updates_for_test();
};

static_assert(!HasSubscriptionDisconnect<convex::Subscription>);
static_assert(!HasAdapterDisconnect<convex::Client>);
static_assert(!HasPendingUpdatesTestHook<convex::Subscription>);

int main() {}
