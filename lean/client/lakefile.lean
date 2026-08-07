/-
Build definition for the educational Convex client.

There are no package dependencies: JSON comes from `Lean.Data.Json`, which the
toolchain already ships, and everything the language cannot do on its own --
sockets, TLS, poll, a monotonic clock, SHA-1, randomness -- comes from the one
C shim compiled below. That keeps the Docker build free of any package fetch
beyond the pinned toolchain itself.

Docker copies this file, `Convex.lean`, `Convex/`, `shim/`, `tests/`, and the
canonical example into a flat build tree, so no layout here leaks back into the
educational repository.
-/

import Lake
open Lake DSL System

package convex where
  -- The shim calls OpenSSL directly for TLS, digests, and randomness. Lean's
  -- own linker invocation passes `--sysroot /opt/lean`, which replaces the
  -- default library search path entirely, so plain `-lssl -lcrypto` cannot
  -- find the system OpenSSL `libssl-dev` installed without an explicit `-L`
  -- back to where Debian actually puts them, and a global `-L` addition
  -- there is not safe either: it would also apply to the later `-lc` in
  -- Lean's own linker invocation and let the linker resolve the system's
  -- glibc ahead of Lean's own bundled one under `/opt/lean/lib/glibc`,
  -- which is what its `Scrt1.o` startup file is actually built against
  -- ("undefined symbol: __libc_csu_init" is that ABI mismatch). Even naming
  -- the shared `.so` files by full path fails one step later: they are
  -- prebuilt against a newer glibc than the one bundled with Lean's
  -- toolchain, so linking against them dynamically demands versioned glibc
  -- symbols (`stat@GLIBC_2.33`, `dlclose@GLIBC_2.34`) that Lean's older
  -- bundled glibc does not export. The static `.a` archives sidestep both
  -- problems: their object code becomes part of this executable directly,
  -- so whatever libc calls OpenSSL itself makes resolve like any other
  -- call in the program, against Lean's own bundled glibc, with no
  -- separate shared-library ABI to satisfy at link time.
  moreLinkArgs := #[
    "/usr/lib/x86_64-linux-gnu/libssl.a",
    "/usr/lib/x86_64-linux-gnu/libcrypto.a"]

target convexShim.o pkg : FilePath := do
  let oFile := pkg.buildDir / "shim" / "convex_shim.o"
  let srcJob ← inputTextFile <| pkg.dir / "shim" / "convex_shim.c"
  let flags := #["-I", (← getLeanIncludeDir).toString, "-fPIC", "-O2", "-Wall", "-Wextra"]
  buildO oFile srcJob flags

extern_lib libconvexshim pkg := do
  let name := nameToStaticLib "convexshim"
  let job ← convexShim.o.fetch
  buildStaticLib (pkg.nativeLibDir / name) #[job]

-- `Glob.submodules X` discovers only the *children* of `X` (`Convex.Ffi`,
-- `Convex.Bytes`, ...), not the bare root module `Convex` itself (the
-- top-level `Convex.lean`), even though `roots := #[`Convex]` names it as
-- this library's root. Anything that `import Convex`s -- which is most of
-- this package -- would build `Convex.Ffi` etc. fine and then fail with
-- "object file .../Convex.olean ... does not exist", because nothing ever
-- scheduled a build for the root file. `Glob.andSubmodules` includes the
-- named module along with its children, which is what a "root" is supposed
-- to mean here.
lean_lib Convex where
  roots := #[`Convex]
  globs := #[.andSubmodules `Convex]

/-- Without an explicit library covering the whole `Tests` tree, Lake does not
reliably track `Main.lean`'s import of `Adapter.lean` as a same-package build
dependency: `lake build` would launch the `Tests.Conformance.Main` job before
`Tests.Conformance.Adapter`'s `.olean` existed, failing with "object file ...
does not exist" instead of building it first. Declaring the library, the same
way `Convex` is declared above, gives every module under `Tests` (the shared
test support code as well as each `lean_exe`'s root) a tracked target so Lake
orders and parallelises them correctly. -/
lean_lib Tests where
  globs := #[.andSubmodules `Tests]

/-- The default target is the conformance adapter, so `./run build lean`
produces the image whose entrypoint the shared harness drives. -/
@[default_target]
lean_exe «convex-adapter» where
  root := `Tests.Conformance.Main

/-- The canonical example, compiled from the exact file the README shows. -/
lean_exe «convex-example» where
  root := `ConvexExample

/-- Scripted peers for the language-local tests. Test-only. -/
lean_exe «convex-fixture» where
  root := `Tests.FixtureMain

lean_exe «unit-tests» where
  root := `Tests.UnitTests

lean_exe «http-tests» where
  root := `Tests.HttpTests

lean_exe «tls-tests» where
  root := `Tests.TlsTests

lean_exe «websocket-tests» where
  root := `Tests.WebSocketTests

lean_exe «live-tests» where
  root := `Tests.LiveTests

lean_exe «adapter-tests» where
  root := `Tests.AdapterTests

lean_exe «example-tests» where
  root := `Tests.ExampleTests
