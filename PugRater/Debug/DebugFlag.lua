-- Debug/DebugFlag.lua -- the development-build marker.
--
-- This file and the rest of Debug/ are stripped from released packages: the
-- .toc wraps them in a #@debug@ block and .pkgmeta lists the folder under
-- `ignore`, so a shipped zip contains no debug code at all rather than debug
-- code that is merely switched off.
--
-- Production files must therefore only ever reach debug functionality through a
-- guarded feature-detect (`if ns.Debug and ns.Debug.X then`).

local ADDON, ns = ...

ns.DEBUG_BUILD = true
