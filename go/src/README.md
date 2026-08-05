# Source layout

Go packages conventionally live at the module root, so this pilot's native
library source is in the parent directory. This marker keeps the shared
cross-language layout explicit without adding a non-idiomatic `/src` import
path.
